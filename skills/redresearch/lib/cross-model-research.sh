#!/usr/bin/env bash
# Cross-model research review — даёт topic + report + sources двум независимым
# моделям (GPT-5 и Gemini 2.5 Pro) для outside opinion на research-отчёт.
# Research-аналог lib/cross-model.sh (тот — plan-panel сигнатура plan/judge/reviews).
#
# Usage:
#   cross-model-research.sh <topic_file> <report_file> <sources_file>
#
# Выход: JSON { gpt: {...}, gemini: {...}, errors: [...], usage:{...cost_usd} }
#
# Секреты: OPENAI_API_KEY + GEMINI_API_KEY инъектятся через op run (self-wrap ниже).
# НИКОГДА не печатать значения. Без curl -v / 2>&1 (Authorization header в base64
# тривиально декодируется — см. CLAUDE.md secrets protocol).
set -euo pipefail

TOPIC_FILE="${1:?usage: cross-model-research.sh <topic> <report> <sources>}"
REPORT_FILE="${2:?need report.md}"
SOURCES_FILE="${3:?need sources (jsonl or text)}"

for var in TOPIC_FILE REPORT_FILE SOURCES_FILE; do
  path="${!var}"
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf '{"error":"%s_missing_or_unreadable","path":"%s"}\n' "${var,,}" "$path"
    exit 1
  fi
done

# curl hardening — DRY (identical to cross-model.sh)
CURL_OPTS=(
  --silent --show-error --max-time 120
  --fail-with-body
  --proto '=https' --tlsv1.2
)

# Self-wrap если env не выставлен (один op call на оба провайдера; секрет только в child env)
if [ -z "${OPENAI_API_KEY:-}" ] || [ -z "${GEMINI_API_KEY:-}" ]; then
  exec op run --env-file=<(cat <<'EOF'
OPENAI_API_KEY=op://AI-Tokens/OpenAI/credential
GEMINI_API_KEY=op://AI-Tokens/Gemini/credential
EOF
) -- bash "$0" "$@"
fi

TOPIC=$(cat "$TOPIC_FILE")
REPORT=$(cat "$REPORT_FILE")
SOURCES=$(cat "$SOURCES_FILE")

# Одинаковый промпт обеим моделям — честный cross-check
PROMPT="Ты — senior independent research reviewer. Тебе показывают research-отчёт,
составленный другой AI-системой (Claude через skill redresearch), и источники, с
которыми она работала.

Твоя задача — НАЙТИ СЛАБОСТИ (не хвалить):

1. Что в отчёте НЕТОЧНО / устарело / переврано относительно реальности?
2. Какие важные аспекты темы ПРОПУЩЕНЫ?
3. Какие утверждения НЕ подкреплены перечисленными источниками (возможная галлюцинация)?
4. С какими выводами ты НЕ согласен и почему?
5. Confidence в качестве отчёта (0-1).

=== ТЕМА ===
${TOPIC}

=== ОТЧЁТ (Claude/redresearch) ===
${REPORT}

=== ИСТОЧНИКИ ===
${SOURCES}

=== END ===

Верни СТРОГО JSON (без markdown):
{
  \"reviewer_model\": \"gpt-5\" or \"gemini-2.5-pro\",
  \"report_confidence\": 0.85,
  \"inaccuracies\": [{\"claim\":\"...\",\"issue\":\"...\"}],
  \"missing\": [\"важный аспект который пропущен\"],
  \"unsupported\": [\"утверждение без поддержки источников\"],
  \"disputed_conclusions\": [{\"conclusion\":\"...\",\"your_view\":\"...\"}],
  \"top_concerns\": [{\"severity\":\"high|medium|low\",\"concern\":\"...\"}],
  \"summary\": \"1-3 предложения итого\"
}"

GPT_OUT=$(mktemp); GEM_OUT=$(mktemp); GPT_META=$(mktemp); GEM_META=$(mktemp)
trap 'rm -f "$GPT_OUT" "$GEM_OUT" "$GPT_META" "$GEM_META"' EXIT

call_gpt() {
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    model: "gpt-5",
    messages: [{role:"user", content:$p}],
    response_format: {type:"json_object"}
  }')
  local http
  http=$(curl "${CURL_OPTS[@]}" -o "$GPT_OUT" -w "%{http_code}" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    https://api.openai.com/v1/chat/completions || true)
  printf '%s\n' "$http" > "$GPT_META"
}

call_gemini() {
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    contents: [{parts: [{text:$p}]}],
    generationConfig: {temperature: 0.3, responseMimeType: "application/json"}
  }')
  local proxy_arg=()
  if [ -n "${GEMINI_PROXY:-}" ]; then
    local target="${GEMINI_PROXY#socks5://}"; target="${target#socks5h://}"
    proxy_arg=(--socks5-hostname "$target")
  fi
  local http
  http=$(curl "${CURL_OPTS[@]}" "${proxy_arg[@]}" -o "$GEM_OUT" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=$GEMINI_API_KEY" || true)
  printf '%s\n' "$http" > "$GEM_META"
}

call_gpt & PID_GPT=$!
call_gemini & PID_GEM=$!
wait "$PID_GPT" "$PID_GEM"

GPT_HTTP=$(cat "$GPT_META"); GEM_HTTP=$(cat "$GEM_META")

GPT_JSON='null'; GPT_USAGE='null'; GPT_ERR=''
if [ "$GPT_HTTP" = "200" ]; then
  GPT_CONTENT=$(jq -r '.choices[0].message.content // ""' < "$GPT_OUT")
  GPT_USAGE=$(jq -c '.usage // {}' < "$GPT_OUT")
  if [ -n "$GPT_CONTENT" ]; then
    GPT_JSON=$(echo "$GPT_CONTENT" | jq -c '.' 2>/dev/null || echo "{\"parse_error\":true,\"raw\":$(echo "$GPT_CONTENT" | jq -Rs .)}")
  else GPT_ERR="empty_content"; fi
else
  GPT_ERR="http_$GPT_HTTP: $(jq -r '.error.message // tostring' < "$GPT_OUT" | head -c 200)"
fi

GEM_JSON='null'; GEM_USAGE='null'; GEM_ERR=''
if [ "$GEM_HTTP" = "200" ]; then
  GEM_CONTENT=$(jq -r '.candidates[0].content.parts[0].text // ""' < "$GEM_OUT")
  GEM_USAGE=$(jq -c '.usageMetadata // {}' < "$GEM_OUT")
  if [ -n "$GEM_CONTENT" ]; then
    GEM_JSON=$(echo "$GEM_CONTENT" | jq -c '.' 2>/dev/null || echo "{\"parse_error\":true,\"raw\":$(echo "$GEM_CONTENT" | jq -Rs .)}")
  else GEM_ERR="empty_content"; fi
else
  GEM_ERR="http_$GEM_HTTP: $(jq -r '.error.message // tostring' < "$GEM_OUT" | head -c 200)"
fi

# Cost estimate (GPT-5 ~$5/M in + $20/M out; Gemini 2.5 Pro $1.25/M in + $5/M out)
GPT_IN=$(echo "$GPT_USAGE" | jq -r '.prompt_tokens // 0')
GPT_OUT_T=$(echo "$GPT_USAGE" | jq -r '.completion_tokens // 0')
GEM_IN=$(echo "$GEM_USAGE" | jq -r '.promptTokenCount // 0')
GEM_OUT_T=$(echo "$GEM_USAGE" | jq -r '.candidatesTokenCount // 0')
COST=$(awk -v gi="$GPT_IN" -v go="$GPT_OUT_T" -v ggi="$GEM_IN" -v ggo="$GEM_OUT_T" \
  'BEGIN{printf "%.4f", gi*5/1e6 + go*20/1e6 + ggi*1.25/1e6 + ggo*5/1e6}')

jq -nc \
  --argjson gpt "$GPT_JSON" --argjson gem "$GEM_JSON" \
  --arg gpt_err "$GPT_ERR" --arg gem_err "$GEM_ERR" \
  --argjson gpt_in "$GPT_IN" --argjson gpt_out "$GPT_OUT_T" \
  --argjson gem_in "$GEM_IN" --argjson gem_out "$GEM_OUT_T" \
  --arg cost "$COST" \
  '{
    gpt: $gpt, gemini: $gem,
    errors: [ ($gpt_err|select(.!="")), ($gem_err|select(.!="")) ],
    usage: {
      gpt: {input_tokens:$gpt_in, output_tokens:$gpt_out},
      gemini: {input_tokens:$gem_in, output_tokens:$gem_out},
      cost_usd: $cost
    }
  }'
