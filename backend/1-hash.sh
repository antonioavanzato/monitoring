#!/usr/bin/env bash
# Шаг 1. Сделать bcrypt-хеш пароля.
#
#   ./1-hash.sh 'мой-пароль'
#
# Печатает хеш. Пароль никуда не отправляется и нигде не сохраняется.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Использование: ./1-hash.sh 'ваш-пароль'   (пароль в ОДИНАРНЫХ кавычках)" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm init -y >/dev/null 2>&1
npm install bcryptjs >/dev/null 2>&1

node -e "console.log(require('bcryptjs').hashSync(process.argv[1], 12))" "$1"
