#!/usr/bin/env bash
# gemini-review.sh — single-Gemini second-opinion на research-отчёт С privacy-барьером.
# Заменяет инлайн-curl в research.js verify-фазе (standard+): тот слал report+sources
# в Gemini БЕЗ scrub. Здесь — тот же fail-closed scrub, что в cross-model-research.sh.
#
# Usage: gemini-review.sh <topic_file> <report_file> <sources_file> [model]
# Выход: JSON { gemini:{...}|null, error?, cost_usd }
set -euo pipefail

TOPIC_FILE="${1:?usage: gemini-review.sh <topic> <report> <sources> [model]}"
REPORT_FILE="${2:?need report}"
SOURCES_FILE="${3:?need sources}"
MODEL="${4:-gemini-pro-latest}"
for var in TOPIC_FILE REPORT_FILE SOURCES_FILE; do
  p="${!var}"; { [ -f "$p" ] && [ -r "$p" ]; } || { printf '{"error":"%s_missing"}\n' "${var,,}"; exit 1; }
done

# self-wrap: ключ только в child env
if [ -z "${GEMINI_API_KEY:-}" ]; then
  exec op run --env-file=<(printf 'GEMINI_API_KEY=op://AI-Tokens/Gemini/credential\n') -- bash "$0" "$@"
fi

# Gemini гео-блокирует РФ (прямой → 400). openclaw-FI SOCKS (TLS e2e, ключ на сервере не виден,
# хелпер прогревает туннель). Fail-open: FI недоступен → PROXY пуст → прямой (RU → вероятен 400).
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
[ -f "$_GFI" ] && source "$_GFI" && PROXY=$(gemini_fi_proxy) || PROXY=""

TOPIC=$(cat "$TOPIC_FILE"); REPORT=$(cat "$REPORT_FILE"); SOURCES=$(cat "$SOURCES_FILE")

# ─── PRIVACY BARRIER (#3) — тот же fail-closed scrub ───
SCRUB="$HOME/.claude/skills/_shared/external-judge/scrub.sh"
[ -f "$SCRUB" ] || { printf '{"error":"scrub-missing","note":"fail-closed, ничего не отправлено"}\n'; exit 0; }
run_scrub() { printf '%s' "$1" | bash "$SCRUB" 2>/dev/null; }
rc_max=0
S_TOPIC="$(run_scrub "$TOPIC")"     || rc_max=$?
S_REPORT="$(run_scrub "$REPORT")"   || { r=$?; [ "$r" -gt "$rc_max" ] && rc_max=$r; }
S_SOURCES="$(run_scrub "$SOURCES")" || { r=$?; [ "$r" -gt "$rc_max" ] && rc_max=$r; }
if [ "$rc_max" -eq 20 ]; then printf '{"error":"denylist-block","note":"payload matched denylist — НЕ отправлено в Gemini"}\n'; exit 0
elif [ "$rc_max" -ne 0 ]; then printf '{"error":"scrub-failed","note":"fail-closed"}\n'; exit 0; fi

PROMPT="Ты — независимое второе мнение (Gemini) по research-отчёту. Найди слабости, не хвали:
1. Что НЕТОЧНО/устарело? 2. Какие важные аспекты ПРОПУЩЕНЫ? 3. Что НЕ подкреплено источниками? 4. overall confidence 0-1.
=== ТЕМА ===
${S_TOPIC}
=== ОТЧЁТ ===
${S_REPORT}
=== ИСТОЧНИКИ ===
${S_SOURCES}
=== END ===
Верни СТРОГО JSON: {\"report_confidence\":0.0,\"inaccuracies\":[],\"missing\":[],\"unsupported\":[],\"summary\":\"...\"}"

CFG=$(mktemp); RESP=$(mktemp); chmod 600 "$CFG"
trap 'rm -f "$CFG" "$RESP"' EXIT
printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$CFG"
payload=$(jq -nc --arg p "$PROMPT" '{contents:[{role:"user",parts:[{text:$p}]}],generationConfig:{temperature:0.3,responseMimeType:"application/json",maxOutputTokens:2000}}')
http=$(curl --silent --show-error --max-time 120 --proto '=https' --tlsv1.2 \
  ${PROXY:+--proxy "$PROXY"} \
  --config "$CFG" -H "Content-Type: application/json" \
  -o "$RESP" -w '%{http_code}' -d "$payload" \
  "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent" 2>/dev/null || true)

if [ "$http" != "200" ]; then
  printf '{"gemini":null,"error":"http_%s"}\n' "$http"; exit 0
fi
CONTENT=$(jq -r '[.candidates[0].content.parts[]? | select((.thought//false)|not) | .text // ""]|join("")' < "$RESP")
GJSON=$(printf '%s' "$CONTENT" | jq -c '.' 2>/dev/null || echo 'null')
GIN=$(jq -r '.usageMetadata.promptTokenCount // 0' < "$RESP")
GOUT=$(jq -r '.usageMetadata.candidatesTokenCount // 0' < "$RESP")
COST=$(awk -v i="$GIN" -v o="$GOUT" 'BEGIN{printf "%.4f", i*1.25/1e6 + o*5/1e6}')
jq -nc --argjson g "$GJSON" --arg c "$COST" '{gemini:$g, cost_usd:$c}'
