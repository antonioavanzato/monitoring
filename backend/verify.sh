#!/usr/bin/env bash
#
# Сверка цифр дашборда с сырыми данными Monitoring.
#
#   ./verify.sh
#
# Печатает по каждому каталогу: сколько вызовов насчитано за календарный
# месяц, и разбивку по функциям — чтобы видеть, из чего складывается итог
# и не попали ли туда функции самого дашборда.
#
# IAM-токен берётся на лету и не печатается.

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'; GRN=$'\e[32m'

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

MONTH_START=$(date -u +%Y-%m-01T00:00:00Z)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Сумма за произвольное окно — чтобы сверять с биллингом,
# который мог начать собирать данные позже начала месяца.
window() {
  local token="$1" folder="$2" from="$3"
  curl -s -m 40 -X POST \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=${folder}" \
    -d "{\"query\":\"\\\"functions_finished\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$from\",\"toTime\":\"$NOW\",\"downsampling\":{\"maxPoints\":100,\"gridAggregation\":\"SUM\"}}" \
  | node -e '
      let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
        let j; try { j=JSON.parse(raw); } catch { console.log("ошибка"); return; }
        if (j.code) { console.log("ошибка API"); return; }
        const t=(j.metrics||[]).reduce((acc,m)=>{
          const ts=m.timeseries||{};
          return acc+(ts.doubleValues||ts.int64Values||[]).reduce((a,b)=>a+(Number(b)||0),0);
        },0);
        console.log(Math.round(t).toLocaleString("ru-RU"));
      });'
}

# Одна и та же сумма при разном числе точек? Если нет — виновата
# агрегация, а не данные.
probe() {
  local token="$1" folder="$2" metric="$3" points="$4"
  curl -s -m 40 -X POST \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=${folder}" \
    -d "{\"query\":\"\\\"${metric}\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$MONTH_START\",\"toTime\":\"$NOW\",\"downsampling\":{\"maxPoints\":${points},\"gridAggregation\":\"SUM\"}}" \
  | node -e '
      let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
        let j; try { j=JSON.parse(raw); } catch { console.log("ошибка"); return; }
        if (j.code) { console.log("ошибка API: "+(j.message||"")); return; }
        const t=(j.metrics||[]).reduce((acc,m)=>{
          const ts=m.timeseries||{};
          return acc+(ts.doubleValues||ts.int64Values||[]).reduce((a,b)=>a+(Number(b)||0),0);
        },0);
        console.log(Math.round(t).toLocaleString("ru-RU"));
      });'
}

check() {
  local label="$1" folder="$2" profile="$3"
  echo
  echo "${BLD}── $label${OFF}   каталог $folder"
  echo "   период: $MONTH_START → $NOW"

  yc config profile activate "$profile" >/dev/null 2>&1
  local token; token=$(yc iam create-token 2>/dev/null)
  [ -n "$token" ] || { echo "   не получить IAM-токен"; return; }

  echo
  echo "   ${YLW}зависимость суммы от числа точек${OFF} (у корректной суммы её быть не должно):"
  for pts in 10 100 1000 5000; do
    printf "     functions_finished, maxPoints=%-5s → %s\n" "$pts" "$(probe "$token" "$folder" functions_finished "$pts")"
  done
  echo "     functions_started,  maxPoints=100   → $(probe "$token" "$folder" functions_started 100)"
  echo
  echo "   ${YLW}по окнам${OFF} (для сверки с биллингом, если он считает не с начала месяца):"
  for d in 1 2 3 5 7 14; do
    local from
    from=$(date -u -v-${d}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$d days ago" +%Y-%m-%dT%H:%M:%SZ)
    printf "     последние %-3s дн. → %s\n" "$d" "$(window "$token" "$folder" "$from")"
  done
  echo "     с начала месяца   → $(probe "$token" "$folder" functions_finished 100)"
  echo

  local body
  body=$(curl -s -m 40 -X POST \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=${folder}" \
    -d "{\"query\":\"\\\"functions_finished\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$MONTH_START\",\"toTime\":\"$NOW\",\"downsampling\":{\"maxPoints\":100,\"gridAggregation\":\"SUM\"}}")

  # разбор ответа: сумма по каждому ряду + метка function
  echo "$body" | node -e '
    let raw=""; process.stdin.on("data",d=>raw+=d).on("end",()=>{
      let j; try { j=JSON.parse(raw); } catch { console.log("   не разобрать ответ:", raw.slice(0,200)); return; }
      if (j.code) { console.log("   ошибка API:", j.message||raw.slice(0,200)); return; }
      const own = ["cm-admin-api","cm-monitor-aggregator"];
      let total=0, ownTotal=0;
      const rows=(j.metrics||[]).map(m=>{
        const ts=m.timeseries||{};
        const vals=(ts.doubleValues||ts.int64Values||[]).map(Number);
        const sum=vals.reduce((a,b)=>a+(b||0),0);
        const name=m.labels?.function||m.labels?.resource_id||"(без метки)";
        const isOwn=own.some(o=>name.includes(o));
        total+=sum; if(isOwn) ownTotal+=sum;
        return {name,sum,isOwn};
      }).sort((a,b)=>b.sum-a.sum);

      rows.forEach(r=>console.log("     "+String(Math.round(r.sum)).padStart(9)+"  "+r.name+(r.isOwn?"   <- сам дашборд":"")));
      console.log("   ─────");
      console.log("   всего в каталоге: "+Math.round(total).toLocaleString("ru-RU"));
      console.log("   из них дашборд:   "+Math.round(ownTotal).toLocaleString("ru-RU"));
      console.log("   \x1b[1mдолжно быть на карточке: "+Math.round(total-ownTotal).toLocaleString("ru-RU")+"\x1b[0m");
    });'
}

for pair in "Avanzato:b1gvs59n7rkplk5jmu21" "ALGA:b1gjcf3ucce90qgigaii" "Daria:b1gfon9pe6vpmlgaq0f7"; do
  label=${pair%%:*}; folder=${pair#*:}
  prof=$(find_profile "$folder")
  [ -z "$prof" ] && { echo; echo "${YLW}── $label: нет профиля, пропускаю${OFF}"; continue; }
  check "$label" "$folder" "$prof"
done

echo
echo "${BLD}Сверьте последнюю строку по каждому проекту с цифрой на карточке.${OFF}"
echo "Если сходится — дашборд считает верно."
