# TODO: backend (Yandex Cloud Functions)

Backend живёт **не в этом репозитории** — это две функции на Node.js 18+, которые
деплоятся вручную через `yc CLI`. Ниже — контракт, которого ждёт фронтенд, и
референсный код.

> Логику проверки пароля (bcrypt) и выдачи JWT берём из уже работающей
> `admin-api` в `alga-tour-backend` — здесь она воспроизведена по описанию,
> сверьте с оригиналом перед деплоем (особенно `JWT_SECRET`, `issuer`, `alg`).

---

## 1. Контракт API

Базовый URL прописывается в `config.js` → `API_BASE`.

| Метод | Путь             | Авторизация | Ответ |
|-------|------------------|-------------|-------|
| POST  | `/auth/login`    | `{ password }` | `{ token, expiresIn }` + `Set-Cookie: cm_rt=…; HttpOnly` |
| POST  | `/auth/session`  | refresh-cookie | `{ token, expiresIn }` |
| POST  | `/auth/logout`   | refresh-cookie | `204`, cookie сбрасывается |
| GET   | `/metrics`       | `Authorization: Bearer <JWT>` | см. ниже |

`GET /metrics`:

```json
{
  "generatedAt": "2026-07-27T10:00:00Z",
  "projects": [
    {
      "key": "avanzato",
      "folderId": "b1g...",
      "calls": 128400,
      "limit": 1000000,
      "errors30d": 3,
      "lastInvocationAt": "2026-07-27T09:57:12Z"
    },
    { "key": "alga",  "...": "..." },
    { "key": "daria", "...": "..." }
  ]
}
```

* `key` обязан совпадать с ключами в `CM_CONFIG.PROJECTS`.
* `calls` — `functions_finished` за текущий календарный месяц (free-tier считается помесячно).
* `errors30d` — `functions_errors` за последние 30 дней.
* `lastInvocationAt` — время последнего вызова; `null`, если вызовов не было.
  Фронт красит keep-warm: `≤6 мин` зелёный, `≤15 мин` жёлтый, дальше красный.

## 2. CORS (обязательно)

`credentials: 'include'` требует **конкретного** Origin, `*` не сработает:

```js
const ORIGIN = 'https://antonioavanzato.github.io';
const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Vary': 'Origin'
};
```

Preflight `OPTIONS` должен возвращать `204` с этими заголовками.

Refresh-cookie: `HttpOnly; Secure; SameSite=None; Path=/; Max-Age=2592000`.
`SameSite=None` нужен потому, что github.io и yandexcloud.net — разные сайты.
Safari и браузеры с блокировкой third-party cookies её отбросят — тогда логин
будет спрашиваться после каждой перезагрузки (токен всё равно только в памяти,
это не дыра, просто неудобно). **Хотите бесшовно — посадите фронт и API на один
домен**: свой домен на API Gateway + фронт там же (или CNAME для Pages), тогда
можно `SameSite=Strict`.

## 3. Секреты (переменные окружения функции)

Задаются через Lockbox, а не открытым текстом:

| Переменная | Что |
|---|---|
| `SA_KEY_AVANZATO` | JSON авторизованного ключа сервисного аккаунта (base64) |
| `SA_KEY_ALGA` | то же |
| `SA_KEY_DARIA` | то же |
| `FOLDER_AVANZATO`, `FOLDER_ALGA`, `FOLDER_DARIA` | folderId |
| `ADMIN_PASSWORD_HASH` | bcrypt-хеш пароля |
| `JWT_SECRET` | ≥32 случайных байта |

Каждому сервисному аккаунту достаточно роли `monitoring.viewer` в своём каталоге.

## 4. admin-api: пароль → JWT

```js
// index.js  (функция admin-api)
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');

const SECRET = process.env.JWT_SECRET;
const HASH = process.env.ADMIN_PASSWORD_HASH;
const ACCESS_TTL = 900;            // 15 мин, живёт в памяти вкладки
const REFRESH_TTL = 30 * 24 * 3600;

const sign = (ttl, typ) =>
  jwt.sign({ sub: 'admin', typ }, SECRET, { expiresIn: ttl, issuer: 'cloud-monitor' });

const json = (code, body, extra = {}) => ({
  statusCode: code,
  headers: { 'Content-Type': 'application/json', ...cors, ...extra },
  body: JSON.stringify(body)
});

const readCookie = (event, name) => {
  const raw = event.headers?.Cookie || event.headers?.cookie || '';
  const hit = raw.split(';').map(s => s.trim()).find(s => s.startsWith(name + '='));
  return hit ? decodeURIComponent(hit.slice(name.length + 1)) : null;
};

const setRefresh = (token) =>
  `cm_rt=${token}; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=${REFRESH_TTL}`;

exports.handler = async (event) => {
  const path = event.path || '/';
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };

  if (path.endsWith('/auth/login')) {
    const { password } = JSON.parse(event.body || '{}');
    // bcrypt.compare сам по себе constant-time по хешу
    const ok = typeof password === 'string' && await bcrypt.compare(password, HASH);
    if (!ok) {
      await new Promise(r => setTimeout(r, 300 + crypto.randomInt(200))); // против перебора
      return json(401, { error: 'invalid_credentials' });
    }
    return json(200,
      { token: sign(ACCESS_TTL, 'access'), expiresIn: ACCESS_TTL },
      { 'Set-Cookie': setRefresh(sign(REFRESH_TTL, 'refresh')) });
  }

  if (path.endsWith('/auth/session')) {
    const rt = readCookie(event, 'cm_rt');
    try {
      const p = jwt.verify(rt, SECRET, { issuer: 'cloud-monitor' });
      if (p.typ !== 'refresh') throw new Error('wrong typ');
    } catch { return json(401, { error: 'no_session' }); }
    return json(200, { token: sign(ACCESS_TTL, 'access'), expiresIn: ACCESS_TTL });
  }

  if (path.endsWith('/auth/logout')) {
    return json(204, {}, { 'Set-Cookie': 'cm_rt=; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=0' });
  }

  return json(404, { error: 'not_found' });
};
```

Хеш пароля генерится один раз локально:
`node -e "console.log(require('bcryptjs').hashSync(process.argv[1],12))" 'пароль'`

## 5. monitor-aggregator

Шаги: `SA key → IAM token` (JWT-ассерция, кэшировать ~50 мин) →
`POST monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=…`.

```js
const jwt = require('jsonwebtoken');
const LIMIT = 1_000_000;

async function iamToken(saKeyJson) {                     // кэшируйте по key.id!
  const key = JSON.parse(Buffer.from(saKeyJson, 'base64').toString('utf8'));
  const now = Math.floor(Date.now() / 1000);
  const assertion = jwt.sign(
    { iss: key.service_account_id, aud: 'https://iam.api.cloud.yandex.net/iam/v1/tokens', iat: now, exp: now + 3600 },
    key.private_key,
    { algorithm: 'PS256', keyid: key.id }
  );
  const res = await fetch('https://iam.api.cloud.yandex.net/iam/v1/tokens', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jwt: assertion })
  });
  if (!res.ok) throw new Error('iam ' + res.status);
  return (await res.json()).iamToken;
}

async function readMetric(iam, folderId, query, from, to, downsampling) {
  const res = await fetch(
    'https://monitoring.api.cloud.yandex.net/monitoring/v2/data/read?folderId=' + folderId, {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + iam, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query,
        fromTime: from.toISOString(),
        toTime: to.toISOString(),
        downsampling: downsampling || { maxPoints: 1, gridAggregation: 'SUM' }
      })
    });
  if (!res.ok) throw new Error('monitoring ' + res.status + ' ' + await res.text());
  return res.json();
}

const sum = (r) => (r.metrics || [])
  .flatMap(m => m.timeseries?.doubleValues || m.timeseries?.int64Values || [])
  .reduce((a, b) => a + (Number(b) || 0), 0);

async function collect(key, saKeyJson, folderId) {
  const iam = await iamToken(saKeyJson);
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const d30 = new Date(now - 30 * 864e5);

  const q = (name) =>
    `"${name}"{service="serverless-functions", folderId="${folderId}"}`;

  const [calls, errors, recent] = await Promise.all([
    readMetric(iam, folderId, q('functions_finished'), monthStart, now),
    readMetric(iam, folderId, q('functions_errors'), d30, now),
    // мелкая сетка за последний час — ищем последнюю непустую точку (keep-warm)
    readMetric(iam, folderId, q('functions_finished'), new Date(now - 36e5), now,
               { gridInterval: 60_000, gridAggregation: 'SUM' })
  ]);

  let lastInvocationAt = null;
  const ts = recent.metrics?.[0]?.timeseries;
  if (ts) {
    const vals = ts.doubleValues || ts.int64Values || [];
    for (let i = vals.length - 1; i >= 0; i--) {
      if (Number(vals[i]) > 0) { lastInvocationAt = new Date(Number(ts.timestamps[i])).toISOString(); break; }
    }
  }

  return { key, folderId, calls: sum(calls), limit: LIMIT, errors30d: sum(errors), lastInvocationAt };
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };

  // тот же JWT_SECRET, что у admin-api
  const auth = event.headers?.Authorization || event.headers?.authorization || '';
  try {
    const p = require('jsonwebtoken').verify(auth.replace(/^Bearer /, ''), process.env.JWT_SECRET,
                                             { issuer: 'cloud-monitor' });
    if (p.typ !== 'access') throw new Error('wrong typ');
  } catch {
    return { statusCode: 401, headers: cors, body: '{"error":"unauthorized"}' };
  }

  const defs = [
    ['avanzato', process.env.SA_KEY_AVANZATO, process.env.FOLDER_AVANZATO],
    ['alga',     process.env.SA_KEY_ALGA,     process.env.FOLDER_ALGA],
    ['daria',    process.env.SA_KEY_DARIA,    process.env.FOLDER_DARIA]
  ];

  // один упавший проект не должен ронять весь ответ
  const settled = await Promise.allSettled(defs.map(d => collect(...d)));
  const projects = settled
    .map((r, i) => r.status === 'fulfilled'
      ? r.value
      : { key: defs[i][0], folderId: defs[i][2], error: String(r.reason) })
    .filter(p => !p.error);

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors },
    body: JSON.stringify({ generatedAt: new Date().toISOString(), projects })
  };
};
```

Деплой:

```bash
yc serverless function version create \
  --function-name monitor-aggregator \
  --runtime nodejs18 --entrypoint index.handler \
  --memory 256m --execution-timeout 30s \
  --source-path ./aggregator \
  --secret name=cm-secrets,key=SA_KEY_AVANZATO,environment-variable=SA_KEY_AVANZATO \
  # …остальные секреты…
  --service-account-id <sa-id-вызывающего-аккаунта>
```

Функции публикуются с `--no-service-account` (публичный вызов) — авторизация
своя, по JWT. Если ставите API Gateway, положите обе функции под один домен и
подравняйте пути из таблицы выше.

## Проверки перед вводом в строй

- [ ] `API_BASE` в `config.js` заменён на реальный URL.
- [ ] Preflight `OPTIONS` отвечает 204 с `Allow-Credentials: true`.
- [ ] `/metrics` без `Authorization` отдаёт 401 (иначе метрики публичны).
- [ ] `key` в ответе совпадает с `CM_CONFIG.PROJECTS`.
- [ ] Названия метрик сверены с реальным ответом Monitoring API — если они
      отличаются от `functions_finished` / `functions_errors`, поправьте `q()`.
