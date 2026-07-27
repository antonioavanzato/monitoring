#!/usr/bin/env bash
#
# Cloud Monitor — установка одной командой.
#
#   cd backend && chmod +x setup.sh && ./setup.sh
#
# Скрипт сам: создаст сервисные аккаунты в трёх облаках, выдаст им права,
# заберёт ключи, положит всё в Lockbox, задеплоит обе функции, поднимет
# API Gateway и пропишет его адрес во фронтенд.
#
# Ничего заранее заполнять не надо — всё спросит по ходу.
# Прервать можно в любой момент (Ctrl+C), повторный запуск безопасен.

set -uo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'
step()  { echo; echo "${BLD}==> $*${OFF}"; }
ok()    { echo "  ${GRN}✓${OFF} $*"; }
warn()  { echo "  ${YLW}!${OFF} $*"; }
die()   { echo; echo "${RED}Ошибка:${OFF} $*" >&2; echo "Исправьте и запустите ./setup.sh снова." >&2; exit 1; }

cd "$(dirname "$0")" || die "не могу перейти в папку скрипта"

# ─────────────────────────────────────────────────────────────
step "Проверяю инструменты"

command -v node >/dev/null || die "не установлен node. Поставьте LTS с https://nodejs.org и повторите."
command -v yc   >/dev/null || die "не установлен yc. Установка:
  curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
  exec -l \$SHELL"
command -v openssl >/dev/null || die "не найден openssl"
ok "node $(node -v), yc есть"

b64() { base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n'; }
jsonval() { grep -o "\"$2\": *\"[^\"]*\"" <<<"$1" | head -1 | sed 's/.*: *"//; s/"$//'; }

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')
[ -n "$PROFILES" ] || die "нет ни одного профиля yc. Выполните 'yc init' — по разу на каждое облако."

echo
echo "Ваши профили yc:"
echo "$PROFILES" | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────
step "Какой профиль отвечает за какой проект"
echo "Впишите имя профиля из списка выше для каждого проекта."

ask_profile() {
  local label="$1" var
  while :; do
    read -r -p "  Профиль для ${label}: " var
    if grep -qx "$var" <<<"$PROFILES"; then echo "$var"; return; fi
    echo "    нет такого профиля, попробуйте ещё раз"
  done
}

P_AVANZATO=$(ask_profile "Avanzato")
P_ALGA=$(ask_profile "ALGA")
P_DARIA=$(ask_profile "Daria")

echo
read -r -p "  В каком профиле разместить сами функции [$P_AVANZATO]: " P_HOME
P_HOME=${P_HOME:-$P_AVANZATO}
grep -qx "$P_HOME" <<<"$PROFILES" || die "профиль '$P_HOME' не найден"

# ─────────────────────────────────────────────────────────────
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
HASHDIR=$(mktemp -d); trap 'rm -rf "$HASHDIR"' EXIT
( cd "$HASHDIR" && npm init -y >/dev/null 2>&1 && npm install bcryptjs >/dev/null 2>&1 ) \
  || die "не удалось поставить bcryptjs (нет интернета?)"
PW_HASH=$(cd "$HASHDIR" && node -e "console.log(require('bcryptjs').hashSync(process.argv[1],12))" "$PW1") \
  || die "не удалось посчитать хеш"
unset PW1 PW2
ok "хеш готов"

JWT_SECRET=$(openssl rand -hex 32)

# ─────────────────────────────────────────────────────────────
step "Создаю сервисные аккаунты и забираю ключи"

declare -A SA_KEY_B64 FOLDER_OF

prepare_project() {
  local name="$1" profile="$2"
  echo
  echo "  ── $name (профиль $profile)"

  yc config profile activate "$profile" >/dev/null 2>&1 || die "не переключиться на профиль $profile"

  local folder
  folder=$(yc config get folder-id 2>/dev/null) || die "у профиля $profile не задан folder-id (выполните 'yc init')"
  [ -n "$folder" ] || die "у профиля $profile пустой folder-id"
  FOLDER_OF[$name]=$folder
  echo "     каталог: $folder"

  if yc iam service-account get cm-monitor >/dev/null 2>&1; then
    echo "     сервисный аккаунт cm-monitor уже есть"
  else
    yc iam service-account create --name cm-monitor >/dev/null \
      || die "не создать сервисный аккаунт в $profile"
    echo "     сервисный аккаунт создан"
  fi

  local sa_id
  sa_id=$(jsonval "$(yc iam service-account get cm-monitor --format json)" id)
  [ -n "$sa_id" ] || die "не получить id сервисного аккаунта в $profile"

  yc resource-manager folder add-access-binding "$folder" \
      --role monitoring.viewer --subject "serviceAccount:$sa_id" >/dev/null 2>&1
  echo "     право на чтение метрик выдано"

  local keyfile="key-$name.json"
  rm -f "$keyfile"
  yc iam key create --service-account-name cm-monitor --output "$keyfile" >/dev/null 2>&1 \
    || die "не создать ключ в $profile"
  SA_KEY_B64[$name]=$(b64 "$keyfile")
  rm -f "$keyfile"           # в base64 уже забрали, на диске не держим
  ok "$name готов"
}

prepare_project avanzato "$P_AVANZATO"
prepare_project alga     "$P_ALGA"
prepare_project daria    "$P_DARIA"

# ─────────────────────────────────────────────────────────────
step "Перехожу в профиль $P_HOME — здесь будут жить функции"
yc config profile activate "$P_HOME" >/dev/null || die "не переключиться на $P_HOME"
HOME_FOLDER=$(yc config get folder-id)
ok "каталог $HOME_FOLDER"

# ─────────────────────────────────────────────────────────────
step "Кладу секреты в Lockbox"

PAYLOAD=$(printf '[{"key":"ADMIN_PASSWORD_HASH","text_value":"%s"},{"key":"JWT_SECRET","text_value":"%s"},{"key":"SA_KEY_AVANZATO","text_value":"%s"},{"key":"SA_KEY_ALGA","text_value":"%s"},{"key":"SA_KEY_DARIA","text_value":"%s"}]' \
  "$PW_HASH" "$JWT_SECRET" "${SA_KEY_B64[avanzato]}" "${SA_KEY_B64[alga]}" "${SA_KEY_B64[daria]}")

if yc lockbox secret get cm-secrets >/dev/null 2>&1; then
  yc lockbox payload add-version --name cm-secrets --payload "$PAYLOAD" >/dev/null \
    || die "не обновить секрет cm-secrets"
  ok "секрет cm-secrets обновлён"
else
  yc lockbox secret create --name cm-secrets \
    --description "Cloud Monitor: пароль, JWT, ключи СА" \
    --payload "$PAYLOAD" >/dev/null || die "не создать секрет cm-secrets"
  ok "секрет cm-secrets создан"
fi
unset PW_HASH PAYLOAD SA_KEY_B64

# ─────────────────────────────────────────────────────────────
step "Сервисный аккаунт для функций"

if ! yc iam service-account get cm-func >/dev/null 2>&1; then
  yc iam service-account create --name cm-func >/dev/null || die "не создать cm-func"
fi
FUNC_SA=$(jsonval "$(yc iam service-account get cm-func --format json)" id)
[ -n "$FUNC_SA" ] || die "не получить id cm-func"

# функции должны уметь читать секрет и вызывать друг друга через шлюз
yc resource-manager folder add-access-binding "$HOME_FOLDER" \
  --role lockbox.payloadViewer --subject "serviceAccount:$FUNC_SA" >/dev/null 2>&1
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
step "Деплой admin-api"
yc serverless function create --name admin-api >/dev/null 2>&1
yc serverless function version create \
  --function-name admin-api \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 128m --execution-timeout 10s \
  --source-path ./admin-api \
  --service-account-id "$FUNC_SA" \
  --environment ALLOWED_ORIGIN="$ORIGIN" \
  --secret name=cm-secrets,key=ADMIN_PASSWORD_HASH,environment-variable=ADMIN_PASSWORD_HASH \
  --secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET \
  >/dev/null || die "не задеплоить admin-api"
ok "admin-api задеплоен"

step "Деплой monitor-aggregator"
yc serverless function create --name monitor-aggregator >/dev/null 2>&1
yc serverless function version create \
  --function-name monitor-aggregator \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 256m --execution-timeout 30s \
  --source-path ./aggregator \
  --service-account-id "$FUNC_SA" \
  --environment ALLOWED_ORIGIN="$ORIGIN" \
  --environment FOLDER_AVANZATO="${FOLDER_OF[avanzato]}" \
  --environment FOLDER_ALGA="${FOLDER_OF[alga]}" \
  --environment FOLDER_DARIA="${FOLDER_OF[daria]}" \
  --secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET \
  --secret name=cm-secrets,key=SA_KEY_AVANZATO,environment-variable=SA_KEY_AVANZATO \
  --secret name=cm-secrets,key=SA_KEY_ALGA,environment-variable=SA_KEY_ALGA \
  --secret name=cm-secrets,key=SA_KEY_DARIA,environment-variable=SA_KEY_DARIA \
  >/dev/null || die "не задеплоить monitor-aggregator"
ok "monitor-aggregator задеплоен"

ADMIN_ID=$(jsonval "$(yc serverless function get admin-api --format json)" id)
AGG_ID=$(jsonval "$(yc serverless function get monitor-aggregator --format json)" id)

# ─────────────────────────────────────────────────────────────
step "Поднимаю API Gateway"

SPEC=$(mktemp); trap 'rm -rf "$HASHDIR" "$SPEC"' EXIT
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

if yc serverless api-gateway get cloud-monitor >/dev/null 2>&1; then
  yc serverless api-gateway update --name cloud-monitor --spec="$SPEC" >/dev/null \
    || die "не обновить шлюз"
else
  yc serverless api-gateway create --name cloud-monitor --spec="$SPEC" >/dev/null \
    || die "не создать шлюз"
fi

DOMAIN=$(jsonval "$(yc serverless api-gateway get cloud-monitor --format json)" domain)
[ -n "$DOMAIN" ] || die "шлюз создан, но не удалось прочитать его домен. Посмотрите: yc serverless api-gateway get cloud-monitor"
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
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$DOMAIN/auth/login" \
  -H 'Content-Type: application/json' -d '{"password":"заведомо-неверный"}' || echo 000)

case "$CODE" in
  401) ok "backend жив и правильно отвергает неверный пароль" ;;
  000) warn "шлюз пока не отвечает — обычно поднимается за минуту. Проверьте позже:
       curl -i -X POST https://$DOMAIN/auth/login -H 'Content-Type: application/json' -d '{\"password\":\"x\"}'" ;;
  *)   warn "неожиданный ответ $CODE — смотрите логи: yc serverless function logs admin-api" ;;
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
