# Plan: Add `user_preferences` table + GDPR-ish data export

## Steps

1. Supabase migration: add table `user_preferences` with columns `user_id (FK)`, `theme`, `language`, `notifications_json`, `created_at`, `updated_at`
2. Add RLS policy: user can SELECT/UPDATE only their own row
3. New endpoint `GET /api/me/export` — returns all user data (preferences, sessions, submissions) as JSON download
4. Audit log: each export request logged with timestamp + user_id
5. Auto-delete export logs older than 90 days (cron)

## Definition

Migration applies cleanly. Export returns full user payload. RLS validated by impersonating another user (should get 403).
