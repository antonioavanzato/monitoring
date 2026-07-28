#!/usr/bin/env bash
#
# Разбор логов функции по каждому вызову. Ничего не меняет — только читает.
#
#   ./coldstart-logs.sh [имя-функции] [период]
#   ./coldstart-logs.sh hub-api 3h
#
# Метрики дают агрегаты и уже показали, что дело ни в редкости вызовов
# (пауза ~35 секунд), ни в параллельности (одновременно всегда один экземпляр).
# Логи дают факты по каждому вызову: был ли он холодным и сколько прошло
# с предыдущего. Отсюда видно, сколько на самом деле живёт экземпляр.

set -uo pipefail
BLD=$'\e[1m'; OFF=$'\e[0m'; YLW=$'\e[33m'

FUNC=${1:-hub-api}
SINCE=${2:-3h}

cd "$(dirname "$0")" || exit 1

echo "${BLD}Читаю логи $FUNC за $SINCE${OFF}"

# yc на свежем окне догоняет настоящее время и переходит в слежение, не
# завершаясь. Поэтому читаем в фоне и через WAIT секунд забираем что успело
# прийти. Своего таймаута у yc нет, а GNU timeout в macOS отсутствует.
WAIT=${CM_WAIT:-25}
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

yc serverless function logs "$FUNC" --since "$SINCE" > "$TMP" 2>&1 &
YCPID=$!
( sleep "$WAIT"; kill "$YCPID" 2>/dev/null ) >/dev/null 2>&1 &
KILLER=$!
wait "$YCPID" 2>/dev/null
kill "$KILLER" 2>/dev/null

LOGS=$(cat "$TMP")
echo "  получено строк: $(printf '%s\n' "$LOGS" | wc -l | tr -d ' ')"

if echo "$LOGS" | grep -q "ERROR:\|not found"; then
  echo "$LOGS" | head -3
  echo
  echo "Проверьте имя функции: yc serverless function list"
  exit 1
fi

echo "$LOGS" | CM_FUNC="$FUNC" node -e '
  let raw = "";
  process.stdin.on("data", d => raw += d).on("end", () => {
    const lines = raw.split("\n");

    // START даёт время вызова и версию, REPORT — был ли холодный старт
    const starts = new Map();   // requestId -> {t, version}
    const reports = [];         // {id, t, cold, initMs, durMs, memMb}

    lines.forEach(l => {
      const ts = l.match(/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
      if (!ts) return;
      const t = Date.parse(ts[1].replace(" ", "T") + "Z");

      const s = l.match(/START RequestID: (\S+)(?:.*Version: (\S+))?/);
      if (s) { starts.set(s[1], { t, version: s[2] || "?" }); return; }

      const r = l.match(/REPORT RequestID: (\S+)/);
      if (!r) return;
      const init = l.match(/Function Init Duration: ([\d.]+) ms/);
      const dur  = l.match(/\bDuration: ([\d.]+) ms/);
      const mem  = l.match(/Memory Size: (\d+) MB/);
      reports.push({
        id: r[1], t,
        cold: !!init,
        initMs: init ? parseFloat(init[1]) : 0,
        durMs: dur ? parseFloat(dur[1]) : 0,
        memMb: mem ? parseInt(mem[1], 10) : 0
      });
    });

    if (!reports.length) {
      console.log("Не нашёл строк REPORT — возможно, за этот период вызовов не было.");
      return;
    }

    // упорядочиваем по времени старта
    const calls = reports
      .map(r => ({ ...r, start: starts.get(r.id)?.t ?? r.t, version: starts.get(r.id)?.version || "?" }))
      .sort((a, b) => a.start - b.start);

    const cold = calls.filter(c => c.cold).length;
    console.log("");
    console.log("  \x1b[1mвсего вызовов: " + calls.length +
                ", холодных: " + cold +
                " (" + (cold / calls.length * 100).toFixed(0) + "%)\x1b[0m");

    // CLI отдаёт логи страницами и молча обрезает. Если окно в логах короче
    // запрошенного или обрывается задолго до «сейчас» — выборка неполная,
    // и делать по ней выводы нельзя.
    const first = calls[0].start, last = calls[calls.length-1].start;
    const spanMin = (last - first) / 60000;
    const staleMin = (Date.now() - last) / 60000;
    console.log("  окно в логах: " + new Date(first).toISOString().slice(11,19) +
                " – " + new Date(last).toISOString().slice(11,19) + " UTC" +
                " (" + spanMin.toFixed(0) + " мин), последняя запись " +
                staleMin.toFixed(0) + " мин назад");

    if (staleMin > 10) {
      console.log("");
      console.log("  \x1b[33m! Выборка обрезана\x1b[0m: логи заканчиваются задолго до текущего момента,");
      console.log("    то есть CLI вернул только часть записей. Возьмите окно поменьше,");
      console.log("    например ./coldstart-logs.sh " + (process.env.CM_FUNC || "hub-api") + " 20m,");
      console.log("    и сверьте число вызовов с тем, что показывает ./coldstart.sh");
    }

    const versions = [...new Set(calls.map(c => c.version))];
    console.log("  версий в выборке: " + versions.length + " — " + versions.join(", "));
    const mems = [...new Set(calls.map(c => c.memMb))].filter(Boolean);
    if (mems.length) console.log("  память: " + mems.join(", ") + " МБ");

    // ── главное: пауза перед вызовом против того, холодный он или тёплый ──
    const buckets = [
      [0, 10, "менее 10 сек"], [10, 30, "10–30 сек"], [30, 60, "30–60 сек"],
      [60, 120, "1–2 мин"], [120, 300, "2–5 мин"], [300, 1e9, "более 5 мин"]
    ];
    const stat = buckets.map(b => ({ label: b[2], lo: b[0], hi: b[1], cold: 0, warm: 0 }));

    for (let i = 1; i < calls.length; i++) {
      const gapSec = (calls[i].start - calls[i-1].start) / 1000;
      const b = stat.find(x => gapSec >= x.lo && gapSec < x.hi);
      if (!b) continue;
      if (calls[i].cold) b.cold++; else b.warm++;
    }

    console.log("");
    console.log("  \x1b[1mпауза перед вызовом → холодный или тёплый\x1b[0m");
    console.log("     пауза            тёплых   холодных   доля холодных");
    stat.forEach(b => {
      const n = b.cold + b.warm;
      if (!n) return;
      const pct = (b.cold / n * 100).toFixed(0);
      const col = pct >= 80 ? "\x1b[31m" : pct >= 40 ? "\x1b[33m" : "\x1b[32m";
      console.log("     " + b.label.padEnd(15) +
                  String(b.warm).padStart(6) +
                  String(b.cold).padStart(11) +
                  "   " + col + (pct + "%").padStart(4) + "\x1b[0m");
    });

    console.log("");
    console.log("  Если тёплые встречаются только при коротких паузах — это и есть");
    console.log("  время жизни экземпляра. Если холодные равномерно во всех строках,");
    console.log("  экземпляр не переиспользуется вообще, и причина внутри функции.");

    // ── длительность: сколько стоит холодный старт ──
    const avg = a => a.length ? a.reduce((x,y) => x+y, 0) / a.length : 0;
    const coldD = calls.filter(c => c.cold);
    const warmD = calls.filter(c => !c.cold);
    console.log("");
    console.log("  \x1b[1mдлительность\x1b[0m");
    console.log("     холодный вызов: " + avg(coldD.map(c => c.durMs)).toFixed(0) + " мс" +
                " (из них инициализация " + avg(coldD.map(c => c.initMs)).toFixed(0) + " мс)");
    if (warmD.length) {
      console.log("     тёплый вызов:   " + avg(warmD.map(c => c.durMs)).toFixed(0) + " мс");
    } else {
      console.log("     тёплых вызовов в выборке нет");
    }

    // ── последние 20 вызовов подряд, чтобы увидеть картину глазами ──
    console.log("");
    console.log("  \x1b[1mпоследние 20 вызовов\x1b[0m (пауза → тип, длительность)");
    calls.slice(-20).forEach((c, i, arr) => {
      const prev = i > 0 ? arr[i-1] : null;
      const gap = prev ? ((c.start - prev.start) / 1000).toFixed(0) + " сек" : "—";
      console.log("     " + new Date(c.start).toISOString().slice(11,19) +
                  "   пауза " + gap.padStart(8) +
                  "   " + (c.cold ? "\x1b[31mхолодный\x1b[0m" : "\x1b[32mтёплый  \x1b[0m") +
                  "   " + c.durMs.toFixed(0) + " мс");
    });
  });
'
