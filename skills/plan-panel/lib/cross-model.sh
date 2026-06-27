#!/usr/bin/env bash
# Cross-model verification — даёт plan + Claude judge.md двум независимым моделям
# (GPT-5 и Gemini 2.5 Pro) для outside opinion. Выводит aggregated JSON в stdout.
#
# Usage:
#   cross-model.sh <plan_file> <judge_file> <reviews_file>
#
# Выход: JSON { gpt: {...}, gemini: {...}, errors: [...], cost_estimate_usd: number }
#
# Требует op run снаружи с OPENAI_API_KEY + GEMINI_API_KEY + GEMINI_PROXY (SOCKS5 на macOS).
set -euo pipefail

PLAN_FILE="${1:?usage: cross-model.sh <plan> <judge> <reviews>}"
JUDGE_FILE="${2:?need judge.md}"
REVIEWS_FILE="${3:?need reviews.json}"

# Validate inputs — files must exist and be readable regular files
for var in PLAN_FILE JUDGE_FILE REVIEWS_FILE; do
  path="${!var}"
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf '{"error":"%s_missing_or_unreadable","path":"%s"}\n' "${var,,}" "$path"
    exit 1
  fi
done

# curl hardening flags — DRY константа
CURL_OPTS=(
  --silent --show-error --max-time 120
  --fail-with-body
  --proto '=https' --tlsv1.2
)

# Self-wrap если env не выставлен (один Touch ID/op call на оба провайдера)
if [ -z "${OPENAI_API_KEY:-}" ] || [ -z "${GEMINI_API_KEY:-}" ]; then
  exec op run --env-file=<(cat <<'EOF'
OPENAI_API_KEY=op://AI-Tokens/OpenAI/credential
GEMINI_API_KEY=op://AI-Tokens/Gemini/credential
EOF
) -- bash "$0" "$@"
fi

PLAN=$(cat "$PLAN_FILE")
JUDGE=$(cat "$JUDGE_FILE")
REVIEWS=$(cat "$REVIEWS_FILE")

# Promt одинаковый для обеих моделей — для честного cross-check
PROMPT="Ты — senior independent reviewer. Тебе показывают:

1. ОРИГИНАЛЬНЫЙ ПЛАН пользователя
2. MULTI-ROLE REVIEW от другой AI system (Claude через skill plan-panel — несколько expert-ролей + judge)

Твоя задача:

1. **Что Claude/panel УПУСТИЛ?** Какие важные dimensions не покрыты (думай про angles которые конкретно ты как другая модель видишь лучше)?
2. **С какими findings ты НЕ СОГЛАСЕН?** Перечисли + обоснование (severity revised если другая)
3. **Какие 2-3 главных дополнительных concerns** у тебя по плану?
4. **Confidence overall** в качестве оригинального panel review (0-1)

=== ПЛАН ===
${PLAN}

=== CLAUDE PANEL REVIEW (judge + roles) ===
JUDGE:
${JUDGE}

ROLE REVIEWS (compact):
${REVIEWS}

=== END ===

Верни СТРОГО JSON (без markdown):
{
  \"reviewer_model\": \"gpt-5\" or \"gemini-2.5-pro\",
  \"panel_confidence\": 0.85,
  \"agreed_findings\": [\"short refs to claude findings you agree with\"],
  \"disputed_findings\": [
    {\"original_ref\": \"...\", \"claude_severity\": \"critical\", \"your_severity\": \"warning\", \"reasoning\": \"...\"}
  ],
  \"missing_dimensions\": [
    {\"area\": \"...\", \"why_missed\": \"...\", \"suggestion\": \"...\"}
  ],
  \"your_top_concerns\": [
    {\"severity\": \"critical|warning|suggestion\", \"area\": \"...\", \"issue\": \"...\", \"suggestion\": \"...\"}
  ],
  \"verdict_revision\": \"agree|stricter|lenient\",
  \"summary\": \"1-3 sentences итого\"
}"

# Temp файлы для параллельных запросов
GPT_OUT=$(mktemp)
GEM_OUT=$(mktemp)
GPT_META=$(mktemp)
GEM_META=$(mktemp)
trap 'rm -f "$GPT_OUT" "$GEM_OUT" "$GPT_META" "$GEM_META"' EXIT

# ─── GPT-5 ───
call_gpt() {
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    model: "gpt-5",
    messages: [{role: "user", content: $p}],
    response_format: {type: "json_object"}
  }')
  local http
  # `--fail-with-body` возвращает non-zero на 4xx/5xx, но всё равно пишет body — нам нужен
  # error message. Поэтому игнорируем exit code (он у нас в HTTP code).
  http=$(curl "${CURL_OPTS[@]}" \
    -o "$GPT_OUT" -w "%{http_code}" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    https://api.openai.com/v1/chat/completions || true)
  printf '%s\n' "$http" > "$GPT_META"
}

# ─── Gemini 2.5 Pro ─── (через SOCKS5 proxy если задан)
call_gemini() {
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    contents: [{parts: [{text: $p}]}],
    generationConfig: {
      temperature: 0.3,
      responseMimeType: "application/json"
    }
  }')
  local proxy_arg=()
  if [ -n "${GEMINI_PROXY:-}" ]; then
    local target="${GEMINI_PROXY#socks5://}"
    target="${target#socks5h://}"
    proxy_arg=(--socks5-hostname "$target")
  fi
  local http
  http=$(curl "${CURL_OPTS[@]}" \
    "${proxy_arg[@]}" \
    -o "$GEM_OUT" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=$GEMINI_API_KEY" || true)
  printf '%s\n' "$http" > "$GEM_META"
}

# Запускаем параллельно
call_gpt &
PID_GPT=$!
call_gemini &
PID_GEM=$!
wait "$PID_GPT" "$PID_GEM"

GPT_HTTP=$(cat "$GPT_META")
GEM_HTTP=$(cat "$GEM_META")

# Extract responses
GPT_JSON='null'
GPT_USAGE='null'
GPT_ERR=''
if [ "$GPT_HTTP" = "200" ]; then
  GPT_CONTENT=$(jq -r '.choices[0].message.content // ""' < "$GPT_OUT")
  GPT_USAGE=$(jq -c '.usage // {}' < "$GPT_OUT")
  if [ -n "$GPT_CONTENT" ]; then
    GPT_JSON=$(echo "$GPT_CONTENT" | jq -c '.' 2>/dev/null || echo "{\"parse_error\": true, \"raw\": $(echo "$GPT_CONTENT" | jq -Rs .)}")
  else
    GPT_ERR="empty_content"
  fi
else
  GPT_ERR="http_$GPT_HTTP: $(jq -r '.error.message // tostring' < "$GPT_OUT" | head -c 200)"
fi

GEM_JSON='null'
GEM_USAGE='null'
GEM_ERR=''
if [ "$GEM_HTTP" = "200" ]; then
  GEM_CONTENT=$(jq -r '.candidates[0].content.parts[0].text // ""' < "$GEM_OUT")
  GEM_USAGE=$(jq -c '.usageMetadata // {}' < "$GEM_OUT")
  if [ -n "$GEM_CONTENT" ]; then
    GEM_JSON=$(echo "$GEM_CONTENT" | jq -c '.' 2>/dev/null || echo "{\"parse_error\": true, \"raw\": $(echo "$GEM_CONTENT" | jq -Rs .)}")
  else
    GEM_ERR="empty_content"
  fi
else
  GEM_ERR="http_$GEM_HTTP: $(jq -r '.error.message // tostring' < "$GEM_OUT" | head -c 200)"
fi

# Cost estimate (GPT-5 ~$5/M input + $20/M output;  Gemini 2.5 Pro $1.25/M in + $5/M out)
GPT_IN=$(echo "$GPT_USAGE"  | jq -r '.prompt_tokens // 0')
GPT_OUT_T=$(echo "$GPT_USAGE" | jq -r '.completion_tokens // 0')
GEM_IN=$(echo "$GEM_USAGE"  | jq -r '.promptTokenCount // 0')
GEM_OUT_T=$(echo "$GEM_USAGE" | jq -r '.candidatesTokenCount // 0')

COST=$(awk -v gi="$GPT_IN" -v go="$GPT_OUT_T" -v ggi="$GEM_IN" -v ggo="$GEM_OUT_T" '
BEGIN {
  c = gi * 5/1000000 + go * 20/1000000 + ggi * 1.25/1000000 + ggo * 5/1000000
  printf "%.4f", c
}')

# Final aggregated output
jq -nc \
  --argjson gpt "$GPT_JSON" \
  --argjson gem "$GEM_JSON" \
  --arg gpt_err "$GPT_ERR" \
  --arg gem_err "$GEM_ERR" \
  --argjson gpt_in "$GPT_IN" \
  --argjson gpt_out "$GPT_OUT_T" \
  --argjson gem_in "$GEM_IN" \
  --argjson gem_out "$GEM_OUT_T" \
  --arg cost "$COST" \
  '{
    gpt: $gpt,
    gemini: $gem,
    errors: [
      ($gpt_err | select(. != "")),
      ($gem_err | select(. != ""))
    ],
    usage: {
      gpt: { input_tokens: $gpt_in, output_tokens: $gpt_out },
      gemini: { input_tokens: $gem_in, output_tokens: $gem_out },
      cost_usd: $cost
    }
  }'
