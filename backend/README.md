# Backend: 5 шагов до рабочего логина

Всё делается один раз, в терминале, где установлен `yc` и `node`.
Порядок важен. Пароль задаётся на шаге 1–2.

```bash
cd backend
chmod +x *.sh
```

---

## Шаг 0. Ключи сервисных аккаунтов

По одному на каждое облако. Выполните **в каждом из трёх профилей** `yc`
(переключение: `yc config profile activate <профиль>`):

```bash
yc iam service-account create --name cm-monitor
yc resource-manager folder add-access-binding <folderId> \
  --role monitoring.viewer \
  --subject serviceAccount:$(yc iam service-account get cm-monitor --format json | grep -o '"id": "[^"]*' | head -1 | cut -d'"' -f4)
yc iam key create --service-account-name cm-monitor --output key-avanzato.json
```

Так три раза → рядом лежат `key-avanzato.json`, `key-alga.json`, `key-daria.json`.
**В git они не попадут** (`.gitignore`), и после шага 2 их надо удалить.

## Шаг 1. Пароль → хеш

```bash
./1-hash.sh 'мой-пароль-от-дашборда'
```

Скрипт напечатает строку вида `$2b$12$Btjk8z8/Absfi77...`. Скопируйте её.
Это и есть «задать пароль»: сам пароль нигде не хранится, только хеш.

## Шаг 2. Положить всё в Lockbox

```bash
./2-secrets.sh '$2b$12$Btjk8z8/Absfi77...'
```

⚠️ Хеш **обязательно в одинарных кавычках** — в нём есть `$`, в двойных кавычках
bash его испортит, и потом будет вечное «Неверный пароль».

Скрипт сам сгенерит `JWT_SECRET` и заберёт три ключа. Дальше:

```bash
rm key-*.json
```

## Шаг 3. Деплой функций

Откройте `3-deploy.sh`, впишите вверху три `folderId`, затем:

```bash
./3-deploy.sh
```

## Шаг 4. API Gateway

Узнайте ID функций и сервисного аккаунта:

```bash
yc serverless function list
yc iam service-account list
```

Подставьте их в `gateway.yaml` вместо `<ID_...>` и создайте шлюз:

```bash
yc serverless api-gateway create --name cloud-monitor --spec=gateway.yaml
yc serverless api-gateway get cloud-monitor --format json | grep domain
```

Получите домен вида `d5d1abcd1234.apigw.yandexcloud.net`.

Сервисному аккаунту шлюза нужна роль `functions.functionInvoker`.

## Шаг 5. Прописать домен во фронтенд

В корне репозитория, в `config.js`:

```js
API_BASE: 'https://d5d1abcd1234.apigw.yandexcloud.net',
```

Закоммитьте и запушьте в `main` — GitHub Pages пересоберётся за минуту.
Откройте https://antonioavanzato.github.io/monitoring/ и войдите паролем из шага 1.

---

## Если не пускает

| Симптом | Причина |
|---|---|
| «Ошибка входа: Failed to fetch» | `API_BASE` не заменён, или шлюз не отвечает, или CORS: `ALLOWED_ORIGIN` должен быть ровно `https://antonioavanzato.github.io` без слэша на конце |
| «Неверный пароль» при верном пароле | хеш испорчен двойными кавычками на шаге 2 — перезалейте секрет |
| Вход проходит, но карточки пустые | смотрите логи: `yc serverless function logs monitor-aggregator` — обычно нет роли `monitoring.viewer` или не те имена метрик |
| Логин спрашивают после каждой перезагрузки | браузер режет third-party cookie (Safari/iOS). Лечится своим доменом на шлюзе — см. `../BACKEND.md` |

Проверить руками, что backend жив:

```bash
curl -i -X POST https://<домен>/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"password":"мой-пароль-от-дашборда"}'
```

Ожидаем `200` и `{"token":"...","expiresIn":900}`. `401` — пароль/хеш.
Ничего — шлюз или функция.
