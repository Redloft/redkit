# Plan: Feedback endpoint

## Шаги

1. Добавить POST /api/feedback endpoint в Express server
2. Принимать body: { role: string, useful: boolean, reason: string }
3. Сохранять в файл /opt/app/feedback/<role>.jsonl (append mode)
4. Защитить bearer token authentication — токен в .env
5. Rate limit 10 req/min/IP через express-rate-limit
6. После записи — webhook на наш Slack incoming-webhook

## Definition

Когда работает — на feedback приходит сразу в Slack.
