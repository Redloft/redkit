Это ПЛАН РЕАЛИЗАЦИИ REDLOFT MVP (Landing Builder) — AI-оркестратор, ведущий проект от идеи до ТЗ на сайт/лендинг через пайплайн скиллов с reviewer-петлёй.

ОБЯЗАТЕЛЬНО прочитай эти файлы ПЕРЕД ревью (через Read tool):
1. ~/.claude/skills/redloft/docs/PLAN.md — САМ ПЛАН (ревьюишь его)
2. ~/.claude/skills/redloft/docs/ARCHITECTURE.md — решения + backing (2 research-прогона: 25+12 источников, cite 0.96/0.93)
3. ~/.claude/skills/redloft/docs/SPEC.md — исходное видение пользователя
4. ~/.claude/skills/redloft/docs/brief-schema.md — схема брифа (34 вопроса)

Ревьюишь PLAN.md. Контекст: оркестратор = Claude Code Workflow tool (research.js-паттерн, уже работает в скилле redresearch); turnkey-база = Next.js+Supabase boilerplate (supastarter/MakerKit); handoff = self-serve Supabase Project Transfer; reviewer = maker-checker cap=2.

ОСОБЫЙ ФОКУС на §5 PLAN.md — 4 открытых вопроса (redresearch nesting, глубина MVP-стадий, agency-panel reuse, хранение промпт-версий). Также: реализуемость phased build (A-F), риски оркестрации/reviewer-петли/handoff, не упущены ли security (Supabase RLS/secrets) и data (Project Context) аспекты.
