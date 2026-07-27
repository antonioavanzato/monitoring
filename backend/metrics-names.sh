#!/usr/bin/env bash
#
# Показывает, какие метрики serverless-функций реально есть в ваших каталогах.
# Нужен, чтобы не гадать с именами: агрегатор запрашивает конкретные имена,
# и если они не совпадают с настоящими, ответ приходит пустым без ошибки.
#
#   ./metrics-names.sh
#
# IAM-токен берётся на лету и на экран не печатается.

set -uo pipefail

BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'

show() {
  local label="$1" folder="$2" profile="$3"

  echo
  echo "${BLD}── $label ($folder)${OFF}"

  yc config profile activate "$profile" >/dev/null 2>&1 || {
    echo "   профиль $profile недоступен, пропускаю"; return; }

  local token
  token=$(yc iam create-token 2>/dev/null)
  [ -n "$token" ] || { echo "   не получить IAM-токен"; return; }

  echo "   имена метрик сервиса serverless-functions:"
  curl -s -m 30 -H "Authorization: Bearer $token" \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/metrics/names?folderId=${folder}&selectors=service%3D%22serverless-functions%22" \
    | tr ',' '\n' | grep -o '"[a-zA-Z0-9_.]*"' | tr -d '"' \
    | grep -v '^names$' | sed 's/^/     /' | sort -u

  echo "   все метки (labels) первых метрик:"
  curl -s -m 30 -H "Authorization: Bearer $token" \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/metrics?folderId=${folder}&selectors=service%3D%22serverless-functions%22&pageSize=3" \
    | head -c 1500
  echo
}

cd "$(dirname "$0")" || exit 1

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')
ORIG=$(yc config profile list 2>/dev/null | grep ACTIVE | awk '{print $1}')
trap '[ -n "${ORIG:-}" ] && yc config profile activate "$ORIG" >/dev/null 2>&1' EXIT

find_profile() {
  local folder="$1" p
  for p in $PROFILES; do
    yc config profile activate "$p" >/dev/null 2>&1 || continue
    yc resource-manager folder get "$folder" >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo ""
}

for pair in "Avanzato:b1gvs59n7rkplk5jmu21" "ALGA:b1gjcf3ucce90qgigaii" "Daria:b1gfon9pe6vpmlgaq0f7"; do
  label=${pair%%:*}; folder=${pair#*:}
  prof=$(find_profile "$folder")
  if [ -z "$prof" ]; then
    echo; echo "${YLW}── $label ($folder): нет профиля, пропускаю${OFF}"
    continue
  fi
  show "$label" "$folder" "$prof"
done

echo
echo "${BLD}Готово.${OFF} Пришлите этот вывод — по нему подставим верные имена метрик."
