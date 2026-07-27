/**
 * app.js — рендер дашборда и опрос monitor-aggregator раз в 60 секунд.
 *
 * Ожидаемый ответ GET /metrics:
 * {
 *   "generatedAt": "2026-07-27T10:00:00Z",
 *   "projects": [{
 *     "key": "avanzato",
 *     "folderId": "b1g...",
 *     "calls": 128400,          // functions_finished за текущий календарный месяц
 *     "limit": 1000000,         // опционально; иначе берётся CM_CONFIG.FREE_TIER_CALLS
 *     "errors30d": 3,           // functions_errors за последние 30 дней
 *     "lastInvocationAt": "2026-07-27T09:57:12Z"  // null если вызовов не было
 *   }, ...]
 * }
 */
(function () {
  var cfg = window.CM_CONFIG;
  var cardsEl = document.getElementById('cards');
  var bannerEl = document.getElementById('banner');
  var updatedEl = document.getElementById('updated');
  var connEl = document.getElementById('conn');
  var timer = null;
  var els = {};   // key -> { root, bar, pct, calls, errors, dot, warm }

  // ---------- helpers ----------

  function fmt(n) {
    return typeof n === 'number' ? n.toLocaleString('ru-RU') : '—';
  }

  function ago(iso) {
    if (!iso) return null;
    var t = Date.parse(iso);
    return isNaN(t) ? null : (Date.now() - t) / 60000;   // минут назад
  }

  function agoText(min) {
    if (min == null) return 'нет данных';
    if (min < 1) return 'только что';
    if (min < 60) return Math.round(min) + ' мин назад';
    if (min < 1440) return Math.round(min / 60) + ' ч назад';
    return Math.round(min / 1440) + ' дн назад';
  }

  function banner(msg, kind) {
    if (!msg) { bannerEl.className = 'banner'; return; }
    bannerEl.textContent = msg;
    bannerEl.className = 'banner show ' + (kind || 'warn');
  }

  function toLogin() {
    if (timer) clearInterval(timer);
    location.replace('./login.html');
  }

  // ---------- разметка ----------

  function build() {
    cfg.PROJECTS.forEach(function (p) {
      var card = document.createElement('section');
      card.className = 'card loading';
      card.innerHTML =
        '<div class="card-head">' +
          '<h2></h2><span class="folder"></span>' +
        '</div>' +
        '<div class="usage-label"><span>Free-tier вызовов</span><strong>—</strong></div>' +
        '<div class="bar"><span></span></div>' +
        '<div class="stats">' +
          '<div class="stat"><div class="k">Ошибок за 30 дней</div><div class="v" data-f="errors">—</div></div>' +
          '<div class="stat"><div class="k">Keep-warm</div>' +
            '<div class="v"><span class="dot"></span><span class="warm-text">—</span></div></div>' +
        '</div>';
      card.querySelector('h2').textContent = p.name;
      cardsEl.appendChild(card);

      els[p.key] = {
        root: card,
        folder: card.querySelector('.folder'),
        pct: card.querySelector('.usage-label strong'),
        bar: card.querySelector('.bar > span'),
        errors: card.querySelector('[data-f=errors]'),
        dot: card.querySelector('.dot'),
        warm: card.querySelector('.warm-text')
      };
    });
  }

  // ---------- отрисовка данных ----------

  function paint(project) {
    var el = els[project.key];
    if (!el) return;
    el.root.classList.remove('loading', 'stale');

    var limit = Number(project.limit) || cfg.FREE_TIER_CALLS;
    var calls = Number(project.calls) || 0;
    var pct = limit > 0 ? (calls / limit) * 100 : 0;
    var shown = Math.min(100, pct);

    el.folder.textContent = project.folderId || '';
    el.pct.textContent = pct.toFixed(1) + '% · ' + fmt(calls) + ' / ' + fmt(limit);
    el.bar.style.width = shown.toFixed(2) + '%';
    el.bar.className = pct >= 90 ? 'err' : (pct >= 70 ? 'warn' : '');

    var errs = Number(project.errors30d) || 0;
    el.errors.textContent = fmt(errs);
    el.errors.className = 'v' + (errs > 0 ? ' err' : '');

    var min = ago(project.lastInvocationAt);
    var state = min == null ? 'err'
      : min <= cfg.WARM_OK_MIN ? 'ok'
      : min <= cfg.WARM_WARN_MIN ? 'warn'
      : 'err';
    el.dot.className = 'dot ' + state;
    el.warm.textContent = agoText(min);
  }

  function markStale() {
    Object.keys(els).forEach(function (k) { els[k].root.classList.add('stale'); });
  }

  // ---------- загрузка ----------

  function load() {
    if (!navigator.onLine) {
      banner('Офлайн — показаны последние данные', 'warn');
      markStale();
      return Promise.resolve();
    }

    return Auth.apiFetch(cfg.ENDPOINTS.metrics, { cache: 'no-store' })
      .then(function (data) {
        banner(null);
        (data.projects || []).forEach(paint);

        // проекты, которых не было в ответе — облако ещё не подключено
        var seen = (data.projects || []).map(function (p) { return p.key; });
        cfg.PROJECTS.forEach(function (p) {
          if (seen.indexOf(p.key) !== -1) return;
          var el = els[p.key];
          el.root.classList.remove('loading');
          el.root.classList.add('stale');
          el.pct.textContent = 'не подключено';
          el.bar.style.width = '0%';
          el.errors.textContent = '—';
          el.dot.className = 'dot';
          el.warm.textContent = '—';
        });

        var ts = data.generatedAt ? new Date(data.generatedAt) : new Date();
        updatedEl.textContent = 'Обновлено ' + ts.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
      })
      .catch(function (err) {
        if (err.status === 401 || err.status === 403) return toLogin();
        banner('Не удалось обновить данные (' + (err.message || err) + ')', 'error');
        markStale();
      });
  }

  function start() {
    if (timer) clearInterval(timer);
    timer = setInterval(load, cfg.REFRESH_MS);
    return load();
  }

  // ---------- события ----------

  document.getElementById('refresh').addEventListener('click', function (e) {
    e.currentTarget.disabled = true;
    load().then(function () { e.currentTarget.disabled = false; });
  });

  document.getElementById('logout').addEventListener('click', function () {
    Auth.logout().then(toLogin);
  });

  // не жжём квоту, пока вкладка в фоне
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) {
      if (timer) { clearInterval(timer); timer = null; }
    } else if (!timer) {
      start();
    }
  });

  window.addEventListener('online', function () { connEl.textContent = ''; load(); });
  window.addEventListener('offline', function () { connEl.textContent = 'офлайн'; markStale(); });

  // ---------- bootstrap ----------

  build();
  Auth.restore().then(function (ok) {
    if (!ok) return toLogin();
    return start();
  });

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('./sw.js').catch(function () { /* не критично */ });
    });
  }
})();
