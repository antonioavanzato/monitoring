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

  var gate = document.getElementById('gate');
  var dash = document.getElementById('dash');
  var gateBanner = document.getElementById('gate-banner');
  var gatePassword = document.getElementById('gate-password');
  var gateSubmit = document.getElementById('gate-submit');

  /** Показать форму входа. Никаких переходов: токен живёт в памяти вкладки. */
  function toLogin() {
    if (timer) { clearInterval(timer); timer = null; }
    dash.hidden = true;
    gate.hidden = false;
    gateBanner.className = 'banner';
    gateSubmit.disabled = false;
    gateSubmit.textContent = 'Войти';
    gatePassword.value = '';
    gatePassword.focus();
  }

  function toDashboard() {
    gate.hidden = true;
    dash.hidden = false;
    return start();
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

    if (project.error) {
      el.root.classList.add('stale');
      el.folder.textContent = project.folderId || '';
      el.pct.textContent = 'ошибка';
      el.pct.title = project.error;
      el.bar.style.width = '0%';
      el.bar.className = 'err';
      el.errors.textContent = '—';
      el.errors.className = 'v';
      el.dot.className = 'dot err';
      el.warm.textContent = 'нет данных';
      return;
    }
    el.pct.title = '';

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

  // ---------- потягивание сверху вниз для обновления ----------

  var pull = document.getElementById('pull');
  var PULL_TRIGGER = 70;    // сколько протянуть, чтобы обновление сработало
  var PULL_MAX = 110;       // дальше не тянется
  var pullStartY = null;
  var pullDist = 0;
  var pullBusy = false;

  function pullSet(dist) {
    pull.style.transform = 'translateY(' + (dist - 56) + 'px)';
    pull.classList.toggle('ready', dist >= PULL_TRIGGER);
    pull.querySelector('.pull-text').textContent =
      dist >= PULL_TRIGGER ? 'Отпустите' : 'Потяните';
  }

  function pullReset() {
    pull.classList.add('settling');
    pull.classList.remove('visible', 'ready', 'busy');
    pull.style.transform = 'translateY(-56px)';
    setTimeout(function () { pull.classList.remove('settling'); }, 260);
  }

  document.addEventListener('touchstart', function (e) {
    if (pullBusy || dash.hidden || e.touches.length !== 1) return;
    // тянем только когда список уже прокручен в самый верх
    pullStartY = window.scrollY <= 0 ? e.touches[0].clientY : null;
    pullDist = 0;
  }, { passive: true });

  document.addEventListener('touchmove', function (e) {
    if (pullStartY === null || pullBusy) return;

    var delta = e.touches[0].clientY - pullStartY;
    if (delta <= 0) { pullStartY = null; pullReset(); return; }

    // сопротивление: чем дальше, тем туже
    pullDist = Math.min(PULL_MAX, delta * 0.5);
    pull.classList.add('visible');
    pull.classList.remove('settling');
    pullSet(pullDist);
    e.preventDefault();          // гасим отскок страницы
  }, { passive: false });

  document.addEventListener('touchend', function () {
    if (pullStartY === null || pullBusy) return;
    var trigger = pullDist >= PULL_TRIGGER;
    pullStartY = null;

    if (!trigger) return pullReset();

    pullBusy = true;
    pull.classList.add('busy', 'settling');
    pull.classList.remove('ready');
    pull.style.transform = 'translateY(0)';
    pull.querySelector('.pull-text').textContent = 'Обновляю…';

    load().then(function () {
      pullBusy = false;
      pullReset();
    });
  }, { passive: true });

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

  document.getElementById('gate-form').addEventListener('submit', function (e) {
    e.preventDefault();
    gateBanner.className = 'banner';
    gateSubmit.disabled = true;
    gateSubmit.textContent = 'Проверяем…';

    Auth.login(gatePassword.value).then(function () {
      gatePassword.value = '';
      return toDashboard();
    }).catch(function (err) {
      gateBanner.textContent = err && err.status === 401
        ? 'Неверный пароль'
        : 'Не удалось войти: ' + (err.message || err);
      gateBanner.className = 'banner show error';
      gateSubmit.disabled = false;
      gateSubmit.textContent = 'Войти';
      gatePassword.value = '';
      gatePassword.focus();
    });
  });

  // ---------- bootstrap ----------

  build();

  // Сессия могла уцелеть в httpOnly cookie — если браузер её не режет.
  // Не уцелела: просто показываем форму, без всяких переходов.
  Auth.restore().then(function (ok) {
    return ok ? toDashboard() : toLogin();
  });

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('./sw.js').catch(function () { /* не критично */ });
    });
  }
})();
