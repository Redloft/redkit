# core-MPs — provenance index (maintainer-only)
<!-- NOT copied into projects. Documents which Wellbookin MPs each kit template generalizes from. -->

> Эта папка — **карта происхождения**: из каких Wellbookin Methodology Proposals выведены
> шаблоны коробки. Шаблоны написаны **сразу generalized** (Wellbookin-isms вычищены, см.
> SPEC §7), поэтому отдельных портов MP здесь нет — только трассируемость «шаблон → MP».
> В проекты НЕ копируется (нет в `MANIFEST.json`).

## Tier → шаблон → исходные MP
| Tier | Шаблон | Generalized из MP |
|---|---|---|
| 0 | `CLAUDE.md` (hub-router) | MP-031, MP-033 |
| 0 | `docs/HARD-RULES.md` (6 кластеров) | MP-028 + MP-009 (pathspec) + MP-013 (branch-verify) |
| 0 | `supabase/rls-bootstrap.sql` | DR-7 (RLS-in-output) |
| 0 | `START-HERE.md` | new (онбординг, SPEC §11) |
| 1 | `docs/tasks/PROTOCOL.md` | MP-001, MP-005 (approval gate) |
| 1 | `docs/tasks/TASK-TEMPLATE.md` | MP-008 (complexity), MP-043 (status frontmatter) |
| 1 | `docs/prompts/iteration.md` | MP-014, MP-025 (closing flow) |
| 1 | `docs/working-protocol.md` | working-protocol (Mode A/B) |
| 2 | `docs/chats/REGISTRY.md` | MP-004 (planning-chats), MP-010 (model assignment) |
| 2 | `docs/chats/handoff-queue.md` | MP-034 (cross-cutting flow) |
| 2 | `docs/methodology-proposals/*` | MP-029 (MP archive-index) |
| 2 | `docs/product-principles.md` | product-principles + Feature Scoring Card |
| 3 | `docs/security-quality-gate.md` | security-quality-gate |
| 3 | `docs/performance-quality-gate.md` | performance-quality-gate |
| 3 | `.github/workflows/auto-merge.yml` | MP-018, MP-044 (tsc-gate auto-merge) |
| 3 | `docs/feedback-journal.md` | MP-020, MP-025, MP-049 |
| 3 | `routines/R1-R4` | MP-011, MP-012, MP-015, MP-017, MP-041 |
| 4 | `docs/goal-pursuit.md` | MP-050, MP-052, MP-057 |
| 4 | `docs/codegraph-setup.md` | MP-055, MP-056 |

## Cross-tier
- MP-009 (pathspec) / MP-013 (branch-verify) / MP-028 (hard-rules cluster) — отражены в Tier 0 HARD-RULES.

> При добавлении нового шаблона — добавь строку сюда (трассируемость = почему правило такое).
