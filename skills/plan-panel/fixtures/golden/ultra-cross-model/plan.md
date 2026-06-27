# Plan: Refactor authentication — migrate from local JWT to OAuth2 (Google + GitHub)

## Steps

1. Add `auth_providers` table: `user_id`, `provider`, `provider_user_id`, `access_token_encrypted`, `refresh_token_encrypted`, `expires_at`
2. Implement OAuth2 callback handler `/auth/callback/:provider` — code exchange, token storage, session creation
3. Encrypt tokens at rest via libsodium `secretbox` with key from KMS (placeholder — use env var for now)
4. Migration path: existing users with local JWT can link OAuth account from `/settings/security`
5. Deprecate local password login after 90 days, force migration via banner + email
6. Update frontend login screen with 3 buttons (local / Google / GitHub)
7. Session refresh: silent token refresh in background, fallback to re-login if refresh fails
8. Logging: all OAuth events (link, unlink, login, refresh, fail) to audit table
9. Rate-limit OAuth callback to prevent abuse (5/min/IP)
10. Update docs + admin guide for OAuth provider config

## Definition

All 3 login paths work in production. Existing users not broken. p95 login latency < 800ms.

## Risks

- KMS placeholder — real KMS integration TBD
- Refresh token rotation strategy unclear
- Deprecation timeline aggressive (90 days)
