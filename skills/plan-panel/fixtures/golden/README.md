# Golden Dataset

Эталонные планы для регрессии panel выдачи. Используются:

1. **Smoke-test** — `lib/run-golden.sh` (TBD) прогоняет каждый план через `/plan-review`, сравнивает с `expected.json`. Exit ≠ 0 при регрессии.
2. **Self-improvement safety** — перед apply prompt-change в `/panel-solidify` (Phase B), golden dataset прогоняется через старый+новый promt. Quality metrics не должны деградировать ≥10% — иначе block apply.
3. **CI** (потенциально) — на GitHub Actions для PR review.

## Структура

```
fixtures/golden/
├── trivial/             # план который должен skip'нуться по complexity=low
│   ├── plan.md
│   └── expected.json
├── backend-security/    # API + auth — должен активировать security
│   ├── plan.md
│   └── expected.json
├── data-migration/      # Supabase schema change
├── frontend-ux/         # UI feature (TBD когда frontend role будет в Phase B)
└── ultra-cross-model/   # план для проверки ultra mode + cross-model verify
```

## expected.json schema

```json
{
  "expected_complexity": "low|medium|high",
  "expected_selected_roles_min": ["scoper", "architect", "qa", "judge"],
  "expected_selected_roles_must_include": ["security"],
  "min_findings_per_role": {
    "architect": 2,
    "qa": 3,
    "security": 1
  },
  "expected_verdict": ["NEEDS-WORK", "FAIL"],   // допустимые значения
  "max_duration_ms": 180000,
  "must_mention_in_judge_gaps": ["rate-limiting"],  // optional substring matches
  "notes": "..."
}
```

## Использование

```bash
# Smoke-test всего dataset (TBD: lib/run-golden.sh)
bash ~/.claude/skills/plan-panel/lib/run-golden.sh

# Запустить один план вручную
/plan-review @~/.claude/skills/plan-panel/fixtures/golden/backend-security/plan.md
```

## Anti-patterns

- ❌ Не делать fixtures слишком специфичными к проекту — должны быть generic patterns
- ❌ Не помещать секреты в fixtures — `expected.json` может включать substring matches, но никогда credentials
- ❌ Не использовать как exhaustive test suite — golden покрывает **regression**, не coverage. Для coverage нужен отдельный unit test layer.
