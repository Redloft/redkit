# plan-panel — multi-role plan verification skill

Multi-agent skill для верификации плана / RFC / implementation strategy. Spawns panel of expert subagents (architect, qa, judge всегда; security/frontend/backend/data/ops conditional based on scope), каждый с строгим checklist-driven protocol. Final judge синтезирует findings в priority-ranked action list с cross-examination конфликтов.

## Status

- **Phase A (MVP)** — реализовано: scoper (Haiku), architect, qa, security, judge (Fable). Workflow orchestrator. /plan-review команда. Dual persistence.
- **Phase B (next session)** — TBD: frontend, backend, data, ops роли. Feedback collection + solidify auto-trigger через Stop-hook. TG нотификация о готовом diff для solidify.

## Quick start

```
/plan-review <план как Markdown текст>
```

Или передай файл: `/plan-review @path/to/plan.md`. Или пусто — возьмёт последний значимый план из текущей сессии.

## Flow

```
plan → SCOPE (Haiku scoper) → scope_tags + selected_roles
       ↓
       PARALLEL REVIEW (Sonnet, выбранные роли)
       каждая роль → JSON по schema из _shared.md
       ↓
       JUDGE (Fable) → synthesis, conflicts, gaps, priority actions
       ↓
       judge.md + полный artifacts в .plan-panel/<ts>-<slug>/
       ↓
       summary в чат
```

## Roles

| Role | Model | Activation |
|---|---|---|
| `scoper` | Haiku | Always — entry point |
| `architect` | Sonnet | Always |
| `qa` | Sonnet | Always |
| `judge` | Fable | Always (с cross-exam в heavy mode) |
| `security` | Sonnet | Conditional: backend, auth, data, api, infra, external-integration, credentials/tokens/passwords/PII в плане |
| `frontend` | Sonnet | TBD Phase B — conditional: frontend, ui, ux, web, mobile |
| `backend` | Sonnet | TBD Phase B — conditional: backend, api, server, endpoint |
| `data` | Sonnet | TBD Phase B — conditional: data, db, migration, supabase, postgres |
| `ops` | Sonnet | TBD Phase B — conditional: deploy, infra, ci-cd, production |

## Modes

| Mode | Roles | Cost | When |
|---|---|---|---|
| `--lite` | architect + qa + judge (no conditional) | ~$0.20 | Быстрый sanity check |
| `standard` (default) | scoper + architect + qa + judge + relevant conditional | ~$0.70-1.50 | Стандартный panel |
| `--heavy` | то же + cross-examination конфликтов | ~$1.50-2.50 | Критичный план |

## Output schema (per role)

См. `_shared.md`:

```json
{
  "role": "...",
  "verdict": "PASS|FAIL|NEEDS-WORK|UNCERTAIN",
  "confidence": 0.85,
  "findings": [{"severity": "critical|warning|suggestion", "area", "issue", "suggestion", "ref"}],
  "summary": "1-2 sentence overall",
  "self_check_passed": true
}
```

Judge добавляет `priority_actions`, `conflicts`, `gaps`, `final_verdict_reasoning`.

## Composability (другие skills)

Роли **ссылаются** на другие skills для context, но не вызывают их:

- `security` → `~/.claude/skills/secrets/SKILL.md` (1Password vault protocol)
- `frontend` → `~/.claude/skills/animate/` + `~/.claude/skills/emil-design-eng/`
- `data` → `supabase` skill
- `ops` → `$CLAUDECORE_PATH/servers/`, `projects/`

## Persistence (hybrid)

Каждый run создаёт:
- `<cwd>/.plan-panel/<YYYY-MM-DD_HH-MM-SS>-<slug>/` — project-local, git-trackable
- `$CLAUDECORE_PATH/plan-panel/<project>/<...>/` — central mirror (symlink to project)

Содержит: `plan.md`, `scope.json`, `review.md` (sectioned by role, sole-author rule), `judge.md`, `metadata.json`.

## Self-improvement loop (Phase B)

После каждого run пользователь даёт `/panel-feedback role:X useful=true/false reason="..."`. Когда накопилось ≥10 entries для роли — auto-trigger готовит **diff** для role prompt через meta-agent (Fable) и шлёт TG-нотификацию через `@rltimebot`. Пользователь approve/reject. Версионирование в `roles/<role>.history/`.

## Architecture decisions log

- **Sole-author rule** (← aws-samples) — каждая роль владеет одной секцией artifact'а
- **Spec-driven directory с structured JSON output** — для parseable feedback loop
- **Model tier routing** (Haiku/Sonnet/Fable) — экономия 5-10x на масштабе
- **Scope-driven activation** — никаких "всегда 50 ролей"; scoper решает, пользователь может override
- **Protocols-driven, не personality-driven** — каждая роль имеет numbered checklist, не "vibe"

См. `$CLAUDECORE_PATH/projects/plan-panel.md` для полной карты проекта (TBD).

## Стоимость на масштабе

- 1 standard run: ~$1
- 10 runs/неделя × 50 недель: ~$500/год. С учётом что качество decision-making повышается → стоит.
- Solidify run раз в 2-3 недели: ~$0.50, незначительно.

## Файлы

```
~/.claude/skills/plan-panel/
├── SKILL.md                # entry point, triggers
├── README.md               # это
├── _shared.md              # severity rubric, output schema, sole-author rule
├── roles/
│   ├── scoper.md           # Haiku, always
│   ├── architect.md
│   ├── qa.md
│   ├── security.md
│   ├── judge.md            # Fable
│   └── _history/           # versioned role prompts after solidify (Phase B)
├── workflow/
│   └── panel.js            # детерминистский orchestrator
├── lib/
│   └── persist.sh          # dual persistence helper
└── feedback/               # per-role feedback log (Phase B)

~/.claude/commands/
└── plan-review.md          # entry command
```
