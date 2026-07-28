#!/usr/bin/env bash
#
# Cloud Monitor — установка одной командой.
#
#   cd backend && chmod +x setup.sh && ./setup.sh
#
# Скрипт сам: создаст сервисные аккаунты в трёх облаках, выдаст им права,
# заберёт ключи, задеплоит обе функции, поднимет API Gateway и пропишет его
# адрес во фронтенд.
#
# Секреты передаются переменными окружения функции, не через Lockbox: он
# платный, а роль у ключей — monitoring.viewer, то есть чтение счётчиков
# вызовов и ничего больше.
#
# Ничего заранее заполнять не надо — всё спросит по ходу.
# Прервать можно в любой момент (Ctrl+C), повторный запуск безопасен.

set -uo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'

# ── Режим репетиции ──────────────────────────────────────────
# ./setup.sh --dry-run  — показывает каждую изменяющую команду и НЕ выполняет её.
# Чтение (get/list) при этом работает по-настоящему, чтобы план был честным.
DRY=0
CODE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY=1 ;;
    # только перезалить код функций: пароль и ключи не трогаем
    --code-only) CODE_ONLY=1 ;;
  esac
done

# Перехватываем вызовы yc: функция с этим именем имеет приоритет над бинарником.
# Печатаем прямо в терминал: у части вызовов вывод заглушён (>/dev/null 2>&1),
# и без этого половина плана осталась бы невидимой.
PLANFILE=$(mktemp)
say_plan() {
  local line="$1"
  # прячем содержимое --payload: там хеш пароля и JWT-секрет
  case "$line" in
    *--payload*) line="${line%%--payload*}--payload <скрыто: пароль и ключи>" ;;
  esac
  printf '  %s\n' "$line" >> "$PLANFILE"
}

yc() {
  if [ "$DRY" = 1 ]; then
    case "$*" in
      *"iam key create"*)
        # ключ не выпускаем, но кладём заглушку, чтобы репетиция дошла до конца
        local out="" prev=""
        for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
        say_plan "yc $*"
        [ -n "$out" ] && echo '{"id":"dry","service_account_id":"dry","private_key":"dry"}' > "$out"
        return 0 ;;
      *" create"*|*"add-access-binding"*|*"add-version"*|*" update "*|*" update --"*)
        say_plan "yc $*"
        return 0 ;;
      *" get "*)
        # ресурса ещё нет — это нормально, не пугаем пользователя ошибкой
        command yc "$@" 2>/dev/null
        return $? ;;
    esac
  fi
  command yc "$@"
}
step()  { echo; echo "${BLD}==> $*${OFF}"; }
ok()    { echo "  ${GRN}✓${OFF} $*"; }
warn()  { echo "  ${YLW}!${OFF} $*"; }
die()   { echo; echo "${RED}Ошибка:${OFF} $*" >&2; echo "Исправьте и запустите ./setup.sh снова." >&2; exit 1; }

cd "$(dirname "$0")" || die "не могу перейти в папку скрипта"

# ─────────────────────────────────────────────────────────────
step "Проверяю инструменты"

command -v node >/dev/null || die "не установлен node. Поставьте LTS с https://nodejs.org и повторите."

# ВАЖНО: именно type -P, а не command -v — ниже определена shell-функция yc,
# и command -v нашёл бы её, решив, что программа установлена.
type -P yc >/dev/null 2>&1 || die "не установлен yc (Yandex Cloud CLI). Установка:

  curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
  exec -l \$SHELL

После этого запустите ./setup.sh снова."

command -v openssl >/dev/null || die "не найден openssl"
ok "node $(node -v), yc $(command yc version 2>/dev/null | head -1)"

# Чтение из stdin — единственная форма, одинаково работающая в macOS и Linux:
# у BSD-base64 нет -w0, а GNU-base64 переносит строки, которые убирает tr.
b64() { base64 < "$1" | tr -d '\n\r'; }
jsonval() { grep -o "\"$2\": *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }

# Переменные окружения уже развёрнутой версии функции: "имя<TAB>значение".
# Нужны для --code-only, чтобы перелить код, не спрашивая пароль и не
# перевыпуская ключи. Значения секретов больше не хранятся отдельно —
# единственный их экземпляр живёт в самой функции.
current_env() {
  yc serverless function version get --function-name "$1" --format json 2>/dev/null \
  | node -e 'let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      let j; try { j = JSON.parse(s); } catch { return; }
      const e = j.environment || {};
      for (const k of Object.keys(e)) console.log(k + "\t" + e[k]);
    });' 2>/dev/null
}

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')
[ -n "$PROFILES" ] || die "нет ни одного профиля yc. Выполните 'yc init' — по разу на каждое облако."

# Активный профиль вернём как было, что бы дальше ни случилось.
ORIG_PROFILE=$(yc config profile list 2>/dev/null | grep ACTIVE | awk '{print $1}')
restore_profile() {
  [ -n "${ORIG_PROFILE:-}" ] && yc config profile activate "$ORIG_PROFILE" >/dev/null 2>&1
  return 0
}
trap 'restore_profile' EXIT

echo
echo "Ваши профили yc:"
echo "$PROFILES" | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────
# Каталоги известны заранее — это идентификаторы, не секреты.
FOLDER_AV="b1gvs59n7rkplk5jmu21"   # Avanzato («Мой»)
FOLDER_AL="b1gjcf3ucce90qgigaii"   # ALGA
FOLDER_DA="b1gfon9pe6vpmlgaq0f7"   # Daria

step "Определяю, какой профиль к какому облаку относится"
echo "  Перебираю профили и смотрю, из какого виден каждый каталог."

# Ищет профиль, отвечающий за указанный каталог.
#
# Сначала — по локальной настройке профиля: folder-id хранится в конфиге yc,
# сети для этого не нужно, и ошибиться тут невозможно. Только если совпадения
# нет, спрашиваем API, и то с повторами: при дрожащей сети один запрос может
# ложно удаться, а другой ложно провалиться, и тогда каталог припишется не
# тому облаку — а это значит деплой в чужой проект.
find_profile() {
  local folder="$1" label="$2" p cfg

  for p in $PROFILES; do
    yc config profile activate "$p" >/dev/null 2>&1 || continue
    cfg=$(yc config get folder-id 2>/dev/null)
    if [ "$cfg" = "$folder" ]; then
      echo "     ${GRN}✓${OFF} $label → профиль $p (по настройке профиля)" >&2
      echo "$p"
      return 0
    fi
  done

  # Ни у одного профиля этот каталог не выбран по умолчанию — спрашиваем API.
  local try
  for p in $PROFILES; do
    yc config profile activate "$p" >/dev/null 2>&1 || continue
    for try in 1 2 3; do
      if yc resource-manager folder get "$folder" >/dev/null 2>&1; then
        echo "     ${GRN}✓${OFF} $label → профиль $p (проверено через API)" >&2
        echo "$p"
        return 0
      fi
      sleep 1
    done
  done

  echo "     ${YLW}—${OFF} $label ($folder): ни один профиль не отвечает за этот каталог, пропускаю" >&2
  echo ""
}

P_AVANZATO=$(find_profile "$FOLDER_AV" "Avanzato")
P_ALGA=$(find_profile "$FOLDER_AL" "ALGA")
P_DARIA=$(find_profile "$FOLDER_DA" "Daria")

READY=0
[ -n "$P_AVANZATO" ] && READY=$((READY+1))
[ -n "$P_ALGA" ]     && READY=$((READY+1))
[ -n "$P_DARIA" ]    && READY=$((READY+1))

[ "$READY" -gt 0 ] || die "не найдено ни одного из трёх облаков.
Выполните 'yc init' хотя бы для одного и запустите ./setup.sh снова."

if [ "$READY" -lt 3 ]; then
  echo
  warn "настроено облаков: $READY из 3."
  echo "  Дашборд поднимется с ними. Остальные добавите позже: сделайте 'yc init'"
  echo "  для недостающего аккаунта и запустите ./setup.sh ещё раз — он всё дополнит."
else
  ok "все три облака найдены"
fi

# Функции разместим в первом доступном облаке.
DEFAULT_HOME=$P_AVANZATO
[ -n "$DEFAULT_HOME" ] || DEFAULT_HOME=$P_ALGA
[ -n "$DEFAULT_HOME" ] || DEFAULT_HOME=$P_DARIA

echo
echo "  В каком облаке разместить сами функции? Просто нажмите Enter — возьмём $DEFAULT_HOME."
while :; do
  read -r -p "  Профиль [$DEFAULT_HOME]: " P_HOME
  P_HOME=${P_HOME:-$DEFAULT_HOME}
  grep -qx "$P_HOME" <<<"$PROFILES" && break
  echo "    профиля '$P_HOME' нет. Доступны: $(echo $PROFILES | tr '\n' ' ')"
  echo "    (нажмите Enter, чтобы взять $DEFAULT_HOME)"
done

# ─────────────────────────────────────────────────────────────
step "Проверяю, что ничего вашего не заденем"

yc config profile activate "$P_HOME" >/dev/null 2>&1

# Куда именно поедут функции — показываем ДО подтверждения, а не после.
TARGET_FOLDER=$(yc config get folder-id 2>/dev/null)
case "$TARGET_FOLDER" in
  "$FOLDER_AV") TARGET_NAME="Avanzato" ;;
  "$FOLDER_AL") TARGET_NAME="ALGA" ;;
  "$FOLDER_DA") TARGET_NAME="Daria" ;;
  "")           die "не удалось определить каталог профиля '$P_HOME'. Проверьте сеть и 'yc config get folder-id'." ;;
  *)            TARGET_NAME="НЕИЗВЕСТНЫЙ ПРОЕКТ" ;;
esac

echo
echo "  ${BLD}Функции будут созданы здесь:${OFF}"
echo "     профиль:  $P_HOME"
echo "     каталог:  $TARGET_FOLDER  (${BLD}$TARGET_NAME${OFF})"
if [ "$TARGET_NAME" = "НЕИЗВЕСТНЫЙ ПРОЕКТ" ]; then
  warn "этот каталог не совпадает ни с одним из трёх известных — проверьте дважды."
fi
echo

CLASH=""
for f in cm-admin-api cm-monitor-aggregator; do
  yc serverless function get "$f" >/dev/null 2>&1 && CLASH="$CLASH\n     функция $f"
done
yc serverless api-gateway get cm-gateway >/dev/null 2>&1 && CLASH="$CLASH\n     шлюз cm-gateway"
yc lockbox secret get cm-secrets    >/dev/null 2>&1 && CLASH="$CLASH\n     секрет cm-secrets"

echo "  Будут созданы только ресурсы с префиксом cm- :"
echo "     сервисный аккаунт cm-monitor — в настроенных каталогах ($READY шт., роль monitoring.viewer, только чтение)"
echo "     сервисный аккаунт cm-func    — в каталоге $P_HOME"
echo "     секрет   cm-secrets"
echo "     функции  cm-admin-api, cm-monitor-aggregator"
echo "     шлюз     cm-gateway"
echo
echo "  Существующие функции, шлюзы и секреты не читаются, не меняются и не удаляются."
echo "  Права выдаются добавлением (add-access-binding) — текущие доступы не затрагиваются."

if [ -n "$CLASH" ]; then
  echo
  warn "уже существуют (будут ОБНОВЛЕНЫ до свежей версии):"
  printf "$CLASH\n"
  echo "  Если это не ресурсы Cloud Monitor от прошлого запуска — прервите (Ctrl+C) и переименуйте их."
fi

echo
read -r -p "  Продолжить? [y/N]: " GO
case "$GO" in
  [yYдД]*) ;;
  *) echo "  Отменено. Ничего не создано."; exit 0 ;;
esac

# ─────────────────────────────────────────────────────────────
if [ "$CODE_ONLY" = 1 ]; then
  step "Режим --code-only: пароль и ключи не трогаем"
  ok "переливаем только код функций, секрет cm-secrets остаётся как есть"
else
step "Пароль для входа в дашборд"
echo "  Вводится скрыто. Нигде не сохраняется — в облако уедет только bcrypt-хеш."

while :; do
  read -r -s -p "  Пароль: " PW1; echo
  read -r -s -p "  Ещё раз: " PW2; echo
  [ -n "$PW1" ] || { echo "    пустой пароль не годится"; continue; }
  [ ${#PW1} -ge 8 ] || { echo "    минимум 8 символов"; continue; }
  [ "$PW1" = "$PW2" ] && break
  echo "    не совпадают, ещё раз"
done

echo "  Считаю хеш…"
HASHDIR=$(mktemp -d); trap 'rm -rf "${HASHDIR:-}"; restore_profile' EXIT
( cd "$HASHDIR" && npm init -y >/dev/null 2>&1 && npm install bcryptjs >/dev/null 2>&1 ) \
  || die "не удалось поставить bcryptjs (нет интернета?)"
PW_HASH=$(cd "$HASHDIR" && node -e "console.log(require('bcryptjs').hashSync(process.argv[1],12))" "$PW1") \
  || die "не удалось посчитать хеш"
unset PW1 PW2
ok "хеш готов"

JWT_SECRET=$(openssl rand -hex 32)
fi

# ─────────────────────────────────────────────────────────────
step "Создаю сервисные аккаунты и забираю ключи"

# Без ассоциативных массивов: в macOS штатный bash 3.2, там их нет.
# Функция печатает в stdout строку "folderId<TAB>base64ключа", логи идут в stderr.
prepare_project() {
  local name="$1" profile="$2"
  {
    echo
    echo "  ── $name (профиль $profile)"
  } >&2

  yc config profile activate "$profile" >/dev/null 2>&1 || die "не переключиться на профиль $profile"

  local folder
  folder=$(yc config get folder-id 2>/dev/null)
  [ -n "$folder" ] || die "у профиля $profile не задан folder-id (выполните 'yc init')"
  echo "     каталог: $folder" >&2

  if yc iam service-account get cm-monitor >/dev/null 2>&1; then
    echo "     сервисный аккаунт cm-monitor уже есть" >&2
  else
    yc iam service-account create --name cm-monitor >/dev/null \
      || die "не создать сервисный аккаунт в $profile"
    echo "     сервисный аккаунт создан" >&2
  fi

  local sa_id
  sa_id=$(jsonval "$(yc iam service-account get cm-monitor --format json)" id)
  # в репетиции аккаунт не создавался, поэтому и id взяться неоткуда
  [ -z "$sa_id" ] && [ "$DRY" = 1 ] && sa_id="<id сервисного аккаунта cm-monitor>"
  [ -n "$sa_id" ] || die "не получить id сервисного аккаунта в $profile"

  yc resource-manager folder add-access-binding "$folder" \
      --role monitoring.viewer --subject "serviceAccount:$sa_id" >/dev/null 2>&1
  echo "     право на чтение метрик выдано" >&2

  local keyfile="key-$name.json"
  rm -f "$keyfile"
  yc iam key create --service-account-name cm-monitor --output "$keyfile" >/dev/null 2>&1 \
    || die "не создать ключ в $profile"
  local key_b64
  key_b64=$(b64 "$keyfile")
  rm -f "$keyfile"           # в base64 уже забрали, на диске не держим

  # Молча уехавший пустой ключ — худшее, что тут может случиться:
  # функция задеплоится и не увидит метрик. Лучше остановиться.
  if [ "$DRY" != 1 ] && [ ${#key_b64} -lt 100 ]; then
    die "ключ для $name закодировался неправильно (получилось ${#key_b64} символов).
Без этого агрегатор не сможет читать метрики. Проверьте, что команда
'base64' работает: echo test | base64"
  fi
  ok "$name готов" >&2

  printf '%s\t%s\n' "$folder" "$key_b64"
}

KEY_AV=""; KEY_AL=""; KEY_DA=""

if [ "$CODE_ONLY" = 1 ]; then
  # ключи уже лежат в Lockbox; отмечаем, какие облака участвуют
  [ -n "$P_AVANZATO" ] && KEY_AV="есть"
  [ -n "$P_ALGA" ]     && KEY_AL="есть"
  [ -n "$P_DARIA" ]    && KEY_DA="есть"
else

if [ -n "$P_AVANZATO" ]; then
  RES=$(prepare_project avanzato "$P_AVANZATO") || exit 1
  FOLDER_AV=${RES%%$'\t'*}; KEY_AV=${RES#*$'\t'}
fi
if [ -n "$P_ALGA" ]; then
  RES=$(prepare_project alga "$P_ALGA") || exit 1
  FOLDER_AL=${RES%%$'\t'*}; KEY_AL=${RES#*$'\t'}
fi
if [ -n "$P_DARIA" ]; then
  RES=$(prepare_project daria "$P_DARIA") || exit 1
  FOLDER_DA=${RES%%$'\t'*}; KEY_DA=${RES#*$'\t'}
fi
unset RES
fi

# ─────────────────────────────────────────────────────────────
step "Перехожу в профиль $P_HOME — здесь будут жить функции"
yc config profile activate "$P_HOME" >/dev/null || die "не переключиться на $P_HOME"
HOME_FOLDER=$(yc config get folder-id)
ok "каталог $HOME_FOLDER"

# ─────────────────────────────────────────────────────────────
# Lockbox не используем: он платный, а роль у ключей — monitoring.viewer,
# то есть чтение счётчиков вызовов и ничего больше. Секреты передаём
# переменными окружения функции; прочитать их может только владелец каталога.
#
# Значения сохраняем до unset ниже — они понадобятся при сборке команд деплоя.
PW_HASH_KEEP="${PW_HASH:-}"
JWT_SECRET_KEEP="${JWT_SECRET:-}"
KEY_AV_KEEP="${KEY_AV:-}"
KEY_AL_KEEP="${KEY_AL:-}"
KEY_DA_KEEP="${KEY_DA:-}"

# Каталоги — по тем облакам, что реально настроены.
# Каталог передаём, если облако настроено: при полном запуске это значит
# «ключ выпущен», при --code-only — «профиль для него нашёлся».
AGG_ARGS=()
if [ -n "$P_AVANZATO" ]; then AGG_ARGS+=(--environment "FOLDER_AVANZATO=$FOLDER_AV"); fi
if [ -n "$P_ALGA" ];     then AGG_ARGS+=(--environment "FOLDER_ALGA=$FOLDER_AL");     fi
if [ -n "$P_DARIA" ];    then AGG_ARGS+=(--environment "FOLDER_DARIA=$FOLDER_DA");    fi

unset PW_HASH KEY_AV KEY_AL KEY_DA

# ─────────────────────────────────────────────────────────────
step "Сервисный аккаунт для функций"

if ! yc iam service-account get cm-func >/dev/null 2>&1; then
  yc iam service-account create --name cm-func >/dev/null || die "не создать cm-func"
fi
FUNC_SA=$(jsonval "$(yc iam service-account get cm-func --format json)" id)
[ -z "$FUNC_SA" ] && [ "$DRY" = 1 ] && FUNC_SA="<id сервисного аккаунта cm-func>"
[ -n "$FUNC_SA" ] || die "не получить id cm-func"

# функции должны уметь читать секрет и вызывать друг друга через шлюз
yc resource-manager folder add-access-binding "$HOME_FOLDER" \
  --role functions.functionInvoker --subject "serviceAccount:$FUNC_SA" >/dev/null 2>&1
ok "cm-func готов ($FUNC_SA)"

# ─────────────────────────────────────────────────────────────
step "Ставлю зависимости функций"
( cd admin-api  && npm install --omit=dev --silent ) || die "npm install в admin-api"
( cd aggregator && npm install --omit=dev --silent ) || die "npm install в aggregator"
ok "зависимости на месте"

ORIGIN="https://antonioavanzato.github.io"

# ─────────────────────────────────────────────────────────────
# Заводим обе функции заранее: их id нужны агрегатору, чтобы исключить
# собственные вызовы из показаний (иначе дашборд считает сам себя).
yc serverless function create --name cm-admin-api >/dev/null 2>&1
yc serverless function create --name cm-monitor-aggregator >/dev/null 2>&1
ADMIN_ID=$(jsonval "$(yc serverless function get cm-admin-api --format json)" id)
AGG_ID=$(jsonval "$(yc serverless function get cm-monitor-aggregator --format json)" id)
if [ "$DRY" = 1 ]; then
  ADMIN_ID=${ADMIN_ID:-"<id функции cm-admin-api>"}
  AGG_ID=${AGG_ID:-"<id функции cm-monitor-aggregator>"}
fi
# И идентификаторы, и имена: метка function у разных метрик заполняется
# то одним, то другим — по одному только id часть рядов не отсеивалась бы.
EXCLUDE_IDS="$ADMIN_ID,$AGG_ID,cm-admin-api,cm-monitor-aggregator"

# ─────────────────────────────────────────────────────────────
# Секреты передаём переменными окружения, а не через Lockbox: он платный, а
# роль у ключей всего лишь monitoring.viewer — чтение счётчиков вызовов.
#
# В режиме --code-only значений у нас нет (пароль не спрашивали, ключи не
# выпускали), поэтому переносим их из уже развёрнутой версии функции.
SECRET_KEYS="ADMIN_PASSWORD_HASH JWT_SECRET SA_KEY_AVANZATO SA_KEY_ALGA SA_KEY_DARIA"

ADMIN_ENV=(); AGG_ENV=()
if [ "$CODE_ONLY" = 1 ]; then
  step "Забираю секреты из развёрнутых версий"
  # ВАЖНО: без $(...) — подстановка команд создаёт подоболочку, и массив,
  # наполненный внутри неё, до основного скрипта не доходит. Счётчик при этом
  # выглядит правильным, а секреты в деплой не попадают.
  KEPT=0
  keep_env() {                       # $1 функция, $2 имя массива
    local key val
    KEPT=0
    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      case " $SECRET_KEYS " in
        *" $key "*) eval "$2+=(--environment \"\$key=\$val\")"; KEPT=$((KEPT+1)) ;;
      esac
    done < <(current_env "$1")
  }
  keep_env cm-admin-api ADMIN_ENV;         n1=$KEPT
  keep_env cm-monitor-aggregator AGG_ENV;  n2=$KEPT
  if [ "${n1:-0}" -eq 0 ] && [ "${n2:-0}" -eq 0 ]; then
    warn "в развёрнутых версиях секретов нет — значит они ещё берутся из Lockbox."
    echo "     Оставляю привязки к Lockbox как есть: перелив кода ничего не сломает."
    echo "     Чтобы переехать на переменные окружения, выполните полный ./setup.sh"
    USE_LOCKBOX=1
  else
    ok "перенесено значений: admin-api $n1, aggregator $n2"
    USE_LOCKBOX=0
  fi
else
  ADMIN_ENV=(--environment "ADMIN_PASSWORD_HASH=$PW_HASH_KEEP"
             --environment "JWT_SECRET=$JWT_SECRET_KEEP")
  [ -n "$KEY_AV_KEEP" ] && AGG_ENV+=(--environment "SA_KEY_AVANZATO=$KEY_AV_KEEP")
  [ -n "$KEY_AL_KEEP" ] && AGG_ENV+=(--environment "SA_KEY_ALGA=$KEY_AL_KEEP")
  [ -n "$KEY_DA_KEEP" ] && AGG_ENV+=(--environment "SA_KEY_DARIA=$KEY_DA_KEEP")
  AGG_ENV+=(--environment "JWT_SECRET=$JWT_SECRET_KEEP")
  USE_LOCKBOX=0
fi

# Старые привязки к Lockbox нужны только пока не переехали
LOCK_ADMIN=(); LOCK_AGG=()
if [ "${USE_LOCKBOX:-0}" = 1 ]; then
  LOCK_ADMIN=(--secret name=cm-secrets,key=ADMIN_PASSWORD_HASH,environment-variable=ADMIN_PASSWORD_HASH
              --secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET)
  LOCK_AGG=(--secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET
            --secret name=cm-secrets,key=SA_KEY_AVANZATO,environment-variable=SA_KEY_AVANZATO
            --secret name=cm-secrets,key=SA_KEY_ALGA,environment-variable=SA_KEY_ALGA
            --secret name=cm-secrets,key=SA_KEY_DARIA,environment-variable=SA_KEY_DARIA)
fi

step "Деплой cm-admin-api"
yc serverless function version create \
  --function-name cm-admin-api \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 128m --execution-timeout 10s \
  --source-path ./admin-api \
  --service-account-id "$FUNC_SA" \
  --environment ALLOWED_ORIGIN="$ORIGIN" \
  ${ADMIN_ENV[@]+"${ADMIN_ENV[@]}"} \
  ${LOCK_ADMIN[@]+"${LOCK_ADMIN[@]}"} \
  >/dev/null || die "не задеплоить cm-admin-api"
ok "cm-admin-api задеплоен"

step "Деплой cm-monitor-aggregator"
yc serverless function version create \
  --function-name cm-monitor-aggregator \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 256m --execution-timeout 30s \
  --source-path ./aggregator \
  --service-account-id "$FUNC_SA" \
  --environment ALLOWED_ORIGIN="$ORIGIN" \
  --environment EXCLUDE_FUNCTIONS="$EXCLUDE_IDS" \
  ${AGG_ENV[@]+"${AGG_ENV[@]}"} \
  ${LOCK_AGG[@]+"${LOCK_AGG[@]}"} \
  ${AGG_ARGS[@]+"${AGG_ARGS[@]}"} \
  >/dev/null || die "не задеплоить cm-monitor-aggregator"
ok "cm-monitor-aggregator задеплоен"

# ─────────────────────────────────────────────────────────────
step "Поднимаю API Gateway"

SPEC=$(mktemp); trap 'rm -rf "${HASHDIR:-}" "${SPEC:-}"; restore_profile' EXIT
cat > "$SPEC" <<SPECEOF
openapi: 3.0.0
info:
  title: Cloud Monitor API
  version: 1.0.0
paths:
  /auth/{action}:
    parameters:
      - name: action
        in: path
        required: true
        schema: { type: string }
    x-yc-apigateway-any-method:
      x-yc-apigateway-integration:
        type: cloud_functions
        function_id: ${ADMIN_ID}
        tag: \$latest
        service_account_id: ${FUNC_SA}
  /metrics:
    get:
      x-yc-apigateway-integration:
        type: cloud_functions
        function_id: ${AGG_ID}
        tag: \$latest
        service_account_id: ${FUNC_SA}
    options:
      x-yc-apigateway-integration:
        type: cloud_functions
        function_id: ${AGG_ID}
        tag: \$latest
        service_account_id: ${FUNC_SA}
SPECEOF

if yc serverless api-gateway get cm-gateway >/dev/null 2>&1; then
  yc serverless api-gateway update --name cm-gateway --spec="$SPEC" >/dev/null \
    || die "не обновить шлюз"
else
  yc serverless api-gateway create --name cm-gateway --spec="$SPEC" >/dev/null \
    || die "не создать шлюз"
fi

DOMAIN=$(jsonval "$(yc serverless api-gateway get cm-gateway --format json)" domain)

if [ "$DRY" = 1 ]; then
  echo
  echo "${BLD}Полный список команд, которые выполнил бы настоящий запуск:${OFF}"
  echo
  cat "$PLANFILE"
  rm -f "$PLANFILE"
  echo
  echo "${GRN}${BLD}Репетиция закончена. В облаках ничего не изменилось.${OFF}"
  echo "Ни одной из перечисленных команд не выполнялось — только чтение (get/list)."
  echo
  echo "Если всё устраивает — запустите без флага:  ./setup.sh"
  exit 0
fi

[ -n "$DOMAIN" ] || die "шлюз создан, но не удалось прочитать его домен. Посмотрите: yc serverless api-gateway get cm-gateway"
ok "шлюз поднят: https://$DOMAIN"

# ─────────────────────────────────────────────────────────────
step "Прописываю адрес во фронтенд"

CFG="../config.js"
[ -f "$CFG" ] || die "не найден $CFG"
sed -i.bak "s#API_BASE: '[^']*'#API_BASE: 'https://$DOMAIN'#" "$CFG" && rm -f "$CFG.bak"
grep -q "https://$DOMAIN" "$CFG" || die "не удалось записать адрес в config.js — впишите вручную"
ok "config.js обновлён"

# ─────────────────────────────────────────────────────────────
step "Проверяю, что backend отвечает"

sleep 3
CODE=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST "https://$DOMAIN/auth/login" \
  -H 'Content-Type: application/json' -d '{"password":"заведомо-неверный"}' 2>/dev/null)
[ -n "$CODE" ] || CODE=000

case "$CODE" in
  401) ok "backend жив и правильно отвергает неверный пароль" ;;
  000) warn "шлюз пока не отвечает — обычно поднимается за минуту. Проверьте позже:
       curl -i -X POST https://$DOMAIN/auth/login -H 'Content-Type: application/json' -d '{\"password\":\"x\"}'" ;;
  *)   warn "неожиданный ответ $CODE — смотрите логи: yc serverless function logs cm-admin-api" ;;
esac

# ─────────────────────────────────────────────────────────────
echo
echo "${GRN}${BLD}Готово.${OFF}"
echo
echo "Осталось отправить обновлённый config.js на GitHub:"
echo
echo "    ${BLD}cd .. && git add config.js && git commit -m 'Point frontend at deployed gateway' && git push origin main${OFF}"
echo
echo "Через минуту дашборд заработает:"
echo "    https://antonioavanzato.github.io/monitoring/"
echo
echo "Заходить — паролем, который вы ввели в начале."
echo
