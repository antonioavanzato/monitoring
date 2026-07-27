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
const EXCLUDE_SELECTOR = EXCLUDE.map((id) => `, function!="${id}"`).join('');

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

const sumAll = (payload) =>
  (payload.metrics || []).reduce((acc, m) => acc + values(m.timeseries).reduce((a, b) => a + (b || 0), 0), 0);

async function collect(key, saKeyBase64, folderId) {
  const iam = await iamToken(saKeyBase64);

  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const d30 = new Date(now.getTime() - 30 * 864e5);
  const hourAgo = new Date(now.getTime() - 36e5);

  // Каталог задаётся параметром folderId в URL. Меткой folderId у метрик нет —
  // селектор с ней не совпадал ни с чем, и ответ приходил пустым без ошибки.
  //
  // Собственные функции дашборда исключаем: они живут в одном из каталогов и
  // иначе считали бы сами себя, завышая цифру тем сильнее, чем дольше открыт
  // дашборд.
  const q = (name) => `"${name}"{service="serverless-functions"${EXCLUDE_SELECTOR}}`;

  // Если Monitoring не поймёт исключения, лучше показать чуть завышенное
  // число, чем ошибку — поэтому есть запасной запрос без них.
  const qPlain = (name) => `"${name}"{service="serverless-functions"}`;

  // Пробуем с исключениями, при отказе повторяем без них.
  const read = async (name, from, to, downsampling) => {
    try {
      return await readMetric(iam, folderId, q(name), from, to, downsampling);
    } catch (e) {
      if (!EXCLUDE_SELECTOR) throw e;
      console.error('селектор с исключениями отвергнут, читаю без него:', e.message);
      return readMetric(iam, folderId, qPlain(name), from, to, downsampling);
    }
  };

  const [calls, errors, recent] = await Promise.all([
    read('functions_finished', monthStart, now),
    read('functions_errors', d30, now),
    // минутная сетка за последний час — ищем последнюю непустую точку (keep-warm)
    read('functions_finished', hourAgo, now,
         { gridInterval: 60_000, gridAggregation: 'SUM' })
  ]);

  let lastInvocationAt = null;
  for (const m of recent.metrics || []) {
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
    calls: sumAll(calls),
    limit: LIMIT,
    errors30d: sumAll(errors),
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
