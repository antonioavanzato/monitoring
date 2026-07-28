#!/usr/bin/env bash
#
# Сырые ряды метрики за короткое окно, со всеми метками. Только чтение.
#
#   ./raw-series.sh [метрика] [минут]
#   ./raw-series.sh functions_finished 20
#
# Зачем: логи за 15 минут показывают 6 вызовов hub-api, а метрика за тот же
# период — около 26. И отдельно: метрика даёт 54 000 вызовов за месяц против
# 20 000 в биллинге. Если на один вызов приходится несколько рядов, сложение
# завышает итог — здесь это видно поимённо.

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'

METRIC=${1:-functions_finished}
MINUTES=${2:-20}
FOLDER=${3:-b1gvs59n7rkplk5jmu21}

cd "$(dirname "$0")" || exit 1

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')
ORIG=$(yc config profile list 2>/dev/null | grep ACTIVE | awk '{print $1}')
trap '[ -n "${ORIG:-}" ] && yc config profile activate "$ORIG" >/dev/null 2>&1' EXIT

for p in $PROFILES; do
  yc config profile activate "$p" >/dev/null 2>&1 || continue
  yc resource-manager folder get "$FOLDER" >/dev/null 2>&1 && break
done

TOKEN=$(yc iam create-token 2>/dev/null)
[ -n "$TOKEN" ] || { echo "не получить IAM-токен"; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FROM=$(date -u -v-"${MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$MINUTES minutes ago" +%Y-%m-%dT%H:%M:%SZ)

echo "${BLD}$METRIC, каталог $FOLDER, последние $MINUTES мин${OFF}"
echo "  $FROM → $NOW"

curl -s -m 40 -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=$FOLDER" \
  -d "{\"query\":\"\\\"$METRIC\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$FROM\",\"toTime\":\"$NOW\",\"downsampling\":{\"gridInterval\":60000,\"gridAggregation\":\"SUM\"}}" \
| node -e '
  let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
    let j; try { j=JSON.parse(raw); } catch { console.log("не разобрать ответ:", raw.slice(0,300)); return; }
    if (j.code) { console.log("ошибка API:", j.message || raw.slice(0,300)); return; }

    const series = (j.metrics || []).map(m => {
      const ts = m.timeseries || {};
      const v = (ts.doubleValues || ts.int64Values || []).map(Number);
      return {
        labels: m.labels || {},
        type: m.type,
        sum: v.reduce((a,b) => a + (b||0), 0),
        points: v.filter(x => x > 0).length
      };
    }).filter(s => s.sum > 0).sort((a,b) => b.sum - a.sum);

    if (!series.length) { console.log("  за этот период рядов с данными нет"); return; }

    console.log("");
    console.log("  \x1b[1mряды с ненулевыми значениями\x1b[0m");
    series.forEach(s => {
      const keys = Object.keys(s.labels).sort();
      const desc = keys.map(k => k + "=" + s.labels[k]).join("  ");
      console.log("     " + String(Math.round(s.sum)).padStart(6) +
                  "  точек " + String(s.points).padStart(3) +
                  "  " + desc);
    });

    const total = series.reduce((a,s) => a + s.sum, 0);
    console.log("     ─────");
    console.log("     " + String(Math.round(total)).padStart(6) + "  ИТОГО (так считает дашборд)");

    // Группируем по функции: если у одной функции несколько рядов с
    // одинаковыми суммами — это одни и те же вызовы, посчитанные дважды.
    const byFunc = {};
    series.forEach(s => {
      const f = s.labels.function || s.labels.resource_id || "(без метки)";
      (byFunc[f] = byFunc[f] || []).push(s);
    });

    console.log("");
    console.log("  \x1b[1mпо функциям\x1b[0m");
    Object.entries(byFunc).forEach(([f, list]) => {
      const sum = list.reduce((a,s) => a + s.sum, 0);
      const max = Math.max(...list.map(s => s.sum));
      console.log("     " + f);
      console.log("        рядов: " + list.length +
                  ", сумма: " + Math.round(sum) +
                  ", наибольший ряд: " + Math.round(max));
      if (list.length > 1) {
        const distinct = [...new Set(list.map(s => Math.round(s.sum)))];
        console.log("        суммы рядов: " + list.map(s => Math.round(s.sum)).join(", ") +
                    (distinct.length === 1 ? "  \x1b[33m← одинаковые: похоже на дубли\x1b[0m" : ""));
        // чем ряды отличаются
        const allKeys = [...new Set(list.flatMap(s => Object.keys(s.labels)))];
        const varying = allKeys.filter(k => new Set(list.map(s => s.labels[k])).size > 1);
        console.log("        различаются метками: " + (varying.join(", ") || "ничем"));
      }
    });

    console.log("");
    console.log("  Сверьте с логами: сколько вызовов было на самом деле за это окно.");
    console.log("  Если сумма заметно больше, а ряды одной функции различаются");
    console.log("  только версией — значит складывать их нельзя.");
  });'

echo
echo "${BLD}Сами точки ряда, шаг 15 секунд${OFF}"
echo "  Если внутри одной минуты значение повторяется — это счётчик за период,"
echo "  а не приращение, и складывать точки нельзя: получится завышение в 4 раза."

curl -s -m 40 -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=$FOLDER" \
  -d "{\"query\":\"\\\"$METRIC\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$FROM\",\"toTime\":\"$NOW\",\"downsampling\":{\"disabled\":true}}" \
| node -e '
  let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
    let j; try { j=JSON.parse(raw); } catch { console.log("  не разобрать ответ:", raw.slice(0,200)); return; }
    if (j.code) {
      console.log("  без даунсэмплинга API отказал (" + (j.message||"") + "), беру шаг 15 секунд");
      return;
    }
    (j.metrics || []).forEach(m => {
      const ts = m.timeseries || {};
      const v = (ts.doubleValues || ts.int64Values || []).map(Number);
      const t = ts.timestamps || [];
      const name = m.labels?.function || m.labels?.resource_id || "?";
      const nonZero = v.filter(x => x > 0).length;
      if (!nonZero) return;
      console.log("");
      console.log("  " + name + " — точек " + v.length + ", ненулевых " + nonZero +
                  ", сумма " + Math.round(v.reduce((a,b)=>a+(b||0),0)));
      const last = Math.max(0, v.length - 40);
      for (let i = last; i < v.length; i++) {
        if (!(v[i] > 0)) continue;
        console.log("     " + new Date(Number(t[i])).toISOString().slice(11,19) + "   " + v[i]);
      }
    });
  });'
