# Plan: Public API endpoint with bearer auth

## Steps

1. POST `/api/submit` accepting JSON body `{email, message}`
2. Bearer token auth — token from `.env`
3. Rate limit 60 req/min per IP (in-memory)
4. Save to PostgreSQL via Prisma
5. Send Slack webhook on each submission
6. Return 200 OK with `{id}` on success

## Definition

Endpoint works in production. Tested with curl.
