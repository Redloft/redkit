# plan-panel — applied methodology lessons

Провенанс усвоенных методологических уроков (правок role-промптов). Источник: ledger
(`feedback/learnings.jsonl`) → `solidify.sh scan` → апрув → `solidify.sh apply`. Урок живёт ЗДЕСЬ,
в самом скилле, а не только в общей auto-memory.

- **2026-06-27** · `qa` · success-signal-integrity + persistence-round-trip — критерий «успешно» должен мерять РЕЗУЛЬТАТ, а не прокси-флаг; на write-путях нужен round-trip assert. (вручную, по реальному кейсу Termoport promo-bug; до ledger-петли)
- **2026-06-27** · `data`,`backend` · type-impedance-on-write — coercion в типизированное хранилище (float→INT и т.п.) может тихо ронять весь update; deferred-debt blast-radius. (вручную, тот же кейс)
- **2026-06-27** · `judge` · empirical-unknown — третий бакет классификации остатка (runtime внешней системы × тип поля × движок), не закрывается ни панелью, ни /finalize → на live-verify. (вручную, тот же кейс)

_Дальше — автоматически: meta-критик каждого прогона пишет находки в ledger, `scan` поднимает повторяющиеся темы, `apply` дописывает сюда._
