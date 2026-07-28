/**
 * monitor-aggregator — собирает метрики Cloud Functions по трём проектам.
 *
 * Переменные окружения:
 *   SA_KEY_AVANZATO / SA_KEY_ALGA / SA_KEY_DARIA — JSON авторизованного ключа СА в base64
 *   FOLDER_AVANZATO / FOLDER_ALGA / FOLDER_DARIA — folderId
 *   JWT_SECRET      — тот же, что у admin-api
 *   ALLOWED_ORIGIN  — https://antonioavanzato.github.io
 *   FREE_TIER_CALLS — необязательно, по умолчанию 1000000
 */
const jwt = require('jsonwebtoken');

const SECRET = process.env.JWT_SECRET;
const ORIGIN = process.env.ALLOWED_ORIGIN || 'https://antonioavanzato.github.io';
const LIMIT = Number(process.env.FREE_TIER_CALLS) || 1_000_000;
const ISSUER = 'cloud-monitor';

// Идентификаторы самих функций дашборда — их вызовы не должны попадать в
// показания. Приходят из setup.sh списком через запятую.
const EXCLUDE = (process.env.EXCLUDE_FUNCTIONS || '')
  .split(',').map((s) => s.trim()).filter(Boolean);

// Ответ живёт минуту: несколько открытых вкладок или частые потягивания
// не должны умножать обращения к Monitoring API.
const CACHE_TTL = 60_000;
let cache = null;

const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Vary': 'Origin'
};

// ---------- IAM ----------

const iamCache = new Map();   // keyId -> { token, exp }

async function iamToken(saKeyBase64) {
  const key = JSON.parse(Buffer.from(saKeyBase64, 'base64').toString('utf8'));

  const cached = iamCache.get(key.id);
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;

  const now = Math.floor(Date.now() / 1000);
  const assertion = jwt.sign(
    {
      iss: key.service_account_id,
      aud: 'https://iam.api.cloud.yandex.net/iam/v1/tokens',
      iat: now,
      exp: now + 3600
    },
    key.private_key,
    { algorithm: 'PS256', keyid: key.id }
  );

  const res = await fetch('https://iam.api.cloud.yandex.net/iam/v1/tokens', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jwt: assertion })
  });
  if (!res.ok) throw new Error('IAM ' + res.status + ' ' + (await res.text()));

  const { iamToken: token } = await res.json();
  iamCache.set(key.id, { token, exp: Date.now() + 50 * 60_000 });   // токен живёт 12 ч, освежаем чаще
  return token;
}

// ---------- Monitoring ----------

async function readMetric(iam, folderId, query, from, to, downsampling) {
  const res = await fetch(
    'https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=' + folderId,
    {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + iam, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query,
        fromTime: from.toISOString(),
        toTime: to.toISOString(),
        // maxPoints меньше 10 API отвергает ("too few points"). Берём с запасом
        // и складываем все точки: каждая — сумма своего интервала, значит
        // сумма точек и есть итог за period.
        downsampling: downsampling || { maxPoints: 100, gridAggregation: 'SUM' }
      })
    });
  if (!res.ok) throw new Error('Monitoring ' + res.status + ' ' + (await res.text()));
  return res.json();
}

const values = (ts) => (ts?.doubleValues || ts?.int64Values || []).map(Number);

/**
 * Поправочный коэффициент к сумме точек.
 *
 * functions_finished — счётчик за скользящую минуту, который Monitoring
 * отдаёт каждые 15 секунд. Один вызов поэтому виден в нескольких подряд
 * идущих точках, и простая сумма завышает итог в 3–4 раза. Проверено на
 * живых данных: за 20 минут сумма точек дала 22 при семи вызовах в логах.
 *
 * Точный способ — считать серии подряд идущих непустых точек, но сырое
 * разрешение доступно лишь на коротком окне: за месяц это сотни тысяч
 * точек. Поэтому коэффициент измеряем на свежем часе и применяем к длинным
 * периодам. Он пересчитывается при каждом обновлении, так что подстроится,
 * если характер трафика изменится.
 *
 * Возвращает null, если измерить не вышло — тогда поправка не применяется
 * и поведение остаётся прежним.
 */
function calibrate(payload) {
  const points = [];
  (payload.metrics || []).filter((m) => !isOwn(m)).forEach((m) => {
    const v = values(m.timeseries);
    const t = m.timeseries?.timestamps || [];
    v.forEach((x, i) => { if (x > 0) points.push([Number(t[i]), x]); });
  });
  if (points.length < 8) return null;          // мало данных — не гадаем

  points.sort((a, b) => a[0] - b[0]);

  let runs = 0, prevT = -Infinity;
  let sum = 0;
  points.forEach(([t, v]) => {
    // разрыв больше 20 секунд разделяет серии: шаг отдачи — 15 секунд
    if (t - prevT > 20000) runs++;
    prevT = t;
    sum += v;
  });

  if (runs === 0) return null;
  const k = sum / runs;

  // Защита от нелепых значений: поправка не должна превращаться в фантазию.
  if (!isFinite(k) || k < 1 || k > 6) return null;
  return k;
}

// Ряд принадлежит самому дашборду? Отсеиваем по метке в ответе, а не
// селектором в запросе: "function!=..." выбрасывает заодно все ряды, у
// которых метки function нет вовсе, и данные пропадали целиком.
const isOwn = (m) => {
  const f = m.labels?.function || m.labels?.resource_id || '';
  return EXCLUDE.includes(f);
};

const sumAll = (payload) =>
  (payload.metrics || [])
    .filter((m) => !isOwn(m))
    .reduce((acc, m) => acc + values(m.timeseries).reduce((a, b) => a + (b || 0), 0), 0);

async function collect(key, saKeyBase64, folderId) {
  const iam = await iamToken(saKeyBase64);

  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const d30 = new Date(now.getTime() - 30 * 864e5);
  const hourAgo = new Date(now.getTime() - 36e5);

  // Каталог задаётся параметром folderId в URL. Меткой folderId у метрик нет —
  // селектор с ней не совпадал ни с чем, и ответ приходил пустым без ошибки.
  // Собственные функции дашборда отфильтровываются уже из ответа, см. isOwn.
  const q = (name) => `"${name}"{service="serverless-functions"}`;

  const read = (name, from, to, downsampling) =>
    readMetric(iam, folderId, q(name), from, to, downsampling);

  const d1 = new Date(now.getTime() - 864e5);
  const calibFrom = new Date(now.getTime() - 36e5);

  const [calls, errors, errors24h, inits24h, finished24h, recent, calibRaw] = await Promise.all([
    read('functions_finished', monthStart, now),
    read('functions_errors', d30, now),
    // за сутки — чтобы отличить «сломано сейчас» от «починили две недели назад»:
    // тридцатидневный счётчик держит старые ошибки ещё месяц после починки
    read('functions_errors', d1, now),
    // инициализации против вызовов за те же сутки: доля холодных стартов
    // показывает, доживает ли инстанс до следующего обращения
    read('functions_inits', d1, now),
    read('functions_finished', d1, now),
    // минутная сетка за последний час — ищем последнюю непустую точку (keep-warm)
    read('functions_finished', hourAgo, now,
         { gridInterval: 60_000, gridAggregation: 'SUM' }),
    // сырые точки за час — по ним измеряем поправочный коэффициент
    read('functions_finished', calibFrom, now, { disabled: true })
  ]);

  const k = calibrate(calibRaw);
  // Без измерения оставляем как было: завышенно, но не выдумано.
  const fix = (n) => (k ? Math.round(n / k) : Math.round(n));

  const done24 = sumAll(finished24h);
  const cold24 = sumAll(inits24h);

  let lastInvocationAt = null;
  for (const m of (recent.metrics || []).filter((x) => !isOwn(x))) {
    const vals = values(m.timeseries);
    const stamps = m.timeseries?.timestamps || [];
    for (let i = vals.length - 1; i >= 0; i--) {
      if (vals[i] > 0) {
        const t = new Date(Number(stamps[i])).toISOString();
        if (!lastInvocationAt || t > lastInvocationAt) lastInvocationAt = t;
        break;
      }
    }
  }

  return {
    key,
    folderId,
    calls: fix(sumAll(calls)),
    limit: LIMIT,
    errors30d: fix(sumAll(errors)),
    errors24h: fix(sumAll(errors24h)),
    calls24h: fix(done24),
    coldStarts24h: fix(cold24),
    // для сверки: сырая сумма и применённый коэффициент
    callsRaw: Math.round(sumAll(calls)),
    calibration: k ? Number(k.toFixed(2)) : null,
    // null, а не 0: без вызовов доля не определена и рисовать её нечестно
    coldStartPct: done24 > 0 ? Math.min(100, (cold24 / done24) * 100) : null,
    lastInvocationAt
  };
}

// ---------- handler ----------

exports.handler = async (event) => {
  const method = event.httpMethod || event.requestContext?.http?.method || 'GET';
  if (method === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };

  const auth = event.headers?.Authorization || event.headers?.authorization || '';
  try {
    const payload = jwt.verify(auth.replace(/^Bearer\s+/i, ''), SECRET, { issuer: ISSUER });
    if (payload.typ !== 'access') throw new Error('wrong typ');
  } catch {
    return {
      statusCode: 401,
      headers: { 'Content-Type': 'application/json', ...cors },
      body: JSON.stringify({ error: 'unauthorized' })
    };
  }

  if (cache && Date.now() - cache.at < CACHE_TTL) {
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors },
      body: cache.body
    };
  }

  // Проект участвует, только если для него есть и ключ, и каталог: облака
  // подключаются по одному, недостающие просто пропускаем.
  const defs = [
    ['avanzato', process.env.SA_KEY_AVANZATO, process.env.FOLDER_AVANZATO],
    ['alga', process.env.SA_KEY_ALGA, process.env.FOLDER_ALGA],
    ['daria', process.env.SA_KEY_DARIA, process.env.FOLDER_DARIA]
  ].filter((d) => d[1] && d[2]);

  // один упавший проект не должен ронять весь ответ
  const settled = await Promise.allSettled(defs.map((d) => collect(d[0], d[1], d[2])));
  const projects = settled.map((r, i) => {
    if (r.status === 'fulfilled') return r.value;
    const msg = String(r.reason?.message || r.reason);
    console.error('project ' + defs[i][0] + ' failed:', msg);
    // отдаём проект с пометкой об ошибке: молча пропав, он выглядел бы
    // на дашборде как неподключённый, и причину пришлось бы искать в логах
    return { key: defs[i][0], folderId: defs[i][2], error: msg.slice(0, 200) };
  });

  const body = JSON.stringify({ generatedAt: new Date().toISOString(), projects });
  cache = { at: Date.now(), body };

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors },
    body
  };
};
