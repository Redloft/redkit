# redsemantic — shared contract

Единый контракт стадий пайплайна (scope/seed/harvest/cluster/structure/judge), артефактов и адаптеров. Зеркалит модель `redresearch/_shared.md`.

> **Local-first:** всё в `~/Library/Application Support/redsemantic/runs/<TS>-<slug>/`, **НЕ** в Yandex.Disk (data residency: частотности/семантика не синкаются в RU cloud). Гарантирует `lib/persist.sh`.

---

## 1. Артефакты run-каталога

| Файл | Writer | Формат | Назначение |
|---|---|---|---|
| `run-spec.json` | caller | JSON | вход: topic, mode, region, adapters, флаги |
| `status.json` | heartbeat.sh | JSON | single source of truth (status/phase/worker_pid/workflow_run_id) |
| `run.log` | log.sh | JSONL | append-only event log (secret-scrubbed) |
| `keyword_universe.jsonl` | harvest | JSONL | по ключу на строку: `{phrase, freq, source, intent}` |
| `clusters.json` | cluster | JSON | `intent_clusters[]` + `content_clusters[]` + `orphan_keywords[]` |
| `structure.json` | structure | JSON | `structure[]` — узлы сайта (вход для redloft sitemap) |
| `content_plan.json` | structure | JSON | `seo_pages[]` + `blog_topics[]` + `faq[]` |
| `entities.json` | structure | JSON | `entities[]` для schema.org/GEO |
| `linking_map.json` | structure | JSON | `linking_map[]` внутренняя перелинковка |
| `semantic.md` | structure+judge | Markdown | человекочитаемый отчёт + YAML key_claims header (контракт redloft §3) |
| `scope.json` | scoper | JSON | регион/язык/адаптеры (reproducibility) |

## 2. status.json (state machine)
Поля: `schema_version, run_id, slug, mode, status, phase, started_at, last_heartbeat, worker_pid, exit_code, workflow_run_id`.
- `status` ∈ `pending|running|completed|failed|cancelled|interrupted`.
- `phase` ∈ `init scope seed harvest cluster structure judge render done`.
- Атомарная запись (tmp+mv под mkdir-локом). `set_workflow_id` пишет `workflow_run_id` для resume (F7).

## 3. Intent-таксономия (единая)
`commercial` (купить/заказать/цена) · `service` (конкретная услуга) · `informational` (узнать/как) · `branded` (бренды свои+конкурентов) · `navigational` (рядом/адрес/режим).

## 4. Адаптеры (`lib/adapters/`)
Контракт: вход `<phrase> [flags]` → нормализованный JSON `{source, keywords:[{phrase, freq, intent?}]}` на stdout; `--self-test` → exit code + проверка поля.
- 🔒 Секреты только через `op run --env-file=<(...)`. Никаких `op read`/`--reveal`/`-v`/`2>&1`.
- **Честность freq:** число только из живого ответа; нет — `null`/отсутствует. Модель не выдумывает частотности (`source=model`, `freq=null`).
- `probe.sh` → `{available[], detail{}}`; выводит ТОЛЬКО boolean доступности, не значения кредов.

## 5. Coverage/confidence-рубрика (judge)
- **coverage** — доля JTBD/USP бизнеса, покрытых кластерами (0-1).
- **confidence** — функция полноты живых источников + чистоты кластеров (не правдоподобия). Model-only потолок ≈0.7 (нет живой частотности).
- **verdict:** PASS (coverage ≥0.8, в lite/model-only ≥0.7) · NEEDS-WORK · FAIL.

## 6. Security baseline
- SSRF: client-URL (если фетчим) — через guard перед запросом (в redloft — `url-guard.sh`).
- Секреты: `op run` снаружи; `log.sh` скрабит Api-Key/Basic/op://; адаптеры без verbose.
- Local-first: только App Support, не Yandex.Disk.

## 7. Что стадия НЕ делает
- ❌ не выдумывает частотности; ❌ не плодит кластеры/узлы без спроса; ❌ не печатает секреты;
- ❌ не строит структуру в обход кластеров (семантика — источник структуры, не наоборот);
- ❌ не зацикливается молча при пустом источнике — degraded + честный verdict.
