/**
 * Конфигурация фронтенда. Правится вручную после деплоя backend-функций.
 * Никаких секретов здесь быть не должно — файл публичный (GitHub Pages).
 */
window.CM_CONFIG = {
  // Публичный URL Yandex Cloud Function (API Gateway или https://functions.yandexcloud.net/<id>)
  API_BASE: 'https://functions.yandexcloud.net/REPLACE_WITH_GATEWAY_ID',

  // Эндпоинты admin-api / monitor-aggregator
  ENDPOINTS: {
    login:   '/auth/login',    // POST { password } -> { token, expiresIn } + httpOnly refresh cookie
    session: '/auth/session',  // POST (cookie) -> { token, expiresIn }   — восстановление после reload
    logout:  '/auth/logout',   // POST -> сбрасывает httpOnly cookie
    metrics: '/metrics'        // GET  (Bearer) -> { generatedAt, projects: [...] }
  },

  // Интервал автообновления дашборда
  REFRESH_MS: 60_000,

  // Порядок и отображаемые имена проектов. key должен совпадать с ключом из backend.
  PROJECTS: [
    { key: 'avanzato', name: 'Avanzato' },
    { key: 'alga',     name: 'ALGA' },
    { key: 'daria',    name: 'Daria' }
  ],

  // Free-tier лимит вызовов Cloud Functions в месяц (по умолчанию 1 000 000).
  // Backend может прислать свой limit — он приоритетнее.
  FREE_TIER_CALLS: 1_000_000,

  // Keep-warm: сколько минут без вызова считать «остыло».
  WARM_OK_MIN: 6,
  WARM_WARN_MIN: 15
};
