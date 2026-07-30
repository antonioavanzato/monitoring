#!/usr/bin/env bash
#
# Какой порог ставить в алерте Monitoring. Только чтение, ничего не меняет.
#
#   ./alert-threshold.sh            # каталог Avanzato
#   ./alert-threshold.sh b1gfon9pe6vpmlgaq0f7   # каталог Daria
#
# Алерт считает СЫРУЮ сумму точек functions_finished — ту самую, что завышена
# втрое, потому что метрика это счётчик за скользящую минуту, отдаваемый раз в
# 15 секунд. Поэтому порог нельзя брать из головы: его надо мерить в тех же
# единицах, в каких считает сам алерт.
#
# Скрипт берёт последние сутки, считает сырую сумму по часам и настоящее число
# вызовов, выводит коэффициент и рекомендованные пороги.

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'

FOLDER=${1:-b1gvs59n7rkplk5jmu21}
FREE_TIER=1000000          # бесплатных вызовов в месяц
HOURS_IN_MONTH=720

cd "$(dirname "$0")" || exit 1

# ── находим профиль, из которого виден нужный каталог ──
ORIG=$(yc config profile list 2>/dev/null | grep ACTIVE | awk '{print $1}')
trap '[ -n "${ORIG:-}" ] && yc config profile activate "$ORIG" >/dev/null 2>&1' EXIT

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')

FOUND=""
for p in $PROFILES; do
  yc config profile activate "$p" >/dev/null 2>&1 || continue
  if [ "$(yc config get folder-id 2>/dev/null)" = "$FOLDER" ]; then FOUND="$p"; break; fi
done

# Каталог может быть виден из профиля, для которого он не выбран по умолчанию —
# так у нас профиль daria видит каталог ALGA. Читать метрики этого достаточно.
if [ -z "$FOUND" ]; then
  for p in $PROFILES; do
    yc config profile activate "$p" >/dev/null 2>&1 || continue
    if yc resource-manager folder get "$FOLDER" >/dev/null 2>&1; then
      FOUND="$p"; echo "  каталог виден из профиля $p (не его каталог по умолчанию)"; break
    fi
  done
fi
[ -n "$FOUND" ] || { echo "не нашёл профиль для каталога $FOLDER"; exit 1; }

TOKEN=$(yc iam create-token 2>/dev/null)
[ -n "$TOKEN" ] || { echo "не получить IAM-токен"; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FROM=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

echo "${BLD}Замер порога для алерта${OFF}"
echo "  каталог $FOLDER, профиль $FOUND"
echo "  окно: $FROM → $NOW"

RAW=$(curl -s -m 60 -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=$FOLDER" \
  -d "{\"query\":\"\\\"functions_finished\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$FROM\",\"toTime\":\"$NOW\",\"downsampling\":{\"disabled\":true}}")

CM_FREE="$FREE_TIER" CM_HOURS="$HOURS_IN_MONTH" node -e '
  const FREE = Number(process.env.CM_FREE), HOURS = Number(process.env.CM_HOURS);
  let j; try { j = JSON.parse(process.argv[1]); } catch { j = null; }
  if (!j || !Array.isArray(j.metrics)) {
    console.log("\n  Monitoring вернул не то, что ожидалось:");
    console.log("  " + String(process.argv[1]).slice(0, 300));
    process.exit(1);
  }
  const vals = ts => (ts?.doubleValues || ts?.int64Values || []).map(Number);

  // Все ненулевые точки всех функций каталога, по времени.
  const pts = [];
  j.metrics.forEach(m => {
    const v = vals(m.timeseries), t = m.timeseries?.timestamps || [];
    v.forEach((x, i) => { if (x > 0) pts.push([Number(t[i]), x, m.labels?.function || m.labels?.resource_id || "?"]); });
  });
  if (!pts.length) { console.log("\n  за сутки вызовов не видно — возьмите окно побольше"); process.exit(0); }
  pts.sort((a, b) => a[0] - b[0]);

  // Сырая сумма — ровно то, что складывает алерт.
  const rawSum = pts.reduce((a, p) => a + p[1], 0);

  // Настоящее число вызовов: подряд идущие точки одной функции = одно событие.
  const perFunc = {};
  pts.forEach(([t, v, f]) => (perFunc[f] = perFunc[f] || []).push([t, v]));
  let runs = 0;
  Object.values(perFunc).forEach(arr => {
    let prev = -Infinity;
    arr.forEach(([t]) => { if (t - prev > 20000) runs++; prev = t; });
  });

  const k = runs ? rawSum / runs : 0;
  const rawPerHour = rawSum / 24;
  const realPerHour = runs / 24;

  const pad = (s, n) => String(s).padStart(n);
  const fmt = n => Math.round(n).toLocaleString("ru-RU");

  console.log("");
  console.log("  \x1b[1mчто намерено за сутки\x1b[0m");
  console.log("     сырая сумма точек:        " + pad(fmt(rawSum), 10) + "   \x1b[2m← так считает алерт\x1b[0m");
  console.log("     настоящих вызовов:        " + pad(fmt(runs), 10) + "   \x1b[2m← так считает дашборд\x1b[0m");
  console.log("     коэффициент завышения:    " + pad(k.toFixed(2), 10));
  console.log("     в час: сырых " + fmt(rawPerHour) + ", настоящих " + fmt(realPerHour));

  if (k < 1.5 || k > 6) {
    console.log("");
    console.log("  \x1b[33mКоэффициент вне ожидаемого диапазона 2–5.\x1b[0m Метрика могла поменять");
    console.log("  поведение — порог по этому замеру лучше не ставить, покажите вывод.");
  }

  // Порог: темп, при котором за месяц набежит бесплатный лимит.
  const limitRealPerHour = FREE / HOURS;
  const limitRawPerHour = limitRealPerHour * (k || 3);
  const warn = Math.round(limitRawPerHour * 0.7 / 100) * 100;
  const alarm = Math.round(limitRawPerHour * 0.9 / 100) * 100;

  console.log("");
  console.log("  \x1b[1mчто поставить в алерте\x1b[0m");
  console.log("     Окно вычисления ........ 1 час");
  console.log("     Прореживание ........... Отключено");
  console.log("     Функция агрегации ...... Сумма");
  console.log("     Warning ................ \x1b[33m" + fmt(warn) + "\x1b[0m");
  console.log("     Alarm .................. \x1b[31m" + fmt(alarm) + "\x1b[0m");
  console.log("");
  console.log("  Это темп, при котором за месяц набежал бы миллион вызовов:");
  console.log("     " + fmt(limitRealPerHour) + " настоящих в час = " + fmt(limitRawPerHour) + " сырых.");
  console.log("     Warning на 70% от него, Alarm на 90%.");

  const margin = realPerHour ? limitRealPerHour / realPerHour : Infinity;
  console.log("");
  if (margin > 10) {
    console.log("  \x1b[32mСейчас вы идёте в " + Math.round(margin) + " раз медленнее порога.\x1b[0m");
    console.log("  Ложных срабатываний не будет: чтобы алерт зазвенел, поток должен");
    console.log("  вырасти в сотни раз — а это уже не рост клиентов, а поломка или перебор.");
  } else {
    console.log("  \x1b[33mЗапас всего в " + margin.toFixed(1) + " раза.\x1b[0m Стоит присмотреться: при таком темпе");
    console.log("  бесплатного лимита может не хватить.");
  }

  console.log("");
  console.log("  \x1b[2mпо функциям (настоящих вызовов за сутки)\x1b[0m");
  Object.entries(perFunc).map(([f, arr]) => {
    let n = 0, prev = -Infinity;
    arr.forEach(([t]) => { if (t - prev > 20000) n++; prev = t; });
    return [f, n];
  }).sort((a, b) => b[1] - a[1]).forEach(([f, n]) => {
    console.log("     " + f.padEnd(28) + pad(fmt(n), 8));
  });
' "$RAW"

echo ""
echo "${DIM}Скрипт ничего не менял: только читал метрики.${OFF}"
