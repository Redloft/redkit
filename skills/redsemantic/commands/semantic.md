# /redsemantic — caller contract

Зеркалит `redresearch/commands/research.md`. Оркестрация — `workflow/semantic.js` (Workflow tool). Caller (Claude) делает persist + state + Workflow-launch + пишет артефакты (Workflow-скрипты не имеют FS).

## `/redsemantic <topic> [--region <gео>] [--mode lite|standard|heavy]`

1. **Извлеки** topic (бизнес-ядро + гео), mode (default `lite`), region.
2. **Slug + run dir:** `SLUG=$(...)`; `RUN_DIR|TS = $(bash lib/persist.sh "$SLUG")`.
3. **Probe источников** (у caller есть Bash): `bash lib/adapters/probe.sh --smoke --region "<гео>" [--site <url>]` → JSON с per-adapter `{credentialed, returns_data, reason}` (контракт `docs/probe-contract.md`). Передай в args: `available_adapters` = `bash lib/adapters/probe.sh --names --smoke --region "<гео>"` (только реально отдающие данные!), и `adapter_status` = весь `.smoke`-объект (для громкого GSC-warning, R2). Так DataForSEO для РФ и непривязанный GSC не пройдут как «живые».
   - **existing-site:** если улучшаем СУЩЕСТВУЮЩИЙ сайт — передай `site_url` (https). Включит Recon-фазу (фетч sitemap/контента через url-guard) + verify-offerings (R4) + structure-vs-routes (R5) + GSC-warning наверху (R2).
4. **Init state:** `source lib/heartbeat.sh; init_status "$RUN_DIR" "$SLUG" "$MODE" "$RUN_ID"`. Запиши `run-spec.json` (topic, mode, region, adapters, git_rev, created_at).
5. **Launch Workflow:**
   ```
   Workflow({ scriptPath: ~/.claude/skills/redsemantic/workflow/semantic.js,
     args: { topic, region, mode, site_type, run_id, timestamp, slug, git_rev,
             available_adapters } })
   ```
   Сразу сохрани `wf_runId`: `set_workflow_id "$RUN_DIR" "<wf_runId>"`.
6. **Пиши артефакты** из `result.artifacts` через Write в `$RUN_DIR/`:
   `keyword_universe.jsonl, clusters.json, structure.json, content_plan.json, entities.json, linking_map.json, semantic.md, scope.json, learnings.entry.json`. Затем `write_status "$RUN_DIR" done completed 0`.
   **Петля самоулучшения (push):** `[ -f "$RUN_DIR/learnings.entry.json" ] && bash ~/.claude/skills/plan-panel/lib/ledger.sh append ~/.claude/skills/redsemantic "$(cat "$RUN_DIR/learnings.entry.json")" || true` — meta-критик отметил системные пробелы процесса.
7. **Покажи:** semantic.md (key_claims) + verdict/coverage + кол-во ключей/кластеров + живые адаптеры (degraded/model-fill если были) + путь. Если `degraded` из-за незаполненных кредов — напомни заполнить Wordstat/DataForSEO в 1Password.

## Управление (через `lib/manage.sh`)
| Команда | Действие |
|---|---|
| `/redsemantic-list` | `manage.sh list` |
| `/redsemantic-status <slug>` | `manage.sh status <slug>` |
| `/redsemantic-resume <slug>` | `detect_stale` → если stale/failed, Workflow с `resumeFromRunId=<workflow_run_id>` |
| `/redsemantic-cleanup [--older-than 30d]` | `manage.sh cleanup` |

## Как redloft вызывает (reuse)
redloft `landing-builder.js` запускает стадию `semantic` через `agent()` с reuseSkill-строкой — суб-агент исполняет этот пайплайн и возвращает `{artifact_type:'semantic', key_claims, body_md}`. Вход: brief+research+planning (key_claims). См. `redloft/_shared.md §8`.
