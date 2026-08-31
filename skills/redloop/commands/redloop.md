Запусти автономный прогон REDLOOP по задаче: $ARGUMENTS

Иди по стадиям SKILL.md: RECON (риск, проект, NO-GO-проверка) → CONTRACT (собрать contract.json,
прогнать lib/contract-lint.sh, при отказе — ОДИН батч вопросов ≤4) → COMPILE (lib/compile.sh,
показать prompt.md) → LAUNCH (раннер по таблице; режим 3 redwork не пытаться) → WATCH
(lib/detect.sh scan между итерациями) → POSTMORTEM (метрики + lib/patterns.sh record/candidate).
