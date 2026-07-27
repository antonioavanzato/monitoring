#!/usr/bin/env bash
# Шаг 3. Задеплоить обе функции и напечатать их URL.
#
# Перед запуском впишите три folderId ниже.
set -euo pipefail

# ---- ЗАПОЛНИТЬ ----
FOLDER_AVANZATO="b1g..."
FOLDER_ALGA="b1g..."
FOLDER_DARIA="b1g..."
ALLOWED_ORIGIN="https://antonioavanzato.github.io"
# -------------------

for v in "$FOLDER_AVANZATO" "$FOLDER_ALGA" "$FOLDER_DARIA"; do
  case "$v" in b1g...) echo "Впишите folderId в начале 3-deploy.sh" >&2; exit 1;; esac
done

cd "$(dirname "$0")"

echo "==> Ставлю зависимости"
(cd admin-api && npm install --omit=dev --silent)
(cd aggregator && npm install --omit=dev --silent)

echo "==> Создаю функции (если их ещё нет)"
yc serverless function create --name admin-api         2>/dev/null || true
yc serverless function create --name monitor-aggregator 2>/dev/null || true

echo "==> Деплою admin-api"
yc serverless function version create \
  --function-name admin-api \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 128m --execution-timeout 10s \
  --source-path ./admin-api \
  --environment ALLOWED_ORIGIN="$ALLOWED_ORIGIN" \
  --secret name=cm-secrets,key=ADMIN_PASSWORD_HASH,environment-variable=ADMIN_PASSWORD_HASH \
  --secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET

echo "==> Деплою monitor-aggregator"
yc serverless function version create \
  --function-name monitor-aggregator \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 256m --execution-timeout 30s \
  --source-path ./aggregator \
  --environment ALLOWED_ORIGIN="$ALLOWED_ORIGIN" \
  --environment FOLDER_AVANZATO="$FOLDER_AVANZATO" \
  --environment FOLDER_ALGA="$FOLDER_ALGA" \
  --environment FOLDER_DARIA="$FOLDER_DARIA" \
  --secret name=cm-secrets,key=JWT_SECRET,environment-variable=JWT_SECRET \
  --secret name=cm-secrets,key=SA_KEY_AVANZATO,environment-variable=SA_KEY_AVANZATO \
  --secret name=cm-secrets,key=SA_KEY_ALGA,environment-variable=SA_KEY_ALGA \
  --secret name=cm-secrets,key=SA_KEY_DARIA,environment-variable=SA_KEY_DARIA

echo "==> Открываю публичный вызов (авторизация своя, по JWT)"
yc serverless function allow-unauthenticated-invoke admin-api
yc serverless function allow-unauthenticated-invoke monitor-aggregator

echo
echo "URL функций:"
yc serverless function get admin-api          --format json | grep -o 'https://[^"]*' | head -1
yc serverless function get monitor-aggregator --format json | grep -o 'https://[^"]*' | head -1
echo
echo "Дальше нужен API Gateway (шаг 4) — функции по отдельности не дадут общих путей /auth/login и /metrics."
