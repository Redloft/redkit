#!/usr/bin/env bash
# watch.sh — внешний сторож прогонов redloop (Ф2). Запускается ВНЕ сессии (launchd/redjob).
#
# Инвариант из EVENTS-CONTRACT: сторож ТОЛЬКО ЧИТАЕТ events.jsonl. Свои находки он пишет
# в собственный файл runs/<id>/alerts.jsonl — иначе появился бы второй писатель журнала.
# Смысл: три прогона подряд закончились тишиной (работа шла или встала, журнал молчал,
# человек узнавал об этом от меня, а не от системы).
#
# Usage: watch.sh [--dry-run] | watch.sh --self-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REG="${REDLOOP_INDEX:-$ROOT/runs/index.jsonl}"
DRY="${REDLOOP_WATCH_DRYRUN:-0}"; [ "${1:-}" = "--dry-run" ] && DRY=1

# ⚠ Тишина в журнале ≠ смерть прогона. Первое же боевое применение дало ложную тревогу:
# прогон витрина-лаб «молчал» 192 минуты, а на деле работал — коммитил и правил файлы,
# просто не вёл журнал. Журнальная тишина здесь — ПРОКСИ, и мерить ею живость нельзя.
# Поэтому SILENCE подтверждается внешним признаком жизни: свежие изменения в рабочем дереве
# проекта или новый коммит. Есть признаки жизни → это «журнал не ведётся», а не «прогон умер»,
# и будить человека ночью незачем.
_alive_since() {   # печатает минуты с последней РЕАЛЬНОЙ активности проекта, либо пусто
  local rd="$1" proj newest now cur i
  # глубина вложенности разная: <проект>/.redloop/runs/<id> и <скилл>/runs/<id>.
  # Ищем корень проекта вверх по дереву — по .git или по каталогу, содержащему .redloop.
  cur="$(cd "$rd" 2>/dev/null && pwd)" || return 0
  proj=""
  # ⚠ Только каталог, который РЕАЛЬНО принадлежит прогону: `.redloop` — его якорь.
  # Подъём до первого попавшегося `.git` в монорепо уводил на корень всего репозитория,
  # и правка в соседнем скилле читалась как признак жизни ЭТОГО прогона.
  for i in 1 2 3; do
    cur="$(dirname "$cur")"; [ "$cur" = "/" ] && break
    if [ -d "$cur/.redloop" ]; then proj="$cur"; break; fi
  done
  [ -n "$proj" ] || return 0   # не проект (например прогон в папке скилла) → корроборации нет
  [ -d "$proj" ] || return 0
  # сперва git: коммит — однозначный след работы, в отличие от mtime любого файла
  if [ -d "$proj/.git" ]; then
    newest="$(git -C "$proj" log -1 --format=%ct 2>/dev/null || true)"
  fi
  # затем mtime рабочего дерева, но ограниченно по глубине и без служебных каталогов
  if [ -z "${newest:-}" ]; then
    newest="$(find "$proj" -maxdepth 4 -type f \
              -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.redloop/*' \
              -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/.next/*' \
              -not -path '*/target/*' -not -path '*/vendor/*' -not -path '*/.venv/*' \
              -not -path '*/__pycache__/*' -not -path '*/coverage/*' \
              -newermt '-24 hours' -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)"
  fi
  [ -n "$newest" ] || return 0
  now="$(date -u +%s)"; echo $(( (now - newest) / 60 ))
}

_alert_delivered() {  # «уже сообщали» = ДОСТАВЛЕНО человеку, а не «мы что-то записали».
  # Прежняя версия считала виденной любую запись, включая подавленную и недоставленную:
  # первая же suppressed-строка или один сбой TG навсегда гасили тревогу по этому прогону.
  local rd="$1" det="$2"
  [ -f "$rd/alerts.jsonl" ] || return 1
  jq -e --arg d "$det" -s 'any(.[]; .detector==$d and .delivered==true)' "$rd/alerts.jsonl" >/dev/null 2>&1
}

# ⚠ ОДНА строка на (прогон × детектор), а не строка на обход. Первая версия писала находку
# каждые 15 минут: за сутки 100 одинаковых записей на прогон и рост без предела. Повтор той же
# находки — не новая улика, это тот же факт; поэтому копим СЧЁТЧИК, а не строки.
_alert_upsert() {
  local rd="$1" det="$2" sev="$3" ev="$4" sh="$5" dl="$6" sup="$7"
  local f="$rd/alerts.jsonl"; local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp)"
  if [ -f "$f" ]; then
    jq -s -c --arg d "$det" --arg sev "$sev" --arg ev "$ev" --arg now "$now" \
       --argjson sh "$sh" --argjson dl "$dl" --argjson sup "$sup" '
      (map(select(.detector==$d)) | length) as $has
      | if $has > 0 then
          map(if .detector==$d then
                . + {last_ts:$now, evidence:$ev, severity:$sev, shadow:$sh,
                     seen_count: ((.seen_count // 1) + 1),
                     suppressed_count: ((.suppressed_count // 0) + $sup),
                     delivered: (.delivered or $dl)}
                + (if $dl and (.delivered_ts|not) then {delivered_ts:$now} else {} end)
              else . end)
        else
          . + [{ts:$now, last_ts:$now, detector:$d, severity:$sev, evidence:$ev, source:"watch",
                 shadow:$sh, delivered:$dl, seen_count:1, suppressed_count:$sup}
               + (if $dl then {delivered_ts:$now} else {} end)]
        end
      | .[]' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    jq -nc --arg d "$det" --arg sev "$sev" --arg ev "$ev" --arg now "$now" \
       --argjson sh "$sh" --argjson dl "$dl" --argjson sup "$sup" \
      '{ts:$now, last_ts:$now, detector:$d, severity:$sev, evidence:$ev, source:"watch",
        shadow:$sh, delivered:$dl, seen_count:1, suppressed_count:$sup}' > "$tmp"
  fi
  mv "$tmp" "$f"
}

watch_once() {
  # ⚠ перечитываем на КАЖДЫЙ обход: значение, снятое при загрузке скрипта, не видит
  # переменных, выставленных позже (в тесте это уводило сторожа в боевой реестр).
  REG="${REDLOOP_INDEX:-$ROOT/runs/index.jsonl}"
  DRY="${REDLOOP_WATCH_DRYRUN:-$DRY}"
  [ -f "$REG" ] || { echo "reg=нет прогонов ($REG)"; return 0; }
  local checked=0 alerted=0 gone=0 suppressed=0 shadowed=0 undelivered=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ ! -f "$d/events.jsonl" ]; then gone=$((gone+1)); continue; fi
    checked=$((checked+1))
    local sigs; sigs="$(bash "$HERE/detect.sh" scan "$d" 2>/dev/null || echo '[]')"
    local det sev ev sh
    while IFS=$'\t' read -r det sev ev sh; do
      [ -n "$det" ] || continue
      _alert_delivered "$d" "$det" && continue
      # корроборация тишины: без неё сторож будит человека на живой работе
      if [ "$det" = "SILENCE" ]; then
        local idle; idle="$(_alive_since "$d")"
        if [ -n "$idle" ] && [ "$idle" -lt "${REDLOOP_SILENCE_MIN:-45}" ]; then
          _alert_upsert "$d" SILENCE info "$ev (подавлено: проект жив, простой ${idle} мин)" true false 1
          suppressed=$((suppressed+1)); continue
        fi
      fi
      local delivered=false
      if [ "$sh" = "true" ]; then
        # тихий режим: находку ФИКСИРУЕМ (материал для калибровки), человека не будим
        shadowed=$((shadowed+1))
      elif [ "$DRY" = "1" ]; then
        # сухой прогон: считаем доставленной (иначе счётчик доставок всегда ноль и строка врёт)
        delivered=true; alerted=$((alerted+1))
      else
        # имя детектора идёт в reason_code эскалации 1:1 (списки сверяются тестом)
        if REDLOOP_ESCALATE_NO_EVENT=1 bash "$HERE/escalate.sh" "$d" "$det" "review" "$ev" "прогон $(basename "$d")" >/dev/null 2>&1; then
          delivered=true; alerted=$((alerted+1))
        else
          undelivered=$((undelivered+1))
          echo "⚠ не доставлено ($det, прогон $(basename "$d")) — повторю на следующем обходе" >&2
        fi
      fi
      _alert_upsert "$d" "$det" "$sev" "$ev" "$sh" "$delivered" 0
    done < <(printf '%s' "$sigs" | jq -r '.[] | [.detector,.severity,.evidence,(.shadow|tostring)] | @tsv')
  done < <(jq -r '.path' "$REG" 2>/dev/null | sort -u)
  # знаменатель обязателен, и подавленные тревоги считаются отдельно: «0 тревог» без
  # «сколько подавлено» скрывало бы, что сторож на самом деле срабатывает вхолостую
  # каждое число со своим смыслом: молчание сторожа обязано быть отличимо от «нечего сообщать»
  echo "watch: проверено прогонов $checked, доставлено $alerted, НЕ доставлено $undelivered, тихий режим $shadowed, подавлено (проект жив) $suppressed, недоступных каталогов $gone"
  [ "$undelivered" -gt 0 ] && return 3
  return 0
}

self_test() {
  local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  export REDLOOP_INDEX="$T/index.jsonl" REDLOOP_WATCH_DRYRUN=1
  # фикстуры здесь — намеренно больные прогоны (тишина, пустые итерации). Требование
  # внешнего состояния проверяется в events.sh; тут оно только помешало бы собрать журнал.
  export REDLOOP_STATE_FILES_ENFORCE=0
  export REDLOOP_STATS_DIR="$T/stats"; mkdir -p "$REDLOOP_STATS_DIR"
  local rd="$T/runs/silent"; mkdir -p "$rd"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd/contract.json"
  bash "$HERE/events.sh" append "$rd" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  bash "$HERE/events.sh" append "$rd" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9 >/dev/null 2>&1
  python3 - "$rd/events.jsonl" <<'PYY'
import json,sys,datetime
p=sys.argv[1]; rows=[json.loads(l) for l in open(p) if l.strip()]
t=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)-datetime.timedelta(hours=3)
rows[-1]["ts"]=t.strftime("%Y-%m-%dT%H:%M:%SZ")
open(p,"w").write("".join(json.dumps(r,ensure_ascii=False)+"\n" for r in rows))
PYY
  # SILENCE выведен из тихого режима намеренно: три пропуска подряд, порог щедрый (45 мин)
  echo '{"SILENCE":{"shadow":false}}' > "$REDLOOP_STATS_DIR/detectors.json"
  local out; out="$(watch_once)"
  echo "$out" | grep -q "проверено прогонов 1"; ok $? "сторож обошёл парк по реестру"
  [ -f "$rd/alerts.jsonl" ]; ok $? "тревога записана в СВОЙ файл (журнал не тронут)"
  grep -q '"detector":"SILENCE"' "$rd/alerts.jsonl"; ok $? "молчащий прогон пойман"
  [ "$(jq -s 'length' "$rd/events.jsonl")" = "2" ]; ok $? "сторож НЕ дописал в events.jsonl (только чтение)"
  out="$(watch_once)"; echo "$out" | grep -q "доставлено 0"; ok $? "повторный обход не дублирует доставленную тревогу"
  # живой проект: журнал молчит, но файлы свежие → тревогу подавляем и считаем
  local rl="$T/proj/.redloop/runs/live"; mkdir -p "$rl"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rl/contract.json"
  bash "$HERE/events.sh" append "$rl" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  bash "$HERE/events.sh" append "$rl" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9 >/dev/null 2>&1
  python3 - "$rl/events.jsonl" <<'PYY'
import json,sys,datetime
p=sys.argv[1]; rows=[json.loads(l) for l in open(p) if l.strip()]
t=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)-datetime.timedelta(hours=3)
rows[-1]["ts"]=t.strftime("%Y-%m-%dT%H:%M:%SZ")
open(p,"w").write("".join(json.dumps(r,ensure_ascii=False)+"\n" for r in rows))
PYY
  printf 'свежая работа\n' > "$T/proj/файл.txt"
  out="$(watch_once)"
  echo "$out" | grep -q "подавлено (проект жив) 1"; ok $? "живой проект: SILENCE подавлен, а не выдан за смерть"
  jq -e -s 'any(.[]; .detector=="SILENCE" and (.suppressed_count // 0) > 0 and .delivered==false)' "$rl/alerts.jsonl" >/dev/null
  ok $? "подавление записано счётчиком и не выдано за доставку"
  # ── круг 7: честно сдавшийся прогон обязан ДОЙТИ до владельца ────────────
  # Регрессия круга 6: лечили ложную тревогу на честной сдаче — и вылечили доставку.
  # SILENCE гасится наличием run_done, FRESH-CHECK-MISSING снят по outcome, авто-нотификация
  # выключена. Если RUN-ABANDONED тоже тихий, упавший прогон не доходит НИКАК.
  # Тест пересекает порог: смотрим не «находка есть», а «тревога ДОСТАВЛЕНА».
  local rab="$T/runs/abandoned"; mkdir -p "$rab"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rab/contract.json"
  bash "$HERE/events.sh" append "$rab" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  bash "$HERE/events.sh" append "$rab" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9 >/dev/null 2>&1
  bash "$HERE/events.sh" append "$rab" run_done '{"verdict":"нет токена","iters":1,"interventions":0,"outcome":"blocked"}' >/dev/null 2>&1
  rm -f "$REDLOOP_STATS_DIR/detectors.json"   # тихость берётся из constants.json, не из stats
  out="$(watch_once)"
  echo "$out" | grep -q "доставлено 1"; ok $? "круг7: честный неуспех ДОСТАВЛЕН владельцу (не только записан)"
  jq -e -s 'any(.[]; .detector=="RUN-ABANDONED" and .shadow==false and .delivered==true)' "$rab/alerts.jsonl" >/dev/null
  ok $? "круг7: RUN-ABANDONED не тихий и помечен доставленным"

  # тихий детектор ФИКСИРУЕТСЯ (иначе не накопит эмпирику и не выйдет из shadow по числам)
  local rs="$T/runs/shadowed"; mkdir -p "$rs"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rs/contract.json"
  echo '{}' > "$REDLOOP_STATS_DIR/detectors.json"     # всё в тихом режиме
  bash "$HERE/events.sh" append "$rs" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  local z; for z in 1 2 3; do bash "$HERE/events.sh" append "$rs" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $z --of 9 >/dev/null 2>&1; done
  out="$(watch_once)"
  echo "$out" | grep -q "тихий режим 1"; ok $? "тихая находка записана и посчитана"
  grep -q '"shadow":true' "$rs/alerts.jsonl"; ok $? "в alerts видно, что находка тихая"
  grep -q '"delivered":false' "$rs/alerts.jsonl"; ok $? "тихая находка помечена недоставленной"
  out="$(watch_once)"; echo "$out" | grep -q "тихий режим 1"; ok $? "тихая находка повторяется, а не гасится дедупом"
  [ "$(jq -s 'length' "$rs/alerts.jsonl")" = "1" ]; ok $? "повтор НЕ плодит строк — одна на детектор"
  [ "$(jq -s -r '.[0].seen_count' "$rs/alerts.jsonl")" = "2" ]; ok $? "повтор считается счётчиком (seen_count=2)"
  jq -e -s '.[0]|has("last_ts")' "$rs/alerts.jsonl" >/dev/null; ok $? "у находки есть время последнего повтора"
  # калибровка обязана ВИДЕТЬ эти находки: они и есть материал для выхода из тихого режима
  [ "$(REDLOOP_INDEX="$REDLOOP_INDEX" bash "$HERE/detect.sh" calibration | jq -r .fires)" != "0" ]
  ok $? "калибровка читает находки из alerts.jsonl (а не пустой detector_fire)"
  echo '{"SILENCE":{"shadow":false}}' > "$REDLOOP_STATS_DIR/detectors.json"

  # подавленная тревога НЕ считается «уже сообщали»: проект затих → тревога обязана уйти
  local rp="$T/proj/.redloop/runs/live"
  printf 'старая работа\n' > "$T/proj/файл.txt"
  python3 - "$T/proj/файл.txt" <<'PYY'
import os,sys,time
p=sys.argv[1]; old=time.time()-6*3600; os.utime(p,(old,old))
PYY
  out="$(watch_once)"
  echo "$out" | grep -q "доставлено 1"; ok $? "затихший проект: подавление снято, тревога ушла"

  # исчезнувший каталог виден числом, а не молчанием
  jq -nc '{ts:"2026-01-01T00:00:00Z",run_id:"gone",path:"/nope/gone",runner:"s",task:""}' >> "$REDLOOP_INDEX"
  out="$(watch_once)"; echo "$out" | grep -q "недоступных каталогов 1"; ok $? "пропавший прогон посчитан"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ watch self-test passed"; return 0; } || { echo "✗ watch self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; *) watch_once ;; esac
