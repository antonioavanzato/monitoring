# Cloud Monitor

PWA-дашборд free-tier usage Yandex Cloud Functions по трём проектам
(Avanzato / ALGA / Daria), каждый на своём биллинг-аккаунте.

Чистая статика: HTML/CSS/JS, без сборщиков и зависимостей. Хостится на
GitHub Pages (ветка `main`, папка `/`).

## Файлы

| Файл | Что делает |
|---|---|
| `index.html` | дашборд: 3 карточки — прогресс free-tier, ошибки за 30 дней, keep-warm |
| `login.html` | форма пароля |
| `auth.js` | JWT **только в памяти** + восстановление сессии по httpOnly cookie |
| `app.js` | опрос `monitor-aggregator` с `Authorization: Bearer`, автообновление раз в 60 с |
| `config.js` | URL backend, лимиты, пороги (единственный файл под правку) |
| `styles.css` | тёмная тема |
| `manifest.json`, `sw.js`, `icons/` | PWA: standalone, офлайн-кэш статики |
| `BACKEND.md` | TODO по backend-функциям + референсный код |

## Настройка

1. Задеплойте функции из `BACKEND.md` (`yc CLI`).
2. Впишите их URL в `config.js` → `API_BASE`.
3. Закоммитьте, Pages подхватит.

## Хранение токена

Access-JWT живёт в переменной внутри JS-контекста вкладки: ни `localStorage`,
ни `sessionStorage`, ни доступной из JS cookie. Перезагрузка страницы его
теряет — сессия восстанавливается запросом `/auth/session` по httpOnly
refresh-cookie. Если браузер режет third-party cookies (Safari/iOS), логин
будет спрашиваться после каждой перезагрузки; как убрать — в `BACKEND.md`.

Service worker не кэширует ответы API — только статику.

## Обновление PWA

`sw.js` берёт статику cache-first, поэтому после правки файлов поднимайте
`VERSION` в `sw.js` — иначе установленное приложение останется на старой версии.
