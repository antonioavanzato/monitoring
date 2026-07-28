#!/usr/bin/env bash
#
# Кто получает ошибки: пинг или живые клиенты. Только чтение.
#
#   ./who-errors.sh [функция] [часов]
#   ./who-errors.sh hub-api 24
#
# Пинг ходит строго раз в ~3 минуты, обращения клиентов — вразнобой.
# Берём сырые точки вызовов и ошибок, восстанавливаем ритм пинга и смотрим,
# на какие вызовы пришлись ошибки: на ритмичные (пинг) или на выпадающие
# из ритма (клиенты).

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'; GRN=$'\e[32m'; RED=$'\e[31m'

FUNC=${1:-hub-api}
HOURS=${2:-24}
FOLDER=${3:-b1gvs59n7rkplk5jmu21}

cd "$(dirname "$0")" || exit 1

PROFILES=$(yc config profile list 2>/dev/null | sed 's/ ACTIVE//' | awk '{print $1}')
ORIG=$(yc config profile list 2>/dev/null | grep ACTIVE | awk '{print $1}')
trap '[ -n "${ORIG:-}" ] && yc config profile activate "$ORIG" >/dev/null 2>&1' EXIT

for p in $PROFILES; do
  yc config profile activate "$p" >/dev/null 2>&1 || continue
  [ "$(yc config get folder-id 2>/dev/null)" = "$FOLDER" ] && break
done

TOKEN=$(yc iam create-token 2>/dev/null)
[ -n "$TOKEN" ] || { echo "не получить IAM-токен"; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FROM=$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$HOURS hours ago" +%Y-%m-%dT%H:%M:%SZ)

get() {
  curl -s -m 60 -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=$FOLDER" \
    -d "{\"query\":\"\\\"$1\\\"{service=\\\"serverless-functions\\\"}\",\"fromTime\":\"$FROM\",\"toTime\":\"$NOW\",\"downsampling\":{\"disabled\":true}}"
}

echo "${BLD}$FUNC, последние $HOURS ч${OFF}"
echo "  $FROM → $NOW"

CALLS=$(get functions_finished)
ERRS=$(get functions_errors)

CM_FUNC="$FUNC" node -e '
  const [callsRaw, errsRaw] = process.argv.slice(1);
  const FUNC = process.env.CM_FUNC;
  const parse = (s) => { try { return JSON.parse(s); } catch { return {metrics:[]}; } };
  const nameOf = m => m.labels?.function || m.labels?.resource_id || "";
  const vals = ts => (ts?.doubleValues || ts?.int64Values || []).map(Number);

  // Точки нужной функции → серии подряд идущих отсчётов = отдельные события
  const runsOf = (payload) => {
    const pts = [];
    (payload.metrics || []).filter(m => nameOf(m) === FUNC).forEach(m => {
      const v = vals(m.timeseries), t = m.timeseries?.timestamps || [];
      v.forEach((x, i) => { if (x > 0) pts.push([Number(t[i]), x]); });
    });
    pts.sort((a,b) => a[0] - b[0]);
    const runs = [];
    let prev = -Infinity;
    pts.forEach(([t, v]) => {
      if (t - prev > 20000) runs.push({ t, peak: v });
      else runs[runs.length-1].peak = Math.max(runs[runs.length-1].peak, v);
      prev = t;
    });
    return runs;
  };

  const calls = runsOf(parse(callsRaw));
  const errs  = runsOf(parse(errsRaw));

  if (!calls.length) { console.log("\n  вызовов за период нет"); process.exit(0); }

  console.log("");
  console.log("  вызовов: " + calls.length + ", событий с ошибками: " + errs.length);

  // ── ритм пинга: самый частый интервал между вызовами ──
  const gaps = [];
  for (let i = 1; i < calls.length; i++) gaps.push(Math.round((calls[i].t - calls[i-1].t) / 1000));
  const hist = {};
  gaps.forEach(g => { const k = Math.round(g / 10) * 10; hist[k] = (hist[k]||0) + 1; });
  const top = Object.entries(hist).sort((a,b) => b[1]-a[1]).slice(0, 4);
  console.log("  частые интервалы между вызовами (сек → сколько раз): " +
              top.map(([k,v]) => k + "→" + v).join("  "));

  const period = Number(top[0][0]);
  if (!period) { console.log("  не удалось определить ритм"); process.exit(0); }
  console.log("  ритм пинга принят за " + period + " сек");

  // Вызов считаем пингом, если он отстоит от предыдущего примерно на период
  const TOL = Math.max(20, period * 0.2) * 1000;
  const isPing = calls.map((c, i) => {
    if (i === 0) return true;
    const g = c.t - calls[i-1].t;
    return Math.abs(g - period * 1000) <= TOL;
  });
  const pings = isPing.filter(Boolean).length;
  console.log("  из них похожи на пинг: " + pings +
              ", выпадают из ритма (клиенты): " + (calls.length - pings));

  // ── к каким вызовам пришлись ошибки ──
  let onPing = 0, onClient = 0, orphan = 0;
  const detail = [];
  errs.forEach(e => {
    let best = -1, bestD = Infinity;
    calls.forEach((c, i) => {
      const d = Math.abs(c.t - e.t);
      if (d < bestD) { bestD = d; best = i; }
    });
    if (best < 0 || bestD > 90000) { orphan++; return; }
    if (isPing[best]) onPing++; else onClient++;
    detail.push({ t: e.t, ping: isPing[best], gap: best > 0 ? Math.round((calls[best].t - calls[best-1].t)/1000) : null });
  });

  console.log("");
  console.log("  \x1b[1mчьи это ошибки\x1b[0m");
  console.log("     на вызовах в ритме пинга:      " + onPing);
  console.log("     на выпадающих из ритма:        " + onClient);
  if (orphan) console.log("     не удалось сопоставить:        " + orphan);

  if (detail.length) {
    console.log("");
    console.log("  последние ошибки (время UTC → пауза перед вызовом → чей)");
    detail.slice(-15).forEach(d => {
      console.log("     " + new Date(d.t).toISOString().slice(11,19) +
                  "   " + (d.gap === null ? "  —" : String(d.gap).padStart(4) + " сек") +
                  "   " + (d.ping ? "\x1b[33mпинг\x1b[0m" : "\x1b[31mклиент\x1b[0m"));
    });
  }

  console.log("");
  if (onClient === 0 && onPing > 0) {
    console.log("  \x1b[32mВсе ошибки пришлись на пинг.\x1b[0m Клиенты их не видят —");
    console.log("  уберёте пинг, и ошибки уйдут вместе с ним.");
  } else if (onClient > 0) {
    console.log("  \x1b[31mЕсть ошибки на вызовах вне ритма пинга.\x1b[0m Похоже, их получают");
    console.log("  живые клиенты — тогда ускорение холодного старта имеет смысл.");
  } else {
    console.log("  Ошибок за период не нашлось — возьмите окно побольше.");
  }
' "$CALLS" "$ERRS"
