# /redwork-resume <slug> — продолжить после ответа человека

Резюм прерванного/заблокированного redwork-прогона. Процедура — `SKILL.md`. Envelope: `{slug, human_decision: approve|reject|answer, answer?}`.

## Шаги
1. `RD="$(_data_root)/<slug>"` (или найти по slug). `state.sh get "$RD" .schema_version` (read-policy: `>KNOWN_MAX`→abort).
2. `state.sh lock "$RD"` (re-lock; stale-reclaim если прошлый процесс мёртв).
3. Прочитать `blocked_on={reason_code,needs}`. Применить решение человека:
   - **approve** (например на `DEPLOY_HIGH_RISK`) → снять блок, продолжить фазу (P5 деплой и т.д.).
   - **reject** → откатить/остановить (для деплоя — не катить; пометить run остановленным).
   - **answer `<text>`** → передать ответ в зависшую фазу (например `IMPL_AMBIGUOUS`), `validate_no_secrets` на текст.
4. `state.sh set_json "$RD" '.blocked_on=$val' null` (очистить блок) + `events append … phase_start`.
5. **Idempotency-guard:** если резюмим на P5 с `deploy_intent.status==pending` (краш между intent и success) → НЕ авто-редеплой, заново escalate для ручной проверки состояния прода.
6. Запустить `/loop` redwork-step с этого места.

Один run/repo (lock). Секреты только op://, strip везде.
