# DESIGN — Stage 2 / Часть B: `/finalize` (stabilize + panel review по diff)

> Status: **SPEC, не реализовано.** Ревизия после panel-review (run `2026-06-02_00-54-06`, NEEDS-WORK).
> **Зависит от `plan-panel/DESIGN-foundation.md` (Stage 0)** — finalize-envelope, `review_mode=code` overlay,
> checkpoint, `checked_files`, validators, fixer budget берутся оттуда.
> Намеренно нет `SKILL.md` (dir = только DESIGN.md → скилл не регистрируется). `SKILL.md` = при реализации.

## Проблема

Конец сессии: «наисправляли кучу, надо застабилизировать и сделать код-ревью в финале».
`plan-panel` ревьюит план, не код. Встроенный `/code-review` только ревьюит, **не стабилизирует**
(не гоняет typecheck/lint/build/test и не чинит) и живёт вне семьи ролей redplan.
Нужен один жест: **сначала привести код к зелёному, потом панель ролей по изменениям сессии.**

## Активация

```
/finalize            # diff = всё незакоммиченное
/finalize --staged | --since <ref> | --review-only | --lite | --ultra
```
Триггеры (SKILL.md): «застабилизируй и сделай ревью», «финал сессии», «закругляемся, прогони финалку»,
"stabilize and review", "finalize this", "final code review".

## Flow

```
Phase 0 SNAPSHOT
   → git diff --stat + changed_files[] + языки + размер; project_slug; gates (см. §gates)
   → СРАЗУ secrets-strip pass (§secrets) — НИЧЕГО с сырыми секретами дальше не идёт
   → пустой diff → стоп
   ↓ checkpoint{run_type:'finalize', phase:'snapshot'}
Phase 1 STABILIZE  (если не --review-only; lockfile §lock)
   → gates по очереди typecheck→lint→build→test
   → pre-flight: gate сам падает (ENOENT/network)? → infra-error, fixer НЕ запускается (§fixer)
   → код красит → fixer-агент (Sonnet) чинит причину, не симптом → перегон
   → петля до зелёного или STABILIZE_MAX_ROUNDS=3 → не сошлось: unstable + remaining_failures[]
   ↓
Phase 2 SCOPE (Haiku) — по содержимому diff
Phase 3 PANEL REVIEW (Sonnet, review_mode='code') — роли читают diff, finalize-envelope (Stage 0 §1.3)
   → chunking при большом diff (§chunk)
Phase 4 JUDGE (Fable) — синтез + cross-exam + gaps + verdict SHIP/FIX-FIRST/NEEDS-WORK
   → stable:false ⇒ verdict ≠ SHIP
   ↓
Persistence + user summary
```

## Переиспользование plan-panel (Stage 0 закрывает контракты)

| Берём как есть | Адаптируем |
|---|---|
| `_shared.md` FINDINGS_SCHEMA, severity, sole-author, fail-fast | envelope `plan_text`→finalize-envelope (Stage 0 §1.3) |
| Роли + `review_mode=code` overlay (Stage 0 §1.4 — **не дублируем role-файлы**) | judge verdict-словарь PASS→SHIP, FAIL→FIX-FIRST |
| checkpoint/persist (Stage 0 §2) | dir `.finalize/<ts>-<slug>/` (sync-exclude, §secrets) |

## 🔒 §secrets — secrets-hygiene (critical #3, gap «secrets-binding»)

Прямая привязка к `~/.claude/skills/secrets/SKILL.md` и глобальному протоколу пользователя.
Нарушение здесь = нарушение протокола, поэтому это **первый** и **обязательный** механизм.

1. **Strip-secrets pass** до любой записи на диск и до любого agent-envelope:
   - regex-скан diff на token-префиксы (`sk-`, `ghp_`, `AIza`, `xoxb-`, PEM-блоки, `op://`, `Bearer `, base64 SASL) + high-entropy строки;
   - попадания → заменить на `‹REDACTED:reason›` в `diff_text`/`full_files`; оригинал НИКОГДА не пишется.
2. **diff.patch** сохраняется уже **после** strip. Сырой diff на диск не попадает.
3. **fixer deny-list**: credential-файлы (`.env*`, `*.pem`, `*.key`, `*.p12`, `*.keystore`, `*credentials*`, `secrets/*`, `*.tfvars`, `id_rsa*`) — fixer их не открывает и не правит; находку эскалирует security-роли. **Runtime-enforcement**: не «на честном слове» промпта, а wrapper над tool-call fixer'а, который отклоняет Read/Edit по deny-list-паттерну (defense-in-depth).
   - **Pre-flight integrity gate**: `strip-secrets.sh` self-test (известный набор token-префиксов → все застрипаны) ОБЯЗАН пройти до старта `/finalize`; провал → abort (strip сломан = нельзя гарантировать безопасность).
4. **finding.ref** — только `path:line`, без literal-значений (overlay уже это требует; здесь enforce).
5. **sync-exclude**: `.finalize/` в Yandex.Disk ignore; central mirror для finalize — **metadata-only** (без diff/reviews с кодом). (Stage 0 §2.4.)
6. security-роль ОБЯЗАНА флагнуть любое изменение в `.env`/секретах как critical → verdict FIX-FIRST.

## §gates — определение проверок
Автодетект: 1) `$CLAUDECORE_PATH/projects/<slug>.md` (если прописаны команды); 2) `package.json` scripts (typecheck/tsc, lint, build, test); 3) Makefile/cargo/pytest/ruff/go test; 4) ничего → skip Phase 1, `stable:unknown`, review всё равно идёт (judge не понижает verdict, но отмечает gap «нет автопроверок»).

## §fixer — fixer-агент (Sonnet, budget Stage 0 §1.6)
Tools: Read/Edit/Bash/codegraph. Правила:
- **Чинить причину, не глушить** тест/линтер. Легитимное падение (тест ловит реальный баг в свежем коде) → фиксит **код**, не тест. Enforce: regex-guard на diff fixer'а (Stage 0 §4) → `fixer_warnings[]`.
- **code-failure vs infra-failure** (action #5): pre-flight — если gate падает не из-за кода (ENOENT, network, отсутствует бинарь) → `status:infra-error`, `stable:unknown`, fixer не запускается, в summary явно.
- Fixer crash/timeout → расширенный fail-fast (`_shared.md §9`): остановить stabilize, перейти к review с `stable:false`.

## §lock — конкурентность (action #9, v2-warning #10)
Lock на время STABILIZE (мутирует рабочее дерево) через `checkpoint_acquire` (Stage 0 §2.2, `mkdir`-lock с `{pid, started_at, ttl}`). Параллельный `/finalize` → ждёт/отказывает. Review-фазы read-only, лок не нужен.
- **Stale-lock reclaim**: если процесс с `pid` мёртв ИЛИ `now - started_at > ttl` → lock переотбирается (иначе крэшнувший run навсегда блокирует проект).
- **Project-level lock** (Stage 0 §2.5): сериализует с конкурентным `from-task` на том же slug.

## §ops — operability (v2-warning #10)
- **Troubleshooting runbook** в `SKILL.md` обеих частей: что делать при `status=crashed`, stale-lock, schema-version mismatch, infra-error.
- `checkpoints` index (список активных/просроченных run'ов) для GC и навигации.
- ISO-8601 timestamps везде; backup story: canonical = local `.finalize/`, central mirror = metadata-only.

## §chunk — большой diff (action #9)
diff > N=200 changed files **или** > ~20k токенов на роль → бить по **logical groups** (directory-prefix, ≤ M=100 файлов/группа); каждой группе — свой проход роли; judge агрегирует. `log()` о дроблении (no silent cap). Роль заполняет `checked_files[]` (Stage 0 §1.5).

## Новые файлы
`finalize/SKILL.md`, `finalize/workflow/finalize.js`, `finalize/lib/detect-gates.sh`, `finalize/lib/strip-secrets.sh`, `finalize/lib/persist.sh` (тонкая обёртка над Stage 0 checkpoint), правки в `plan-panel/roles/*.md` (overlay из Stage 0 §1.4).

## Acceptance criteria (executable)

| Фаза | Done when |
|---|---|
| **0. Snapshot** | непустой diff иначе exit; `changed_files[]`/языки/gates; **strip-pass отработал** (0 token-префиксов в записанном diff.patch — проверяется тем же regex). |
| **1. Stabilize** | gates зелёные ИЛИ ≤MAX_ROUNDS → `stable:false`+`remaining_failures[]`; infra-error → `stable:unknown`; `fixer_warnings[]` пуст ИЛИ обоснован; lock снят. |
| **2. Scope** | `selected_roles ≥ 3` иначе fail-fast. |
| **3. Review** | каждая роль — FINDINGS_SCHEMA по diff, ≥1 actionable с `ref` на `path:line`, `checked_files[]` заполнен. |
| **4. Judge** | verdict SHIP/FIX-FIRST/NEEDS-WORK; `stable∈{false,unknown}` ⇒ verdict≠SHIP; gaps учитывают skipped + «нет автопроверок» если gates не найдены. |
| **Persist** | `.finalize/<ts>-<slug>/`: `diff.patch`(stripped), `stabilize.json`, `scope.json`, `reviews.json`, `review.md`, `judge.md`, `metadata.json`; central mirror = metadata-only. |
| **User summary** | verdict + stable? + что чинили + top-5 + conflicts/gaps + путь. Не вываливать diff. |

## Edge cases (+ из panel-review)

| Edge case | Handling |
|---|---|
| Огромный diff | §chunk; `log()` о дроблении. |
| gates не найдены | skip, `stable:unknown`; judge gap «нет автопроверок», verdict не понижает. |
| Fixer в цикле (чинит A — ломает B) | MAX_ROUNDS=3 + `regressed`-детект (critical_count вырос) → unstable + remaining. |
| Изменения в .env/секретах | strip + fixer deny-list + security critical → FIX-FIRST. |
| infra-failure (нет бинаря/network) | `stable:unknown`, fixer не запускается, явно в summary. |
| `--review-only` на грязном дереве | skip stabilize, в summary «стабилизация пропущена». |
| Намеренно не закоммичено | **НИКОГДА не коммитим/не пушим сами** — только чиним дерево и ревьюим. |
