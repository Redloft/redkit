#!/usr/bin/env bash
# redjob-watch.sh — сторож парка джоб: гоняет doctor и зовёт человека на CRITICAL.
#
# ЗАЧЕМ. Детектор без алерта бесполезен: правило `log-stall` нашло сломанную неделей ранее
# джобу только потому, что doctor запустили руками. Класс отказа, который он ловит, тем и
# опасен, что тихий и с бесконечным ретраем — смотреть в него никто не будет по своей воле.
#
# АНТИ-СПАМ. Шлём НЕ каждый прогон, иначе ежедневное «всё те же три критика» превращается в
# шум, который перестают читать (тогда сторож бесполезен ровно как его отсутствие). Правила:
#   · набор критиков ИЗМЕНИЛСЯ (появился новый / исчез старый) → шлём сразу;
#   · набор тот же, но прошло ≥REMIND_DAYS дней → напоминание «всё ещё сломано»;
#   · критиков нет → молчим, только пишем в лог.
#
# КАНАЛ. Уведомитель подключается снаружи через REDJOB_NOTIFY_CMD — команда, читающая текст
# сообщения со STDIN и печатающая `SENT` при успехе (например, скрипт отправки в мессенджер).
# Канал ДОЛЖЕН быть независим от того, за чем следим. Остаточный риск честно: сам сторож —
# тоже launchd-джоба; если умрёт launchd целиком, не позовёт никто. Ловится тем, что
# молчание сторожа дольше недели само по себе аномалия.
#
# Установка: `bin/redjob add` с расписанием раз в сутки. Час выбирать так, чтобы алерт
# заставал человека у клавиатуры: ночная тревога, которую утром сметут вместе с остальными
# уведомлениями, эквивалентна её отсутствию.
set -uo pipefail

# launchd не читает пользовательские rc-файлы: ни PATH с homebrew, ни собственные переменные.
# Это уже стоило инцидентов (падение с кодом 127 на невидимом бинаре). Ставим явно.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

RJ="${REDJOB_HOME:-$HOME/.claude/skills/redjob}"
STATE="$HOME/.cache/redjob/watch-state.txt"
LOG="$HOME/.cache/redjob/watch.log"
mkdir -p "$(dirname "$STATE")"
REMIND_DAYS="${REDJOB_REMIND_DAYS:-7}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$LOG"; }

OUT="$(cd "$RJ" && timeout 300 python3 bin/redjob doctor 2>&1)" || true
CRIT="$(printf '%s' "$OUT" | grep -A1 '^\[CRITICAL\]' || true)"
# подпись набора: только «правило · метка», без изменчивых чисел (часы, счётчики повторов),
# иначе набор «менялся» бы каждый прогон и анти-спам не работал
SIG="$(printf '%s' "$OUT" | grep '^\[CRITICAL\]' | sed 's/^\[CRITICAL\] //' | sort | md5 -q 2>/dev/null || printf '%s' "$OUT" | grep '^\[CRITICAL\]' | sort | md5sum | cut -d' ' -f1)"
# ⚑ Без `|| echo 0`: grep -c при нуле совпадений И печатает «0», И отдаёт rc=1,
# поэтому фолбэк дописывал ВТОРОЙ ноль → N="0\n0" → `[: integer expected`.
N="$(printf '%s' "$OUT" | grep -c '^\[CRITICAL\]')" || N=0
case "$N" in ''|*[!0-9]*) N=0 ;; esac

if [ "${N:-0}" -eq 0 ]; then
  printf 'none\t%s\n' "$(date +%s)" > "$STATE"
  log "чисто (0 CRITICAL)"; exit 0
fi

PREV_SIG=""; PREV_TS=0
[ -f "$STATE" ] && { PREV_SIG="$(cut -f1 "$STATE")"; PREV_TS="$(cut -f2 "$STATE")"; }
NOW="$(date +%s)"
AGE_D=$(( (NOW - ${PREV_TS:-0}) / 86400 ))

if [ "$SIG" = "$PREV_SIG" ] && [ "$AGE_D" -lt "$REMIND_DAYS" ]; then
  log "$N CRITICAL, набор не менялся ($AGE_D д назад слали) — молчу"
  exit 0
fi

WHY="новые находки"; [ "$SIG" = "$PREV_SIG" ] && WHY="всё ещё сломано, ${AGE_D} д"
MSG="$(
  printf '🔧 redjob: %s CRITICAL (%s)\n\n' "$N" "$WHY"
  printf '%s\n' "$CRIT" | sed 's/^\[CRITICAL\] //; s/^--$//' | head -c 3000
  printf '\nПодробно: cd %s && python3 bin/redjob doctor\n' "$RJ"
)"

if [ -z "${REDJOB_NOTIFY_CMD:-}" ]; then
  # Молча не глотаем: без канала сторож не сторож, и это должно быть видно в логе.
  log "$N CRITICAL, но REDJOB_NOTIFY_CMD не задан — отправить некуда (состояние не сдвинуто)"
  printf '%s\n' "$MSG"
  exit 0
fi

SEND="$(printf '%s' "$MSG" | sh -c "$REDJOB_NOTIFY_CMD" 2>/dev/null)"

if [ "$SEND" = "SENT" ]; then
  printf '%s\t%s\n' "$SIG" "$NOW" > "$STATE"
  log "$N CRITICAL → отправлено ($WHY)"
else
  # состояние НЕ обновляем: не смогли позвать — попробуем в следующий раз, а не «отчитались»
  log "$N CRITICAL → ОТПРАВКА НЕ УДАЛАСЬ: ${SEND:-no-result} (состояние не сдвинуто, повтор завтра)"
fi
