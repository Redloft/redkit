# Iteration / closing-flow prompt — {{PROJECT_NAME}}
<!-- EN: Paste at the end of a work session to close it cleanly. (MP-014 / MP-025) -->

> Вставь этот промпт в конце рабочей сессии, чтобы закрыть её чисто.
> _Use this to wrap up a session before committing._

```
Закрываем итерацию по задаче <NN-описание>.

1. Покажи git diff — что реально изменилось.
2. Прогон /finalize: typecheck + lint + build + ревью diff. Если красное — чини, не коммить.
3. Коммит ТОЛЬКО нужных путей (git add <пути>, не git add .). Сообщение по сути изменений.
4. Перенеси задачу docs/tasks/in_progress/<NN>.md → docs/tasks/done/.
5. Кратко: что сделано, что осталось, нужна ли follow-up задача в pending/.
```

## Чеклист закрытия · Closing checklist
- [ ] `/finalize` зелёный (typecheck/lint/build/ревью)
- [ ] Коммит только нужных файлов (pathspec), на рабочей ветке (не main/dev)
- [ ] Задача перенесена в `done/`
- [ ] Нет секретов/PII в diff
