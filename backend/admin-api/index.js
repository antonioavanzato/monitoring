/**
 * admin-api — вход по паролю и выдача JWT.
 *
 * Переменные окружения (через Lockbox):
 *   ADMIN_PASSWORD_HASH — bcrypt-хеш пароля
 *   JWT_SECRET          — общий секрет (тот же, что у aggregator)
 *   ALLOWED_ORIGIN      — https://antonioavanzato.github.io
 */
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');

const SECRET = process.env.JWT_SECRET;
const HASH = process.env.ADMIN_PASSWORD_HASH;
const ORIGIN = process.env.ALLOWED_ORIGIN || 'https://antonioavanzato.github.io';

const ACCESS_TTL = 900;                 // 15 минут — токен живёт в памяти вкладки
const REFRESH_TTL = 30 * 24 * 3600;     // 30 дней — httpOnly cookie
const ISSUER = 'cloud-monitor';

const cors = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Vary': 'Origin'
};

const sign = (ttl, typ) =>
  jwt.sign({ sub: 'admin', typ }, SECRET, { expiresIn: ttl, issuer: ISSUER });

const json = (statusCode, body, extra = {}) => ({
  statusCode,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...cors, ...extra },
  body: JSON.stringify(body)
});

const readCookie = (event, name) => {
  const raw = event.headers?.Cookie || event.headers?.cookie || '';
  const hit = raw.split(';').map((s) => s.trim()).find((s) => s.startsWith(name + '='));
  return hit ? decodeURIComponent(hit.slice(name.length + 1)) : null;
};

// SameSite=None обязателен: github.io и yandexcloud.net — разные сайты
const refreshCookie = (token, maxAge) =>
  `cm_rt=${token}; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=${maxAge}`;

exports.handler = async (event) => {
  const path = event.path || event.url || '/';
  const method = event.httpMethod || event.requestContext?.http?.method || 'POST';

  if (method === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };

  if (!SECRET || !HASH) {
    console.error('JWT_SECRET или ADMIN_PASSWORD_HASH не заданы');
    return json(500, { error: 'server_misconfigured' });
  }

  // ---- вход по паролю ----
  if (path.endsWith('/auth/login')) {
    let password;
    try {
      password = JSON.parse(event.body || '{}').password;
    } catch {
      return json(400, { error: 'bad_request' });
    }

    const ok = typeof password === 'string' && password.length > 0 &&
               await bcrypt.compare(password, HASH);

    if (!ok) {
      // случайная задержка — чуть дороже перебор, не выдаёт время сравнения
      await new Promise((r) => setTimeout(r, 300 + crypto.randomInt(200)));
      return json(401, { error: 'invalid_credentials' });
    }

    return json(200,
      { token: sign(ACCESS_TTL, 'access'), expiresIn: ACCESS_TTL },
      { 'Set-Cookie': refreshCookie(sign(REFRESH_TTL, 'refresh'), REFRESH_TTL) });
  }

  // ---- восстановление сессии по cookie ----
  if (path.endsWith('/auth/session')) {
    const rt = readCookie(event, 'cm_rt');
    if (!rt) return json(401, { error: 'no_session' });
    try {
      const payload = jwt.verify(rt, SECRET, { issuer: ISSUER });
      if (payload.typ !== 'refresh') throw new Error('wrong typ');
    } catch {
      return json(401, { error: 'no_session' });
    }
    return json(200, { token: sign(ACCESS_TTL, 'access'), expiresIn: ACCESS_TTL });
  }

  // ---- выход ----
  if (path.endsWith('/auth/logout')) {
    return {
      statusCode: 204,
      headers: { ...cors, 'Set-Cookie': refreshCookie('', 0) },
      body: ''
    };
  }

  return json(404, { error: 'not_found' });
};
