#!/usr/bin/env bash
#
# Разведка по холодным стартам. Ничего не меняет — только читает метрики.
#
#   ./coldstart.sh
#
# Отвечает на три вопроса:
#   1. У каких функций высокая доля холодных стартов (а не «в среднем по каталогу»)
#   2. Как часто функцию зовут — экземпляр может просто не доживать до следующего вызова
#   3. Приходят ли вызовы пачками — тогда каждый параллельный запрос поднимает свой экземпляр

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'; GRN=$'\e[32m'; RED=$'\e[31m'

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

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
D1=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ)
H6=$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "6 hours ago" +%Y-%m-%dT%H:%M:%SZ)

fetch() {   # token folder metric from to downsamplingJson
  curl -s -m 40 -X POST \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=$2" \
    -d "{\"query\":\"\\\"$3\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$4\",\"toTime\":\"$5\",\"downsampling\":$6}"
}

analyse() {
  local label="$1" folder="$2" profile="$3"
  echo
  echo "${BLD}════ $label ════${OFF}  каталог $folder"

  yc config profile activate "$profile" >/dev/null 2>&1
  local token; token=$(yc iam create-token 2>/dev/null)
  [ -n "$token" ] || { echo "  не получить IAM-токен"; return; }

  local flat='{"maxPoints":100,"gridAggregation":"SUM"}'
  local minute='{"gridInterval":60000,"gridAggregation":"SUM"}'

  local done24 init24 doneMin initMin
  done24=$(fetch "$token" "$folder" functions_finished "$D1" "$NOW" "$flat")
  init24=$(fetch "$token" "$folder" functions_inits    "$D1" "$NOW" "$flat")
  doneMin=$(fetch "$token" "$folder" functions_finished "$H6" "$NOW" "$minute")
  initMin=$(fetch "$token" "$folder" functions_inits    "$H6" "$NOW" "$minute")

  node -e '
    const [done24, init24, doneMin, initMin] = process.argv.slice(1).map(s => {
      try { return JSON.parse(s); } catch { return {metrics:[]}; }
    });
    const OWN = ["cm-admin-api","cm-monitor-aggregator"];
    const nameOf = m => m.labels?.function || m.labels?.resource_id || "(без метки)";
    const vals = ts => (ts?.doubleValues || ts?.int64Values || []).map(Number);

    // ── 1. по функциям: вызовы против инициализаций ───────────────
    const agg = payload => {
      const by = {};
      (payload.metrics || []).forEach(m => {
        const n = nameOf(m);
        by[n] = (by[n] || 0) + vals(m.timeseries).reduce((a,b) => a + (b||0), 0);
      });
      return by;
    };
    const D = agg(done24), I = agg(init24);

    const rows = Object.keys(D)
      .filter(n => D[n] >= 10)
      .map(n => ({ n, done: D[n], init: I[n] || 0, pct: (I[n]||0) / D[n] * 100 }))
      .sort((a,b) => b.done - a.done);

    console.log("");
    console.log("  \x1b[1mдоля холодных стартов за сутки, по функциям\x1b[0m");
    console.log("     вызовов   стартов   доля   функция");
    rows.forEach(r => {
      const mark = OWN.includes(r.n) ? "  (дашборд)" : "";
      const col = r.pct >= 80 ? "\x1b[31m" : r.pct >= 40 ? "\x1b[33m" : "\x1b[32m";
      console.log("     " + String(Math.round(r.done)).padStart(7) +
                  "   " + String(Math.round(r.init)).padStart(7) +
                  "   " + col + (r.pct.toFixed(0) + "%").padStart(4) + "\x1b[0m" +
                  "   " + r.n + mark);
    });

    // ── 2. ритм вызовов за 6 часов, по минутам ────────────────────
    const perMinute = payload => {
      const by = {};
      (payload.metrics || []).forEach(m => {
        const n = nameOf(m);
        const v = vals(m.timeseries);
        const t = m.timeseries?.timestamps || [];
        by[n] = by[n] || new Map();
        v.forEach((x, i) => {
          if (!(x > 0)) return;
          const key = Math.floor(Number(t[i]) / 60000);
          by[n].set(key, (by[n].get(key) || 0) + x);
        });
      });
      return by;
    };
    const DM = perMinute(doneMin), IM = perMinute(initMin);

    const top = rows.filter(r => !OWN.includes(r.n)).slice(0, 3);
    top.forEach(r => {
      const mins = [...(DM[r.n] || new Map()).keys()].sort((a,b) => a-b);
      if (mins.length < 2) return;

      const gaps = [];
      for (let i = 1; i < mins.length; i++) gaps.push(mins[i] - mins[i-1]);
      gaps.sort((a,b) => a-b);
      const med = gaps[Math.floor(gaps.length/2)];
      const counts = [...(DM[r.n] || new Map()).values()].sort((a,b) => b-a);

      console.log("");
      console.log("  \x1b[1m" + r.n + "\x1b[0m — ритм за последние 6 часов");
      console.log("     активных минут:        " + mins.length + " из 360");
      console.log("     пауза между вызовами:  медиана " + med + " мин, минимум " +
                  gaps[0] + ", максимум " + gaps[gaps.length-1]);
      console.log("     вызовов в минуту:      максимум " + Math.round(counts[0]) +
                  ", обычно " + Math.round(counts[Math.floor(counts.length/2)]));
      const initsHere = [...(IM[r.n] || new Map()).values()].reduce((a,b)=>a+b,0);
      const doneHere  = [...(DM[r.n] || new Map()).values()].reduce((a,b)=>a+b,0);
      console.log("     за 6 часов:            " + Math.round(doneHere) + " вызовов, " +
                  Math.round(initsHere) + " инициализаций");

      // распределение пауз — сразу видно, есть ли типичный интервал
      const hist = {};
      gaps.forEach(g => { const k = g >= 10 ? "10+" : String(g); hist[k] = (hist[k]||0)+1; });
      console.log("     распределение пауз (мин → сколько раз): " +
                  Object.entries(hist).map(([k,v]) => k + "→" + v).join("  "));
    });
  ' "$done24" "$init24" "$doneMin" "$initMin"
}

for pair in "Avanzato:b1gvs59n7rkplk5jmu21" "ALGA:b1gjcf3ucce90qgigaii" "Daria:b1gfon9pe6vpmlgaq0f7"; do
  label=${pair%%:*}; folder=${pair#*:}
  prof=$(find_profile "$folder")
  [ -z "$prof" ] && { echo; echo "${YLW}════ $label: нет профиля, пропускаю${OFF}"; continue; }
  analyse "$label" "$folder" "$prof"
done

echo
echo "${BLD}Как читать${OFF}"
echo "  Если пауза между вызовами стабильно больше пары минут, а доля холодных"
echo "  стартов близка к 100% — экземпляр просто не доживает до следующего вызова."
echo "  Если вызовов в минуту заметно больше одного — запросы идут параллельно,"
echo "  и каждый поднимает свой экземпляр; тогда частота пингов ни при чём."
