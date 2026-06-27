# {{PROJECT_TITLE}} — project hub for Claude / AI agents
<!-- EN: Router file. AI chats read this on start. Keep it thin — link out, don't inline. -->

> Это hub-роутер проекта **{{PROJECT_NAME}}**. Любой Claude-чат читает его при старте.
> Тонкий по дизайну: ссылается, а не дублирует. _Thin by design — links, not copies._

## 👋 Новый в проекте? → прочитай `START-HERE.md`
Там рабочий цикл за 1 минуту. Этот файл — карта, START-HERE — инструкция.

## Что за проект
- **Название / Name:** {{PROJECT_NAME}}
- **Описание:** {{PROJECT_TITLE}}
- **Стек / Stack:** {{STACK}}
- **ТЗ на сайт / Product spec:** `docs/tz.md` (источник правды по продукту)

## Как работаем · How we work
| Нужно | Файл |
|---|---|
| Как вести работу (цикл) | `START-HERE.md` |
| Правила, которые нельзя нарушать | `docs/HARD-RULES.md` |
| Жизненный цикл задач | `docs/tasks/PROTOCOL.md` |
| Режимы работы (стратегич./быстрый) | `docs/working-protocol.md` |
| Промпт закрытия итерации | `docs/prompts/iteration.md` |

## Security (кратко, полное — HARD-RULES §F)
- БД: RLS **deny-by-default** — `supabase/rls-bootstrap.sql` применяется до деплоя.
- Секреты: только 1Password / `op run`, **никогда** в код/`.env`/чат.
- PII (контакты клиента): не коммитить, lifecycle по HARD-RULES.

<!-- redloft: сгенерировано при создании проекта (methodology kit, tier {{TIER}}). -->
