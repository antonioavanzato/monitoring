#!/usr/bin/env bash
# Шаг 2. Создать секрет в Lockbox со всеми ключами.
#
# Перед запуском положите рядом три файла ключей сервисных аккаунтов:
#   key-avanzato.json, key-alga.json, key-daria.json
# (получаются командой:
#    yc iam key create --service-account-name <имя> --output key-avanzato.json )
#
# Запуск:  ./2-secrets.sh '<bcrypt-хеш из шага 1>'
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Использование: ./2-secrets.sh '\$2b\$12\$...'   (хеш в ОДИНАРНЫХ кавычках!)" >&2
  exit 1
fi
HASH="$1"

for f in key-avanzato.json key-alga.json key-daria.json; do
  [ -f "$f" ] || { echo "Нет файла $f" >&2; exit 1; }
done

b64() { base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n'; }

JWT_SECRET="$(openssl rand -hex 32)"

PAYLOAD=$(cat <<JSON
[
  {"key":"ADMIN_PASSWORD_HASH","text_value":"$HASH"},
  {"key":"JWT_SECRET","text_value":"$JWT_SECRET"},
  {"key":"SA_KEY_AVANZATO","text_value":"$(b64 key-avanzato.json)"},
  {"key":"SA_KEY_ALGA","text_value":"$(b64 key-alga.json)"},
  {"key":"SA_KEY_DARIA","text_value":"$(b64 key-daria.json)"}
]
JSON
)

yc lockbox secret create --name cm-secrets \
  --description "Cloud Monitor: пароль, JWT-секрет, ключи СА" \
  --payload "$PAYLOAD"

echo
echo "Готово. Секрет cm-secrets создан."
echo "Файлы key-*.json можно удалить: rm key-*.json"
