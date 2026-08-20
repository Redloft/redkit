#!/usr/bin/env bash
# ledger.sh — append-only learnings ledger для петли самоулучшения red*-скиллов.
# Каждый прогон panel/finalize/red* авто-пишет сюда ОДНУ строку (push, не pull):
# вердикт + gaps + methodology_findings от meta-критика. Это источник для scheduled-solidify.
# Шарится между скиллами (finalize и др. симлинкают на plan-panel/lib, как checkpoint.sh/strip-secrets.sh).
#
# Зачем: judge каждый прогон производит сигнал (gaps/conflicts/reasoning), но раньше он оседал
# в throwaway run-dir и выбрасывался. Теперь meta-критик внутри workflow классифицирует находки на
# «дефект этого плана/кода» vs «дыра в чек-листе роли», а ledger.sh копит второе для solidify.
#
# Usage:
#   ledger.sh append  <skill_root> <json_line>   # +1 запись (валидируется + strip-secrets)
#   ledger.sh cluster <skill_root>               # агрегировать methodology-gap темы (для solidify)
#   ledger.sh stat    <skill_root>               # краткая статистика ledger'а
#   ledger.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"
# fallback: ledger могут звать из любого скилла (по skill_root-аргументу); strip живёт в plan-panel/lib
[ -f "$STRIP" ] || STRIP="$HOME/.claude/skills/plan-panel/lib/strip-secrets.sh"

_ledger_path() { echo "$1/feedback/learnings.jsonl"; }

# Служебные (машинные) поля записи — идентификаторы и enum'ы, а не свободный текст.
# К ним применяется паттерн-редакция, но НЕ Shannon-эвристика: она даёт на них чистый
# false positive (uuid и `<ts>-<slug>` ≥20 симв. → high-entropy). Проверено 2026-07-27:
# 3 из 71 записи ledger'а уже потеряли run_id именно так, и телеметрия стала неизмеримой.
LEDGER_SERVICE_KEYS='run_id,ts,skill,mode,entry_point,verdict,remainder_class,iteration,telemetry_ok,telemetry_repaired,telemetry_clobber,confidence,conflicts_count'

# --- Ф6 (2026-08-19): починка телеметрии НА ЗАПИСИ, а не уговорами caller'а -----------------
# Контракт «передай timestamp/run_id/entry_point» жил прозой в SKILL.md — и пропускался:
# 42 из 82 прогонов панели после 2026-07-27 легли с дефолтами panel.js ('now'/'unknown-run-id')
# и без entry_point, то есть больше половины петли было неизмеримо. Уговоры не сработали —
# чиним там, где есть и диск, и date(1): в самом append.
#
# Принцип: НИКОГДА не терять прогон (append случается после дорогого прогона), но и не врать.
#   ts='now'/пусто        → реальная дата момента записи (append идёт через минуты после прогона)
#     ⚠ КОНТРАКТ ДЛЯ ЧИТАТЕЛЕЙ: у ПОЧИНЕННОЙ записи ts — это время APPEND'а, а не прогона.
#     Отличать по telemetry_ok==false / telemetry_repaired[]. Любой анализ по времени прогона
#     обязан фильтровать такие записи, иначе меряет момент записи в журнал.
#   run_id пустой/дефолт  → чеканим 'late-<uuid>' (записи различимы) + telemetry_ok=false
#   entry_point нет       → 'untagged' + telemetry_ok=false
# telemetry_repaired[] — что именно чинили; поле видно в stat, чтобы «почин» не выглядел здоровьем.
_normalize_telemetry() {
  local line="$1"; local ep_arg="${2:-}"
  local now_ts; now_ts="$(date +%Y-%m-%d_%H-%M)"
  # ⚠ НЕ "uuidgen | tr || echo": код возврата пайплайна — это код tr, успешный и на пустом
  # вводе. На машине без uuidgen фолбэк не сработал бы, mint стал бы "late-" для ВСЕХ
  # записей — то есть починка вернула бы ровно ту неразличимость, ради которой затевалась.
  local uid=""
  if command -v uuidgen >/dev/null 2>&1; then uid="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"; fi
  [ -n "$uid" ] || uid="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$uid" ] || uid="${now_ts}-$$-${RANDOM:-0}"
  local mint; mint="late-$uid"
  printf '%s' "$line" | jq -c \
    --arg now "$now_ts" --arg mint "$mint" --arg ep "$ep_arg" '
    . as $o
    | ($o.ts // "" | tostring) as $ts
    | ($o.run_id // "" | tostring) as $rid
    | (($o.entry_point // "") | tostring | ascii_downcase) as $ep0raw
    # ВАЖНО: panel.js:167 и artifact-panel.js:42 дефолтят entry_point ЛИТЕРАЛОМ unknown,
    # поэтому проверки «поле пустое» недостаточно — она не сработала бы ни разу в бою.
    # Плейсхолдер = любое значение, которое не называет вызывающую сторону.
    | (if ($ep0raw | IN("", "unknown", "untagged", "none", "n/a", "не указан", "unknown-entry-point"))
       then "" else ($o.entry_point | tostring) end) as $ep0
    # ts обязан быть ДАТОЙ: cluster/quarantine/closures сравнивают его лексикографически
    # с датами (отсечка канона, closed_at). Любая не-дата ("now", число, мусор) молча
    # уезжает в «исторические» и находка выпадает из петли — поэтому валидируем ФОРМУ,
    # а не только известные дефолты.
    | (if ($ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) then false else true end) as $bad_ts
    | (if (($rid | ascii_downcase | IN("", "unknown", "unknown-run-id", "none", "n/a"))
           or ($rid | test("^unknown-run-id")) or ($rid | test("REDACTED")))
       then true else false end) as $bad_rid
    | (if ($ep0 == "" and $ep == "") then true else false end) as $bad_ep
    | $o
    | (if $bad_ts then .ts = $now else . end)
    | (if $bad_rid then .run_id = $mint else . end)
    | (if $ep != "" then .entry_point = $ep else . end)
    # clobber_note: флаг перебил НЕПУСТОЙ и НЕ-плейсхолдерный entry_point из JSON. Это
    # штатное поведение (вызывающая сторона знает точнее), но молчать нельзя: иначе
    # разбивка stat по entry_point покажет не того caller-а, и течь будут искать не там.
    | (if ($ep != "" and $ep0 != "" and $ep0 != $ep) then .telemetry_clobber = $ep0 else . end)
    | (if $bad_ep then .entry_point = "untagged" else . end)
    | (if ($bad_ts or $bad_rid or $bad_ep) then .telemetry_ok = false else . end)
    | (if ($bad_ts or $bad_rid or $bad_ep)
       then .telemetry_repaired = ([ (if $bad_ts then "ts" else empty end),
                                     (if $bad_rid then "run_id" else empty end),
                                     (if $bad_ep then "entry_point" else empty end) ])
       else . end)
  '
}

append() {
  local root="${1:?skill_root}"; local line="${2:?json_line}"; shift 2 || true
  local ep_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry-point) ep_arg="${2:-}"; shift 2 || shift ;;
      --entry-point=*) ep_arg="${1#*=}"; shift ;;
      --*) echo "⚑ ledger: неизвестный флаг $1 — проигнорирован (опечатка?)" >&2; shift ;;
      *) shift ;;
    esac
  done
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || { echo "✗ ledger: невалидный JSON" >&2; return 1; }
  # Ф6: починить телеметрию до strip (оба прохода должны видеть уже нормализованную запись).
  local normalized
  normalized="$(_normalize_telemetry "$line" "$ep_arg")" || normalized=""
  if [ -n "$normalized" ] && printf '%s' "$normalized" | jq -e . >/dev/null 2>&1; then
    local repaired; repaired="$(printf '%s' "$normalized" | jq -r '(.telemetry_repaired // []) | join(", ")')"
    [ -z "$repaired" ] || echo "⚑ ledger: телеметрия починена на записи ($repaired) — caller не передал; прогон помечен telemetry_ok=false" >&2
    local clob; clob="$(printf '%s' "$normalized" | jq -r '.telemetry_clobber // ""')"
    [ -z "$clob" ] || echo "⚑ ledger: --entry-point перебил значение из JSON ($clob → $ep_arg) — разбивка stat покажет caller-а по флагу" >&2
    line="$normalized"
  else
    echo "⚑ ledger: нормализация телеметрии не удалась → пишем как есть" >&2
  fi
  # Пофайловый strip. Свободный текст (observation, gaps, subject, …) — полный проход,
  # энтропия там и ловит утечки. Служебные поля — восстанавливаются из оригинала после
  # паттерн-редакции. Порядок важен: сначала полный strip всего, потом overlay служебных.
  local clean
  clean="$(printf '%s' "$line" | "$STRIP" 2>/dev/null)" || { echo "✗ ledger: strip failed → 0 байт на диск" >&2; return 1; }
  [ -n "$clean" ] || { echo "✗ ledger: strip дал пусто → не пишем (zero-byte guard)" >&2; return 1; }
  local svc svc_clean
  svc="$(printf '%s' "$line" | jq -c "{$LEDGER_SERVICE_KEYS} | with_entries(select(.value != null))")" \
    || { echo "✗ ledger: не смог выделить служебные поля" >&2; return 1; }
  svc_clean="$(printf '%s' "$svc" | "$STRIP" --no-entropy 2>/dev/null)" \
    || { echo "✗ ledger: strip служебных полей failed → 0 байт на диск" >&2; return 1; }
  [ -n "$svc_clean" ] || { echo "✗ ledger: strip служебных дал пусто → не пишем" >&2; return 1; }
  printf '%s' "$svc_clean" | jq -e . >/dev/null 2>&1 \
    || { echo "✗ ledger: служебные поля после strip — невалидный JSON" >&2; return 1; }
  local compact
  compact="$(printf '%s' "$clean" | jq -c --argjson svc "$svc_clean" '. * $svc')" \
    || { echo "✗ ledger: compact failed" >&2; return 1; }
  [ -n "$compact" ] || { echo "✗ ledger: compact пуст → не пишем" >&2; return 1; }
  local L; L="$(_ledger_path "$root")"; mkdir -p "$(dirname "$L")"
  # mkdir-lock (portable, macOS без flock): сериализация parallel-ultra append на Yandex.Disk
  local LOCK="$L.lock" i
  for i in $(seq 1 50); do mkdir "$LOCK" 2>/dev/null && break; sleep 0.05; done
  printf '%s\n' "$compact" >> "$L"
  # retention cap: ограничить рост append-only (cluster читает весь файл через jq -s)
  local CAP="${PLAN_PANEL_LEDGER_CAP:-1000}"
  if [ "$(wc -l < "$L" | tr -d ' ')" -gt "$CAP" ]; then tail -n "$CAP" "$L" > "$L.tmp" && mv -f "$L.tmp" "$L"; fi
  rmdir "$LOCK" 2>/dev/null || true
  echo "✓ ledger += 1 ($L; всего $(wc -l < "$L" | tr -d ' '))"
}

# Кластеризовать methodology_findings по (role + lens_key): что РЕГУЛЯРНО всплывает.
# lens_key — стабильный слаг линзы от meta-критика (язык/регистр не важны); fallback — нормализованный текст.
# Это вход для solidify: тема с count≥порог → кандидат на правку role-промпта.
_canon_path() { echo "$1/lenses/canon.json"; }
_closed_path() { echo "$1/feedback/closed.jsonl"; }

# Закрытие темы (2026-07-27). Без него петля наматывает один круг вечно: solidify.sh apply
# правит чек-лист, но находки, породившие тему, остаются в ledger'е и на следующем scan дают
# тот же счётчик — драфт-агент предложит ту же клаузу повторно. Нашла артефактная панель на
# собственной спеке (business-analyst / unhappy-path), подтверждено живым scan после 4 патчей.
#
# Семантика: закрытие гасит находки этой (role, lens_key) с ts НЕ ПОЗЖЕ closed_at.
# Находки ПОСЛЕ закрытия копятся заново — это и есть проверка «сработала ли клауза»:
# если тема всплывает снова, значит правка чек-листа не помогла, и это надо видеть.
# stdout: JSON-объект {"role||lens_key": "<последний closed_at>"} (пусто → "{}").
_closed_map() {
  local f; f="$(_closed_path "$1")"
  [ -f "$f" ] || { echo '{}'; return 0; }
  jq -sc '[.[] | select(.role and .lens_key and .closed_at)]
    | group_by((.role) + "||" + (.lens_key))
    | map({key: ((.[0].role) + "||" + (.[0].lens_key)), value: ([.[].closed_at] | max)})
    | from_entries' "$f" 2>/dev/null || echo '{}'
}

# stdout: JSON-объект {alias|key → canonical_key}. exit 1 — канона нет, exit 2 — канон битый.
# Оба ненулевых кода означают ОДНО поведение у caller'а: fail-open к до-Ф1 кластеризации.
_canon_map() {
  local canon="$1"
  [ -f "$canon" ] || return 1
  jq -e '.lenses | type == "array" and length > 0' "$canon" >/dev/null 2>&1 || return 2
  jq -ce '[.lenses[] | . as $l | ([$l.key] + ($l.aliases // [])) | map({key: ., value: $l.key})] | add | from_entries' "$canon" 2>/dev/null || return 2
}

# До-Ф1 кластеризация (свободный lens_key). Остаётся ЕДИНСТВЕННЫМ поведением для скиллов
# без своего lenses/canon.json — redloft/redresearch/redsemantic. Без этого контракта Ф1
# тихо обнулила бы их нудж навсегда: их критики не знают канона plan-panel.
_cluster_raw() {
  jq -s --argjson closed "${2:-{\}}" '
    def isdate: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}");
    [ .[] | (.ts // "") as $ts | (.methodology_findings // [])[] | select(type == "object") | . + {_ts: $ts} ]
    | map(select(
        ($closed[((.role // "") + "||" + (.lens_key // ""))] // null) as $c
        | ($c == null) or ((._ts | isdate) and (._ts > $c))))
    | map(. + {_key: ((.role // "") + "||" + ((.lens_key // (.proposed_checklist_delta // .observation // "")) | ascii_downcase | .[0:80]))})
    | group_by(._key)
    | map({
        role: .[0].role,
        lens_key: (.[0].lens_key // null),
        theme: (.[0].proposed_checklist_delta // .[0].observation),
        count: length,
        severity: ([.[].severity] | map(. // "suggestion") | (if any(. == "critical") then "critical" elif any(. == "warning") then "warning" else "suggestion" end)),
        examples: ([.[].observation] | map(select(. != null)) | unique | .[0:3])
      })
    | sort_by(-.count)
  ' "$1"
}

# Канон-кластеризация: lens_key резолвится через key+aliases. Нерезолвящиеся (new:* и
# незнакомые) в горячие темы НЕ попадают — они уходят в карантин (см. quarantine()).
_cluster_canon() {
  jq -s --argjson map "$2" --argjson closed "${3:-{\}}" '
    def isdate: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}");
    [ .[] | (.ts // "") as $ts | (.methodology_findings // [])[] | select(type == "object") | . + {_ts: $ts} ]
    | map(. + {_canon: ($map[(.lens_key // "")] // null)})
    | map(select(._canon != null))
    | map(select(
        ($closed[((.role // "") + "||" + ._canon)] // null) as $c
        | ($c == null) or ((._ts | isdate) and (._ts > $c))))
    | map(. + {_key: ((.role // "") + "||" + ._canon)})
    | group_by(._key)
    | map({
        role: .[0].role,
        lens_key: .[0]._canon,
        theme: (.[0].proposed_checklist_delta // .[0].observation),
        count: length,
        severity: ([.[].severity] | map(. // "suggestion") | (if any(. == "critical") then "critical" elif any(. == "warning") then "warning" else "suggestion" end)),
        examples: ([.[].observation] | map(select(. != null)) | unique | .[0:3])
      })
    | sort_by(-.count)
  ' "$1"
}

cluster() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  [ -f "$L" ] || { echo "[]"; return 0; }
  local closed; closed="$(_closed_map "$root")"
  local map; map="$(_canon_map "$(_canon_path "$root")")" || { _cluster_raw "$L" "$closed"; return 0; }
  [ -n "$map" ] || { _cluster_raw "$L" "$closed"; return 0; }
  _cluster_canon "$L" "$map" "$closed"
}

# closures — что закрыто и когда (для отчёта и отладки петли)
closures() {
  local root="${1:?skill_root}"; local f; f="$(_closed_path "$root")"
  [ -f "$f" ] || { echo "[]"; return 0; }
  jq -sc 'sort_by(.closed_at) | reverse' "$f"
}

# Карантин: находки, чей lens_key не резолвится в канон. Разделён по дате ввода канона —
# иначе 480 исторических ключей (ретро-миграции нет, решение 2026-07-27) навсегда утопили бы
# настоящих кандидатов в словарь. Свежие показываем поимённо, старые — одним числом.
quarantine() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  local canon; canon="$(_canon_path "$root")"
  [ -f "$L" ] || { echo '{"since":null,"historical":0,"fresh":[]}'; return 0; }
  local map; map="$(_canon_map "$canon")" || { echo '{"since":null,"historical":0,"fresh":[],"canon":"absent-or-broken"}'; return 0; }
  local since; since="$(jq -r '.updated // "1970-01-01"' "$canon" 2>/dev/null || echo '1970-01-01')"
  jq -s --argjson map "$map" --arg since "$since" '
    def isdate: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}");
    [ .[] | (.ts // "") as $ts | (.methodology_findings // [])[] | select(type == "object") | {ts: $ts, role: .role, lens_key: .lens_key, observation: .observation} ]
    | map(select(($map[(.lens_key // "")] // null) == null))
    | {
        since: $since,
        historical: ([ .[] | select((.ts | isdate | not) or (.ts < $since)) ] | length),
        fresh: ([ .[] | select((.ts | isdate) and (.ts >= $since)) ]
                | group_by((.role // "") + "||" + (.lens_key // ""))
                | map({role: .[0].role, lens_key: .[0].lens_key, count: length,
                       examples: ([.[].observation] | map(select(. != null)) | unique | .[0:2])})
                | sort_by(-.count))
      }
  ' "$L"
}

# health — «петля ещё жива?». Дешёвая детерминированная проверка на возврат ИСХОДНОГО
# симптома: хук живой, ledger растёт, а тем нет — ровно так дефект месяц оставался невидимым.
# Разовые метрики внедрения («было 1 → стало 8») этого не ловят: они снимаются один раз.
# Зовётся из Stop-хука на каждом приросте ledger'а, LLM не требует.
health() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  local W="${PLAN_PANEL_HEALTH_WINDOW:-30}"
  [ -f "$L" ] || { echo "ledger пуст"; return 0; }
  local recs; recs="$(tail -n "$W" "$L" | jq -s 'length')"
  local finds; finds="$(tail -n "$W" "$L" | jq -s '[.[].methodology_findings[]? | select(type=="object")] | length')"
  local hot; hot="$(cluster "$root" | jq --argjson t "${PLAN_PANEL_SOLIDIFY_THRESHOLD:-3}" '[.[]|select(.count>=$t)]|length')"
  local qfresh; qfresh="$(quarantine "$root" | jq '[.fresh[]?]|length' 2>/dev/null || echo 0)"
  local warn=""
  # (а) критик перестал выдавать находки — исходный класс «тихо»
  if [ "$recs" -ge 10 ] && [ "$finds" -eq 0 ]; then
    warn="${warn}\n  ⚑ ПЕТЛЯ МОЛЧИТ: за последние $recs прогонов НИ ОДНОЙ methodology-находки — проверь мета-критика"
  fi
  # (б) канон отстал: критик пишет ключи, которых в словаре нет → всё оседает в карантине
  if [ "$finds" -ge 10 ] && [ "$qfresh" -gt 0 ]; then
    local share; share=$(( qfresh * 100 / finds ))
    [ "$share" -ge 50 ] && warn="${warn}\n  ⚑ КАНОН ОТСТАЁТ: ${share}% свежих находок не резолвятся в словарь ($qfresh из $finds) — пора промоутить кандидатов"
  fi
  # (в) шаг внешних судей молча выпадает (2026-08-19). Тумблеры включены, а вызовов нет —
  #     ровно то, что случилось между 22.07 и 19.08: 85 прогонов панели, 0 записей судей.
  #     Прозаический контракт в SKILL.md это не ловит, поэтому детектируем данными.
  local EJ_DIR="${EJ_HOME:-$HOME/.claude/skills/_shared/external-judge}"
  local EJL="${EJ_LEDGER:-$EJ_DIR/ledger.jsonl}"
  local TOG="$EJ_DIR/toggles.env"
  if [ "$recs" -ge 10 ] && [ -f "$EJ_DIR/config.sh" ]; then
    local ej_on="${EJ_ENABLE:-}"
    # тумблеры читаем БЕЗ source (не тащим чужие функции в этот процесс) и без пайпов
    [ -n "$ej_on" ] || { [ -f "$TOG" ] && ej_on="$(awk -F= '/^EJ_ENABLE=/{v=$2} END{gsub(/["'"'"' ]/,"",v); print v}' "$TOG" 2>/dev/null)"; }
    if [ -n "${ej_on// }" ] && [ "${EJ_KILL:-0}" != "1" ] && [ ! -f "$EJ_DIR/KILL" ]; then
      local last_run last_ej
      last_run="$(tail -n "$W" "$L" | jq -rs '[.[].ts? // empty] | map(select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}"))) | max // ""' 2>/dev/null)"
      last_run="${last_run:0:10}"
      last_ej=""
      [ -f "$EJL" ] && last_ej="$(jq -rs '[.[].ts? // empty] | max // ""' "$EJL" 2>/dev/null)" && last_ej="${last_ej:0:10}"
      if [ -n "$last_run" ] && [ "${last_ej:-0000-00-00}" \< "$last_run" ]; then
        warn="${warn}\n  ⚑ ВНЕШНИЕ СУДЬИ ВЫПАЛИ: тумблеры включены ($ej_on), последний их вызов ${last_ej:-никогда} раньше последнего прогона $last_run — шаг систематически пропускают"
      fi
    fi
  fi
  echo "окно $recs прогонов: находок $finds · горячих тем $hot · свежих в карантине $qfresh"
  [ -n "$warn" ] && printf '%b\n' "$warn"
  return 0
}

stat() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  [ -f "$L" ] || { echo "ledger пуст (нет $L)"; return 0; }
  local n; n="$(wc -l < "$L" | tr -d ' ')"
  local mf; mf="$(jq -s '[.[].methodology_findings[]?] | map(select(type == "object")) | length' "$L")"
  echo "ledger: $n прогонов, $mf methodology-находок"
  # Битые находки (строка вместо объекта) — не молчим: до 2026-07-27 одна такая запись
  # роняла весь cluster(), а Stop-хук глотал ошибку и считал, что тем нет.
  local bad_mf; bad_mf="$(jq -s '[.[].methodology_findings[]?] | map(select(type != "object")) | length' "$L")"
  [ "$bad_mf" = "0" ] || echo "⚑ битых находок (не объект): $bad_mf — пропущены при кластеризации"
  echo "вердикты: $(jq -rs 'group_by(.verdict)|map("\(.[0].verdict):\(length)")|join(", ")' "$L")"
  # Телеметрия: чем меньше «сломано», тем осмысленнее вся остальная статистика.
  # Разбивка по entry_point — иначе непонятно, КАКОЙ из caller'ов течёт.
  local bad; bad="$(jq -s '[.[] | select(.telemetry_ok == false or (.run_id // "" | test("REDACTED|^unknown-run-id")))] | length' "$L")"
  if [ "$bad" != "0" ]; then
    echo "⚑ телеметрия сломана: $bad из $n (нет/затёрт run_id или telemetry_ok=false)"
    echo "  по entry_point: $(jq -rs '
      [.[] | select(.telemetry_ok == false or (.run_id // "" | test("REDACTED|^unknown-run-id")))]
      | group_by(.entry_point // "не указан")
      | map("\(.[0].entry_point // "не указан"):\(length)") | join(", ")' "$L")"
  else
    echo "телеметрия: чисто ($n/$n с валидным run_id)"
  fi
  # Ф4: ось остатка. Рост доли implementation/none = архитектурные дыры перестали
  # доживать до вердикта, то есть панель реально стала лучше. Это единственная метрика
  # качества, которую можно снять с ledger'а — verdict почти всегда NEEDS-WORK.
  local rc; rc="$(jq -rs '[.[] | .remainder_class // empty] | if length == 0 then "нет данных" else (group_by(.) | map("\(.[0]):\(length)") | join(", ")) end' "$L")"
  echo "остаток (remainder_class): $rc"
  local nc; nc="$(closures "$root" | jq 'length' 2>/dev/null || echo 0)"
  [ "${nc:-0}" = "0" ] || echo "закрытых тем: $nc (находки до закрытия не переоткрываются; новые — копятся)"
  # Канон линз: есть / нет / битый — и что лежит в карантине.
  local canon; canon="$(_canon_path "$root")"
  if [ ! -f "$canon" ]; then
    echo "канон линз: нет (кластеризация по свободному lens_key — до-Ф1 поведение)"
  elif ! _canon_map "$canon" >/dev/null 2>&1; then
    # НЕ в stderr: Stop-хук глушит stderr (2>/dev/null), предупреждение бы потерялось.
    echo "⚠ канон линз: файл есть, но НЕВАЛИДЕН ($canon) → fail-open к до-Ф1 кластеризации"
  else
    local nl; nl="$(jq '.lenses | length' "$canon")"
    local q; q="$(quarantine "$root")"
    echo "канон линз: $nl тем · карантин — свежих $(printf '%s' "$q" | jq '.fresh | length'), исторических $(printf '%s' "$q" | jq '.historical') (до $(printf '%s' "$q" | jq -r '.since'))"
  fi
}

self_test() {
  set +e  # self-test использует паттерн «[ cond ]; ok $?» — несовместим с set -e
  local T; T="$(mktemp -d)"
  local fail=0
  ok() { if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # 1. append валидных записей (один lens_key → должны слиться при кластеризации)
  append "$T" '{"ts":"t1","skill":"x","run_id":"r1","verdict":"NEEDS-WORK","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"нет проверки success-signal","proposed_checklist_delta":"success меряет результат, не прокси"}]}' >/dev/null
  ok $? "append #1"
  append "$T" '{"ts":"t2","skill":"x","run_id":"r2","verdict":"SHIP","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"опять прокси-success","proposed_checklist_delta":"Success меряет РЕЗУЛЬТАТ, не прокси!"}]}' >/dev/null
  ok $? "append #2"
  [ "$(wc -l < "$T/feedback/learnings.jsonl" | tr -d ' ')" = "2" ]; ok $? "2 строки в ledger"
  # 2. невалидный JSON отклоняется
  append "$T" 'not-json' >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "невалидный JSON отклонён"
  # 3. cluster сливает один lens_key в один кластер с count=2 (язык/регистр не важны)
  local c; c="$(cluster "$T")"
  [ "$(printf '%s' "$c" | jq 'length')" = "1" ]; ok $? "cluster: один lens_key → 1 кластер"
  [ "$(printf '%s' "$c" | jq '.[0].count')" = "2" ]; ok $? "cluster: count=2"
  [ "$(printf '%s' "$c" | jq -r '.[0].lens_key')" = "success-signal-integrity" ]; ok $? "cluster: lens_key сохранён"
  # 4. ROUND-TRIP телеметрии: машинный run_id обязан лечь на диск БЕЗ редакции.
  #    Регресс-гард на дефект 2026-07-27 (uuid/<ts>-<slug> затирались как high-entropy).
  local UUID="7c1e0a94-3b52-4d6f-9a08-2fe1b7d4c6a3"
  local TSSLUG="2026-07-27_17-28-41-panel-v2-foundation"
  append "$T" "{\"ts\":\"$TSSLUG\",\"skill\":\"x\",\"run_id\":\"$UUID\",\"entry_point\":\"slash-command\",\"verdict\":\"PASS\"}" >/dev/null
  ok $? "append записи с машинным run_id"
  local got; got="$(tail -1 "$T/feedback/learnings.jsonl" | jq -r '.run_id')"
  [ "$got" = "$UUID" ]; ok $? "round-trip: run_id на диске == на входе (получено: $got)"
  [ "$(tail -1 "$T/feedback/learnings.jsonl" | jq -r '.ts')" = "$TSSLUG" ]; ok $? "round-trip: ts не затёрт"
  # 5. Пофайловый strip НЕ стал дырой: секрет в свободном тексте обязан быть затёрт.
  append "$T" '{"ts":"t5","skill":"x","run_id":"r5","subject":"утечка sk-''ABCD1234efgh5678ijkl9012mnop тут","methodology_findings":[{"role":"qa","lens_key":"k","observation":"ключ ghp_''ABCDEFGHIJ1234567890abcdefXYZ в логе"}]}' >/dev/null
  ok $? "append записи с секретом в тексте"
  local last; last="$(tail -1 "$T/feedback/learnings.jsonl")"
  ! printf '%s' "$last" | grep -q 'sk-ABCD'; ok $? "strip: openai-ключ в subject затёрт"
  ! printf '%s' "$last" | grep -q 'ghp_ABCDEF'; ok $? "strip: github-токен в observation затёрт"
  # 6. Секрет, подложенный В СЛУЖЕБНОЕ поле, тоже обязан быть затёрт (--no-entropy ≠ выключено).
  append "$T" '{"ts":"t6","skill":"x","run_id":"sk-''ABCD1234efgh5678ijkl9012mnop"}' >/dev/null
  ! tail -1 "$T/feedback/learnings.jsonl" | grep -q 'sk-ABCD'; ok $? "strip: секрет в run_id затёрт паттерном"

  # ── Ф1: канон линз ──────────────────────────────────────────────────────────
  # 7. КОНТРАКТ CROSS-SKILL: без canon.json кластеризация обязана быть БАЙТ-В-БАЙТ до-Ф1.
  #    Это гард на тихий регресс redloft/redresearch/redsemantic — их нудж не должен замолчать.
  local C2; C2="$(mktemp -d)"
  cp "$T/feedback/learnings.jsonl" "$C2/tmp.jsonl" 2>/dev/null
  mkdir -p "$C2/feedback"; cp "$C2/tmp.jsonl" "$C2/feedback/learnings.jsonl"
  local before; before="$(cluster "$C2")"
  [ "$(printf '%s' "$before" | jq 'length')" -ge 1 ]; ok $? "нет канона → кластеры как раньше (не пусто)"
  # 8. Канон резолвит алиас в канонический key и СЛИВАЕТ разные алиасы в одну тему.
  mkdir -p "$C2/lenses"
  cat > "$C2/lenses/canon.json" <<'CANON'
{"version":1,"updated":"2026-07-01","lenses":[
 {"key":"dod-without-threshold","role":"qa","title":"DoD без порога","aliases":["per-phase-done-when","success-signal-integrity"]}]}
CANON
  : > "$C2/feedback/learnings.jsonl"
  append "$C2" '{"ts":"2026-07-10","skill":"x","run_id":"a1","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"per-phase-done-when","observation":"o1","proposed_checklist_delta":"d1"}]}' >/dev/null
  append "$C2" '{"ts":"2026-07-11","skill":"x","run_id":"a2","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"o2","proposed_checklist_delta":"d2"}]}' >/dev/null
  local cc; cc="$(cluster "$C2")"
  [ "$(printf '%s' "$cc" | jq 'length')" = "1" ]; ok $? "канон: два разных алиаса → 1 кластер"
  [ "$(printf '%s' "$cc" | jq -r '.[0].lens_key')" = "dod-without-threshold" ]; ok $? "канон: lens_key нормализован"
  [ "$(printf '%s' "$cc" | jq '.[0].count')" = "2" ]; ok $? "канон: count=2 (раньше было бы 1+1)"
  # 9. new:* и незнакомый ключ — в карантин, НЕ в горячие темы.
  append "$C2" '{"ts":"2026-07-12","skill":"x","run_id":"a3","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"new:какая-то-новая-линза","observation":"o3","proposed_checklist_delta":"d3"}]}' >/dev/null
  [ "$(cluster "$C2" | jq 'length')" = "1" ]; ok $? "карантин: new:* не попал в кластеры"
  local q; q="$(quarantine "$C2")"
  [ "$(printf '%s' "$q" | jq '.fresh | length')" = "1" ]; ok $? "карантин: new:* виден как свежий кандидат"
  # 10. Отсечка по дате: запись СТАРШЕ канона идёт в historical, не в fresh.
  append "$C2" '{"ts":"2026-06-01","skill":"x","run_id":"a4","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"древний-ключ","observation":"o4","proposed_checklist_delta":"d4"}]}' >/dev/null
  q="$(quarantine "$C2")"
  [ "$(printf '%s' "$q" | jq '.historical')" -ge 1 ]; ok $? "карантин: запись до канона → historical"
  [ "$(printf '%s' "$q" | jq '.fresh | length')" = "1" ]; ok $? "карантин: старое НЕ утопило свежих кандидатов"
  # 10б. РЕГРЕСС-ГАРД: находка-строка вместо объекта не должна ронять cluster целиком.
  #      Реальный случай — finalize/learnings.jsonl:28 (3 строки): cluster падал, Stop-хук
  #      глотал ошибку через `2>/dev/null || hot="[]"` и молчал про finalize неопределённо долго.
  append "$C2" '{"ts":"2026-07-13","skill":"x","run_id":"a5","methodology_findings":["просто строка, не объект",{"role":"qa","severity":"warning","lens_key":"per-phase-done-when","observation":"o5","proposed_checklist_delta":"d5"}]}' >/dev/null
  ok $? "append записи со смешанным methodology_findings"
  cluster "$C2" >/dev/null 2>&1; ok $? "cluster не падает на находке-строке"
  [ "$(cluster "$C2" | jq -r '.[] | select(.lens_key=="dod-without-threshold") | .count')" = "3" ]; ok $? "объект рядом со строкой всё равно учтён (count=3)"
  quarantine "$C2" >/dev/null 2>&1; ok $? "quarantine не падает на находке-строке"
  # ── ЗАКРЫТИЕ ТЕМ (гард на «петля наматывает один круг вечно») ──────────────
  local C3; C3="$(mktemp -d)"; mkdir -p "$C3/feedback" "$C3/lenses"
  cp "$C2/lenses/canon.json" "$C3/lenses/canon.json" 2>/dev/null
  append "$C3" '{"ts":"2026-07-10","skill":"x","run_id":"c1","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"per-phase-done-when","observation":"o1","proposed_checklist_delta":"d1"}]}' >/dev/null
  append "$C3" '{"ts":"2026-07-11","skill":"x","run_id":"c2","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"o2","proposed_checklist_delta":"d2"}]}' >/dev/null
  [ "$(cluster "$C3" | jq '.[0].count')" = "2" ]; ok $? "закрытие: до закрытия тема видна (count=2)"
  # 12. Закрытие гасит СТАРЫЕ находки этой темы.
  printf '%s\n' '{"role":"qa","lens_key":"dod-without-threshold","closed_at":"2026-07-12_00-00-00","why":"тест"}' > "$C3/feedback/closed.jsonl"
  [ "$(cluster "$C3" | jq 'length')" = "0" ]; ok $? "закрытие: старые находки темы погашены"
  # 13. ГЛАВНОЕ: находки ПОСЛЕ закрытия копятся заново — иначе не увидим, что клауза не сработала.
  append "$C3" '{"ts":"2026-07-20","skill":"x","run_id":"c3","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"per-phase-done-when","observation":"o3","proposed_checklist_delta":"d3"}]}' >/dev/null
  [ "$(cluster "$C3" | jq '.[0].count // 0')" = "1" ]; ok $? "закрытие: НОВАЯ находка после закрытия снова считается"
  # 14. Закрытие адресное: чужая (role, lens_key) не задета.
  # тот же lens_key, но ДРУГАЯ роль — закрытие для qa не должно её гасить
  append "$C3" '{"ts":"2026-07-09","skill":"x","run_id":"c4","methodology_findings":[{"role":"ops","severity":"warning","lens_key":"per-phase-done-when","observation":"o4","proposed_checklist_delta":"d4"}]}' >/dev/null
  [ "$(cluster "$C3" | jq '[.[]|select(.role=="ops")]|length')" = "1" ]; ok $? "закрытие адресное: та же тема у другой роли не погашена"
  rm -rf "$C3"

  # 15. Ф6: починка телеметрии на записи. Прогон НИКОГДА не теряется, но и не врёт.
  local F6="$T/f6"; mkdir -p "$F6/feedback"
  append "$F6" '{"ts":"now","skill":"x","run_id":"unknown-run-id","verdict":"NEEDS-WORK"}' >/dev/null
  local f6l; f6l="$(tail -1 "$F6/feedback/learnings.jsonl")"
  [ "$(printf '%s' "$f6l" | jq -r '.ts')" != "now" ]; ok $? "Ф6: ts='now' заменён реальной датой записи"
  [ "$(printf '%s' "$f6l" | jq -r '.run_id')" != "unknown-run-id" ]; ok $? "Ф6: дефолтный run_id перечеканен (записи различимы)"
  [ "$(printf '%s' "$f6l" | jq -r '.entry_point')" = "untagged" ]; ok $? "Ф6: отсутствующий entry_point → untagged"
  [ "$(printf '%s' "$f6l" | jq -r '.telemetry_ok')" = "false" ]; ok $? "Ф6: починка НЕ выдаётся за здоровье (telemetry_ok=false)"
  ! printf '%s' "$f6l" | jq -r '.run_id' | grep -q 'REDACTED'; ok $? "Ф6: чеканеный run_id пережил strip (служебное поле, --no-entropy)"
  printf '%s' "$f6l" | jq -e '.telemetry_repaired | index("run_id")' >/dev/null; ok $? "Ф6: в записи видно, ЧТО именно чинили"
  # ts-мусор (число/произвольная строка) — тот же класс: лексикографическое сравнение с датами
  append "$F6" '{"ts":12345,"skill":"x","run_id":"zz-1","entry_point":"skill-freeform"}' >/dev/null
  printf '%s' "$(tail -1 "$F6/feedback/learnings.jsonl")" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")' >/dev/null
  ok $? "Ф6: ts не-датой (число/мусор) заменён реальной датой — иначе запись тонет в «исторических»"
  # ГЛАВНЫЙ боевой кейс (нашла панель 2026-08-19): panel.js:167 / artifact-panel.js:42 дефолтят
  # entry_point ЛИТЕРАЛОМ unknown. Проверка «поле пустое» на этом не срабатывала бы НИКОГДА.
  append "$F6" '{"ts":"2026-08-19_10-00","skill":"x","run_id":"zz-2","entry_point":"unknown"}' >/dev/null
  local f6u; f6u="$(tail -1 "$F6/feedback/learnings.jsonl")"
  [ "$(printf '%s' "$f6u" | jq -r '.entry_point')" = "untagged" ]; ok $? "Ф6: entry_point-плейсхолдер unknown распознан (не только пустая строка)"
  [ "$(printf '%s' "$f6u" | jq -r '.telemetry_ok')" = "false" ]; ok $? "Ф6: плейсхолдер unknown помечает прогон как сломанную телеметрию"
  # Флаг caller-а обязан ПЕРЕБИВАТЬ плейсхолдер (а не только заполнять пустоту).
  append "$F6" '{"ts":"2026-08-19_10-00","skill":"x","run_id":"zz-3","entry_point":"unknown"}' --entry-point slash-command >/dev/null
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.entry_point')" = "slash-command" ]; ok $? "Ф6: --entry-point перебивает плейсхолдер unknown"
  # Флаг АВТОРИТЕТЕН (как безусловная jq-обёртка до Ф6): panel.js не получает entry_point
  # от SKILL и всегда пишет литерал unknown — вызывающая сторона знает точнее, чем JSON.
  append "$F6" '{"ts":"2026-08-19_10-00","skill":"x","run_id":"zz-4","entry_point":"from-task"}' --entry-point slash-command >/dev/null
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.entry_point')" = "slash-command" ]; ok $? "Ф6: флаг авторитетнее непустого entry_point из JSON"
  # Только ts плох, run_id/entry_point валидны — промежуточная комбинация (нашли внешние судьи)
  append "$F6" '{"ts":"now","skill":"x","run_id":"zz-5","entry_point":"finalize"}' >/dev/null
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.telemetry_ok')" = "false" ]; ok $? "Ф6: починка ОДНОГО лишь ts тоже гасит telemetry_ok (не врём)"
  # Фолбэк чеканки без uuidgen: mint обязан остаться уникальным, а не выродиться в "late-"
  ( PATH=/usr/bin:/bin; append "$F6" '{"ts":"now","skill":"x","run_id":"unknown","entry_point":"finalize"}' >/dev/null 2>&1 )
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.run_id')" != "late-" ]; ok $? "Ф6: чеканка не вырождается в пустой префикс"
  # run_id-плейсхолдер точным литералом (не только префиксом unknown-run-id)
  append "$F6" '{"ts":"2026-08-19_10-00","skill":"x","run_id":"unknown","entry_point":"finalize"}' >/dev/null
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.run_id')" != "unknown" ]; ok $? "Ф6: run_id-плейсхолдер unknown перечеканен"
  # telemetry_repaired обязано пережить strip (служебное поле, --no-entropy overlay)
  printf '%s' "$f6u" | jq -e '.telemetry_repaired | type == "array"' >/dev/null; ok $? "Ф6: telemetry_repaired не съеден strip-ом (в LEDGER_SERVICE_KEYS)"
  append "$F6" '{"ts":"now","skill":"x","run_id":"unknown-run-id","verdict":"FAIL"}' --entry-point from-task >/dev/null
  [ "$(tail -1 "$F6/feedback/learnings.jsonl" | jq -r '.entry_point')" = "from-task" ]; ok $? "Ф6: --entry-point проставляется caller'ом"
  local GOODID; GOODID="$(uuidgen | tr 'A-Z' 'a-z')"
  append "$F6" "{\"ts\":\"2026-08-19_12-00\",\"skill\":\"x\",\"run_id\":\"$GOODID\",\"entry_point\":\"slash-command\",\"verdict\":\"SHIP\"}" >/dev/null
  local f6g; f6g="$(tail -1 "$F6/feedback/learnings.jsonl")"
  [ "$(printf '%s' "$f6g" | jq -r '.ts')" = "2026-08-19_12-00" ] \
    && [ "$(printf '%s' "$f6g" | jq -r '.run_id')" = "$GOODID" ] \
    && [ "$(printf '%s' "$f6g" | jq -r '.telemetry_repaired // "нет"')" = "нет" ]
  ok $? "Ф6: здоровая запись проходит нетронутой (без ложной починки)"
  rm -rf "$F6"

  # 16. Детектор «внешние судьи выпали» (2026-08-19). Ловит инцидент 22.07→19.08:
  #     тумблеры включены, 85 прогонов панели, ноль вызовов судей — прозаический контракт
  #     в SKILL.md этого не видел, поэтому проверка живёт в данных.
  local EJT="$T/ejt"; mkdir -p "$EJT/feedback" "$EJT/ej"
  local i
  for i in $(seq 1 12); do
    printf '{"ts":"2026-08-1%s_10-00","skill":"x","run_id":"r%s","entry_point":"finalize"}\n' "$((i%10))" "$i"
  done > "$EJT/feedback/learnings.jsonl"
  : > "$EJT/ej/config.sh"
  printf 'EJ_ENABLE="openai,glm"\n' > "$EJT/ej/toggles.env"
  printf '{"ts":"2026-07-22T12:00:00Z","provider":"openai"}\n' > "$EJT/ej/ledger.jsonl"
  EJ_HOME="$EJT/ej" EJ_LEDGER="$EJT/ej/ledger.jsonl" EJ_ENABLE="" health "$EJT" | grep -q 'СУДЬИ ВЫПАЛИ'
  ok $? "судьи: отставание вызовов от прогонов → тревога"
  printf '{"ts":"2026-08-19T12:00:00Z","provider":"openai"}\n' > "$EJT/ej/ledger.jsonl"
  ! EJ_HOME="$EJT/ej" EJ_LEDGER="$EJT/ej/ledger.jsonl" EJ_ENABLE="" health "$EJT" | grep -q 'СУДЬИ ВЫПАЛИ'
  ok $? "судьи: свежий вызов → тревоги нет (без ложных)"
  printf 'EJ_ENABLE=""\n' > "$EJT/ej/toggles.env"
  printf '{"ts":"2026-07-22T12:00:00Z","provider":"openai"}\n' > "$EJT/ej/ledger.jsonl"
  ! EJ_HOME="$EJT/ej" EJ_LEDGER="$EJT/ej/ledger.jsonl" EJ_ENABLE="" health "$EJT" | grep -q 'СУДЬИ ВЫПАЛИ'
  ok $? "судьи: тумблеры выключены → детектор молчит"
  rm -rf "$EJT"

  # 11. Третье состояние: канон есть, но битый → fail-open к до-Ф1, а не пустота.
  echo '{ это не json' > "$C2/lenses/canon.json"
  [ "$(cluster "$C2" | jq 'length')" -ge 2 ]; ok $? "битый канон → fail-open (кластеры по свободным ключам)"
  rm -rf "$C2"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ ledger self-test passed (append/reject/cluster/round-trip/field-strip/canon/quarantine/closure/telemetry-repair)"; return 0; else echo "✗ ledger self-test FAILED"; return 1; fi
}

case "${1:-}" in
  append)     shift; append "${1:-}" "${2:-}" "${@:3}" ;;
  cluster)    cluster "${2:-}" ;;
  quarantine) quarantine "${2:-}" ;;
  health)     health "${2:-}" ;;
  closures)   closures "${2:-}" ;;
  stat)       stat "${2:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: ledger.sh append|cluster|quarantine|closures|health|stat <skill_root> | --self-test" >&2; exit 1 ;;
esac
