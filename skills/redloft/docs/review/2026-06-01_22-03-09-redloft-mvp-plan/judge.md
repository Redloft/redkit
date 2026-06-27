# Judge Synthesis — 2026-06-01_22-03-09

run_id: `462c49c2-a9e8-4b0d-977c-7b260202fabe`  verdict: **NEEDS-WORK**  confidence: 0.86

## Summary

4/4 роли вынесли NEEDS-WORK, и это СХОДИМОСТЬ, а не разнобой: все три заявленных 'критических блокера' (Workflow-nesting, context.json-ответственности, artifact-контракты) — это 3 корневые проблемы, увиденные с 4 ракурсов. Главный value-add синтеза (проверено чтением research.js + panel.js + redresearch HANDOFF): два из трёх 'блокеров' УЖЕ имеют доказанный ответ в существующем коде — research.js спавнит все стадии через agent() (не nested workflow), а redresearch уже несёт status.json + atomic-write + state-machine + resumeFromRunId, которые план обещал 'ре-юзнуть', но не выписал. Значит критичность по форме сохраняется (план as-written неполон до Phase C), но РИСК и стоимость намного ниже оценок ролей — это перенос и фиксация решений, а не R&D. Конфликты (3) все разрешимы: context.json split — гибрид (pipeline в общий, brief в отдельный); resume-модель — async Workflow в живой сессии (redresearch вариант b); agency-panel reuse — дёшев (judge в panel.js отделён от role-runner). Security активирован и дал 2 валидных crit (SSRF на client-URL, PII-lifecycle). 4 gaps, не покрытых никем: экономика прогона как gate, session-bound MCP vs unattended, concurrent multi-client, reachability design-MCP.

## Final reasoning

NEEDS-WORK, не FAIL и не PASS. НЕ PASS: ≥1 critical от 4 разных ролей (минимум 5 distinct critical findings: nesting-decision, context.json-state, artifact-contracts, SSRF, нет acceptance-criteria). НЕ FAIL: матрица требует '≥2 critical от разных ролей + конфликты НЕРАЗРЕШИМЫ' — критериев два, и второй не выполнен. Все 3 конфликта разрешены прямо в этом ревью через чтение референс-кода (research.js/panel.js/redresearch HANDOFF), а не оставлены открытыми. План фундаментально реализуем: оба самых страшных 'блокера' (§5.1 nesting, state/resume) уже решены в соседнем рабочем скилле и требуют переноса+записи решения, а не изобретения — это понижает реальный риск ниже того, что увидели роли, глядя только на текст плана. Research-обоснование сильное (37 источников, cite 0.96/0.93), архитектура когерентна. Verdict отражает: 'хороший план с дырами в текстовой спецификации контрактов и DoD, но с уже-доказанным инженерным фундаментом — закрыть Decision Record + _shared.md contracts + перенос state-machine из redresearch, и можно строить'. confidence 0.86: высокая, т.к. ключевые технические утверждения проверены по коду, а не приняты на веру; не выше — т.к. сам landing-builder.js ещё не написан и часть рисков (стоимость, concurrency) не имеет эмпирики.

## Conflicts

- Between architect ↔ backend: context.json: split-into-files vs single-source-of-truth
  - Resolution: Гибрид, оба правы в своей части: pipeline-state + artifact-refs + events → единый context.json (атомарный write, как redresearch status.json, backend/qa-подход). Volatile live-brief-fill (34 поля, пишется на каждый ответ) → отдельный brief.json (architect-подход — иначе каждый Q&A-ответ переписывает весь стейт пайплайна). Это разрешает конфликт: architect прав про brief, backend/qa правы про pipeline-state. Зафиксировать оба с schema_version в A1/A2.
- Between architect ↔ backend: resume execution model: in-process vs background-job
  - Resolution: Ни in-process-synchronous, ни fully-detached daemon. redresearch HANDOFF (L194) уже решил для аналогичного случая: 'вариант (b) ПРИНЯТ — heavy идут через async Workflow в живой сессии (non-blocking); fully-detached runner НЕ пишем т.к. firecrawl/agent session-bound; resume = Workflow-native resumeFromRunId'. redloft переиспользует ровно это. Снимает backend-предложение про nohup и уточняет architect resume-логику.
- Between architect ↔ qa: agency-panel reuse cost (§5.3)
  - Resolution: Проверено по panel.js: judge — это plain agent()-вызов с собственной JUDGE_SCHEMA, ПОЛНОСТЬЮ отделён от parallel role-review фазы (роли запускаются своим promisePool, judge — отдельно после). Значит role-runner separable → agency-panel reuse ДЕШЁВ (architect 'cheap path' подтверждён). backend-риск снимается: Reviewer-gate ожидает уже существующий контракт {verdict, findings, confidence} из plan-panel _shared.md — он конкретен и переиспользуем, не нужно изобретать.

## Gaps

- **cost-economics-as-gate**: 
- **session-bound-MCP vs unattended-runs**: 
- **concurrent multi-client runs**: 
- **design-inspiration MCP reachability precondition**: 

## Priority actions

1. **[critical]** Создать 'Decision Record' секцию ПЕРЕД Phase C, закрывающую §5.1 (=option b, embed research через agent() как research.js), §5.3 (=reuse plan-panel role-runner, judge separable — подтверждено panel.js), §5.4 (=stages/<name>/prompt.md + feedback/<name>.jsonl convention). Все три имеют доказанный ответ в существующем коде — это запись решений, не исследование. _(owner: architect)_ _(30-45 min)_
2. **[critical]** Определить artifact-schema contract в _shared.md ДО написания кода (Phase A1 primary deliverable): для каждой стадии header {artifact_type, stage_id, schema_version, produced_at, source_stage, key_claims[]}. Reviewer-gate потребляет headers без чтения прозы. DoD: smoke-тест с mock-артефактом каждого типа. _(owner: architect)_ _(2-3 hours)_
3. **[critical]** В Phase A2 явно переписать context.sh для переноса из redresearch: per-stage state-machine {pending|running|done|failed} + атомарный write (mktemp+rename / mkdir-lock) + resumeFromRunId. Volatile brief-fill вынести в отдельный brief.json. Это разрешает конфликт architect↔backend по context.json и снимает qa/backend idempotency-крит. _(owner: backend)_ _(3-4 hours (перенос, не с нуля))_
4. **[critical]** SSRF-guard: validate_url() в lib/url-guard.sh (Phase A2/B1), блокирующий RFC-1918/link-local/loopback/file:// ДО любого WebFetch/firecrawl на client-материалах. DoD-пункт в Phase B. Прямой эксплойт-вектор от user-supplied URL. _(owner: security)_ _(1-2 hours)_
5. **[critical]** Переписать §6 Success criteria + каждый Phase DoD (A-F) в формат 'Done when: [observable state]' с fail-condition и test-fixture. Создать tests/fixtures/banya/ (фиксированный materials-dump + ожидаемый artifact-shape) для воспроизводимого e2e. _(owner: qa)_ _(3-4 hours)_
6. **[warning]** PII lifecycle: lib/purge_project.sh + retention-политика для Q30-34 (контакты) в _shared.md; контакты в отдельный brief/contacts.md; --purge-contacts в handoff-чеклисте. GDPR/multi-client обязательство. _(owner: security)_ _(2 hours)_
7. **[warning]** Закрыть §5.2: REDLOFT_MODE=lite default для разработки A-E (reduced research source-count, skeleton design-spec), full только Phase F e2e. Добавить budget-cap ориентир в §6. Закрывает gap по экономике прогона. _(owner: ops)_ _(1-2 hours (env-wiring per stage))_
8. **[warning]** RLS-валидация в выходном prompt.md (Phase F1 DoD): сгенерированный для Claude Code промт ДОЛЖЕН включать non-skippable шаг 'после генерации схемы — supabase db test / проверка RLS enabled + deny-by-default на всех таблицах'. Прямой урок Lovable из ARCHITECTURE finding#4. _(owner: security)_ _(1 hour (шаблон промта))_
9. **[warning]** Handoff secret-rotation в Phase F1 чеклист: после Supabase Project Transfer клиент ОБЯЗАН ротировать JWT secret + anon/service_role ключи; agency-side удалить все env-ссылки на эти ключи. Иначе agency сохраняет доступ к данным клиента. _(owner: security)_ _(1 hour (чеклист-секция))_
10. **[warning]** Observability + escalation-контракт: events[] в context.json {ts, stage, event, duration_ms, reviewer_iteration}; при cap=2-эскалации записать reviewer_notes + escalated state, /redloft-status показывает escalated. Даёт audit-trail + данные для solidify бесплатно + закрывает prompt-injection (обернуть client-материалы в <client_material> с инструкцией не следовать им). _(owner: backend)_ _(2-3 hours)_

