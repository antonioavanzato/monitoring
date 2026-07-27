/**
 * Auth — JWT только в памяти вкладки.
 *
 * Токен НЕ попадает в localStorage/sessionStorage/IndexedDB и не пишется в
 * обычную cookie: при закрытии вкладки он исчезает вместе с JS-контекстом.
 *
 * Переход login.html -> index.html убивает JS-контекст, поэтому «мостом»
 * между страницами служит httpOnly + Secure refresh-cookie, которую ставит
 * backend на /auth/login. index.html при загрузке зовёт /auth/session и
 * получает свежий короткоживущий access-JWT снова в память.
 *
 * ВАЖНО: страница (github.io) и функция (yandexcloud.net) — разные сайты,
 * поэтому cookie должна быть SameSite=None; Secure, а CORS — с конкретным
 * Origin и Allow-Credentials: true. Safari/iOS и браузеры с блокировкой
 * third-party cookies такую cookie отбросят: restore() вернёт false и форма
 * входа будет появляться после каждой перезагрузки — безопасная деградация,
 * токен при этом всё равно живёт только в памяти. Чтобы этого избежать,
 * посадите фронт и функцию на один домен (см. BACKEND.md).
 */
window.Auth = (function () {
  var cfg = window.CM_CONFIG;
  var token = null;      // in-memory access JWT
  var expiresAt = 0;     // ms epoch
  var refreshing = null;

  function url(path) {
    return cfg.API_BASE.replace(/\/$/, '') + path;
  }

  function httpError(res) {
    var e = new Error('HTTP ' + res.status);
    e.status = res.status;
    return e;
  }

  function accept(data) {
    if (!data || !data.token) throw new Error('Пустой ответ авторизации');
    token = data.token;
    // expiresIn — в секундах; обновляемся за 30 с до истечения
    var ttl = Number(data.expiresIn) || 900;
    expiresAt = Date.now() + ttl * 1000;
    return token;
  }

  function login(password) {
    return fetch(url(cfg.ENDPOINTS.login), {
      method: 'POST',
      credentials: 'include',            // чтобы браузер принял httpOnly cookie
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: password })
    }).then(function (res) {
      if (!res.ok) throw httpError(res);
      return res.json();
    }).then(accept);
  }

  /** Тихо поднимает сессию по httpOnly cookie. Резолвится в true/false. */
  function restore() {
    if (refreshing) return refreshing;
    refreshing = fetch(url(cfg.ENDPOINTS.session), {
      method: 'POST',
      credentials: 'include'
    }).then(function (res) {
      if (!res.ok) return false;
      return res.json().then(accept).then(function () { return true; });
    }).catch(function () {
      return false;      // офлайн или backend недоступен
    }).then(function (ok) {
      refreshing = null;
      return ok;
    });
    return refreshing;
  }

  /** Возвращает валидный токен (при необходимости обновив его) либо null. */
  function getToken() {
    if (token && Date.now() < expiresAt - 30_000) return Promise.resolve(token);
    token = null;
    return restore().then(function (ok) { return ok ? token : null; });
  }

  function logout() {
    token = null;
    expiresAt = 0;
    return fetch(url(cfg.ENDPOINTS.logout), {
      method: 'POST',
      credentials: 'include'
    }).catch(function () { /* всё равно уходим */ });
  }

  /** fetch с Authorization: Bearer <JWT>. Бросает {status:401} если сессии нет. */
  function apiFetch(path, options) {
    return getToken().then(function (t) {
      if (!t) { var e = new Error('Нет сессии'); e.status = 401; throw e; }
      var opts = Object.assign({ credentials: 'include' }, options || {});
      opts.headers = Object.assign({}, opts.headers, { Authorization: 'Bearer ' + t });
      return fetch(url(path), opts);
    }).then(function (res) {
      if (res.status === 401 || res.status === 403) {
        token = null; expiresAt = 0;
        throw httpError(res);
      }
      if (!res.ok) throw httpError(res);
      return res.json();
    });
  }

  return {
    login: login,
    restore: restore,
    logout: logout,
    apiFetch: apiFetch,
    isAuthenticated: function () { return !!token && Date.now() < expiresAt; }
  };
})();
