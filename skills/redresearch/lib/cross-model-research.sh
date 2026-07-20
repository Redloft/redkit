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
# GEMINI_PROXY: Gemini geo-блокирует RU IP → если не задан, автоопределяется SOCKS5 на
#   127.0.0.1:1080. Таймауты: GPT_MAX_TIME=300с / GEM_MAX_TIME=180с (env-override). См. cross-model.sh.
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

# curl hardening — DRY (identical to cross-model.sh). --max-time вынесен per-leg ниже:
# GPT-5 на объёмных research-отчётах отвечает >120с (см. cross-model.sh, run 2026-07-06).
CURL_OPTS=(
  --silent --show-error
  --fail-with-body
  --proto '=https' --tlsv1.2
)

# Per-leg curl timeouts (сек). GPT-5 медленнее на больших промптах; Gemini — через SOCKS5 proxy.
GPT_MAX_TIME="${GPT_MAX_TIME:-300}"
GEM_MAX_TIME="${GEM_MAX_TIME:-180}"
KIMI_MAX_TIME="${KIMI_MAX_TIME:-480}"   # K3 always-on thinking на больших research-промптах МЕДЛЕННЫЙ (240с не хватало, эмпирика 2026-07-20); gated ногой (RESEARCH_KIMI=1)

# Kimi K3 (Moonshot) — ОПЦИОНАЛЬНАЯ 3-я нога за тумблером RESEARCH_KIMI=1 (default off).
# Кандидат в независимые голоса research-ревью (2026-07-20). Прод-пара остаётся gpt+gemini,
# пока мини-A/B не докажет уникальные находки (урок домен-зависимости: GLM тут отклонён 07-03).
# Гео РФ = прямой доступ (в отличие от Gemini), прокси НЕ нужен.
RESEARCH_KIMI="${RESEARCH_KIMI:-0}"

# ─── Gemini geo-block workaround ───
# Gemini geo-блокирует RU IP (оба auth-пути — и ?key=, и x-goog-api-key header — дают live 400
# FAILED_PRECONDITION, проверено 2026-07-06). Если GEMINI_PROXY не задан — автоопределяем локальный
# SOCKS5 на 127.0.0.1:1080 (ssh -D). "не задан" → автодетект; "" → принудительно без прокси
# (${VAR+set}: асимметрия с GPT_MAX_TIME/GEM_MAX_TIME, где ""==unset→default). Допущение:
# GEMINI_PROXY = socks5://host:port БЕЗ embedded-credentials (уходит в curl argv).
# export → значение переживает self-wrap re-exec (op run пробрасывает env в child).
# Диагностика в stderr (НЕ stdout — там JSON): nc-absent / tunnel-down / detected, иначе
# упавший `ssh -D 1080` даёт немой 400, неотличимый от «прокси не нужен».
# Прокси-автодетект (FI → локальный 1080 → прямой) — единая функция в fi-proxy.sh.
# helper-missing: уважаем явный GEMINI_PROXY, иначе прямой (1080-фолбэк живёт внутри функции,
# т.е. доступен только при наличии helper'а — осознанное сужение сломанной-установки edge).
_GFI=~/.claude/skills/_shared/gemini-fi/fi-proxy.sh
if [ -f "$_GFI" ] && source "$_GFI"; then
  gemini_fi_autodetect_proxy "cross-model-research"
else
  : "${GEMINI_PROXY=}"; export GEMINI_PROXY
fi

# Self-wrap если env не выставлен (один op call на оба провайдера; секрет только в child env)
# GLM протестирован как 3-й голос (mini-A/B 2026-07-03) → ОТКЛОНЁН (B): дубль gpt+gemini на
# research-отчётах (overlap 87%, unique-real 0.5/отчёт, вклад = рантайм не по профилю). Пара gpt+gemini.
_need_wrap=0
[ -z "${OPENAI_API_KEY:-}" ] && _need_wrap=1
[ -z "${GEMINI_API_KEY:-}" ] && _need_wrap=1
[ "$RESEARCH_KIMI" = "1" ] && [ -z "${MOONSHOT_API_KEY:-}" ] && _need_wrap=1
if [ "$_need_wrap" = "1" ]; then
  _envf() {
    printf 'OPENAI_API_KEY=op://AI-Tokens/OpenAI/credential\n'
    printf 'GEMINI_API_KEY=op://AI-Tokens/Gemini/credential\n'
    # ключ Kimi добавляем в env-file ТОЛЬКО при включённой ноге — иначе op не тянет item,
    # и отсутствие/удаление карточки Moonshot не ломает прод-пару gpt+gemini.
    [ "$RESEARCH_KIMI" = "1" ] && printf 'MOONSHOT_API_KEY=op://AI-Tokens/Moonshot Kimi API/credential\n'
  }
  exec op run --env-file=<(_envf) -- bash "$0" "$@"
fi

TOPIC=$(cat "$TOPIC_FILE")
REPORT=$(cat "$REPORT_FILE")
SOURCES=$(cat "$SOURCES_FILE")

# ─── PRIVACY BARRIER (#3) ───────────────────────────────────────────
# report+sources+topic уходят во ВНЕШНИЕ модели (OpenAI US / Google) — тот же
# fail-closed scrub, что в plan-panel/finalize. Маскирует секреты/инфру, БЛОКИРУЕТ
# ИНН/реквизиты/EJ_SENSITIVE. Переиспользуем _shared/external-judge/scrub.sh.
SCRUB="$HOME/.claude/skills/_shared/external-judge/scrub.sh"
if [ ! -f "$SCRUB" ]; then
  printf '{"error":"scrub-missing","note":"privacy scrubber not found; fail-closed, nothing sent to external models"}\n'; exit 0
fi
run_scrub() { printf '%s' "$1" | bash "$SCRUB" 2>/dev/null; }
rc_max=0
S_TOPIC="$(run_scrub "$TOPIC")"     || rc_max=$?
S_REPORT="$(run_scrub "$REPORT")"   || { r=$?; [ "$r" -gt "$rc_max" ] && rc_max=$r; }
S_SOURCES="$(run_scrub "$SOURCES")" || { r=$?; [ "$r" -gt "$rc_max" ] && rc_max=$r; }
if [ "$rc_max" -eq 20 ]; then
  printf '{"error":"denylist-block","note":"research payload matched denylist (ИНН/реквизиты/sensitive) — НЕ отправлено во внешние модели"}\n'; exit 0
elif [ "$rc_max" -ne 0 ]; then
  printf '{"error":"scrub-failed","note":"privacy scrub engine failed — fail-closed, ничего не отправлено"}\n'; exit 0
fi
TOPIC="$S_TOPIC"; REPORT="$S_REPORT"; SOURCES="$S_SOURCES"
# ────────────────────────────────────────────────────────────────────

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
  \"reviewer_model\": \"gpt-5\" or \"gemini-pro-latest\",
  \"report_confidence\": 0.85,
  \"inaccuracies\": [{\"claim\":\"...\",\"issue\":\"...\"}],
  \"missing\": [\"важный аспект который пропущен\"],
  \"unsupported\": [\"утверждение без поддержки источников\"],
  \"disputed_conclusions\": [{\"conclusion\":\"...\",\"your_view\":\"...\"}],
  \"top_concerns\": [{\"severity\":\"high|medium|low\",\"concern\":\"...\"}],
  \"summary\": \"1-3 предложения итого\"
}"

GPT_OUT=$(mktemp); GEM_OUT=$(mktemp); GPT_META=$(mktemp); GEM_META=$(mktemp)
KIMI_OUT=$(mktemp); KIMI_META=$(mktemp)
trap 'rm -f "$GPT_OUT" "$GEM_OUT" "$GPT_META" "$GEM_META" "$KIMI_OUT" "$KIMI_META"' EXIT

call_gpt() {
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    model: "gpt-5",
    messages: [{role:"user", content:$p}],
    response_format: {type:"json_object"}
  }')
  local http
  http=$(curl "${CURL_OPTS[@]}" --max-time "$GPT_MAX_TIME" -o "$GPT_OUT" -w "%{http_code}" \
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
  # секрет-гигиена: ключ в заголовке x-goog-api-key, НЕ в URL (?key= виден в ps/логах прокси)
  http=$(curl "${CURL_OPTS[@]}" --max-time "$GEM_MAX_TIME" "${proxy_arg[@]}" -o "$GEM_OUT" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -d "$payload" \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro-latest:generateContent" || true)
  printf '%s\n' "$http" > "$GEM_META"
}

call_kimi() {
  # Moonshot Chat Completions (OpenAI-совместимый). max_tokens с headroom —
  # K3 always-on thinking жжёт бюджет до ответа (reasoning_tokens), малый лимит → пустой content.
  # max_tokens 16000: K3 в JSON-режиме жжёт ~8000 токенов на reasoning ДО ответа (эмпирика A/B
  # 2026-07-20) — при 8000 finish=length и ПУСТОЙ content на любом размере отчёта. 16000 даёт
  # thinking (~7-8k) + сам ответ (~2-3k) уложиться. Латентность всё равно ~5-7 мин на вызов.
  local payload
  payload=$(jq -nc --arg p "$PROMPT" '{
    model: "kimi-k3",
    messages: [{role:"user", content:$p}],
    max_tokens: 16000,
    response_format: {type:"json_object"}
  }')
  local http
  http=$(curl "${CURL_OPTS[@]}" --max-time "$KIMI_MAX_TIME" -o "$KIMI_OUT" -w "%{http_code}" \
    -H "Authorization: Bearer $MOONSHOT_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    https://api.moonshot.ai/v1/chat/completions || true)
  printf '%s\n' "$http" > "$KIMI_META"
}

call_gpt & PID_GPT=$!
call_gemini & PID_GEM=$!
PID_KIMI=''
if [ "$RESEARCH_KIMI" = "1" ]; then call_kimi & PID_KIMI=$!; fi
wait "$PID_GPT" "$PID_GEM"
[ -n "$PID_KIMI" ] && wait "$PID_KIMI"

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

# ─── Kimi leg parse (только если нога включена) ───
KIMI_JSON='null'; KIMI_USAGE='null'; KIMI_ERR=''; KIMI_IN=0; KIMI_OUT_T=0
if [ "$RESEARCH_KIMI" = "1" ]; then
  KIMI_HTTP=$(cat "$KIMI_META")
  if [ "$KIMI_HTTP" = "200" ]; then
    KIMI_CONTENT=$(jq -r '.choices[0].message.content // ""' < "$KIMI_OUT")
    KIMI_USAGE=$(jq -c '.usage // {}' < "$KIMI_OUT")
    if [ -n "$KIMI_CONTENT" ]; then
      KIMI_JSON=$(echo "$KIMI_CONTENT" | jq -c '.' 2>/dev/null || echo "{\"parse_error\":true,\"raw\":$(echo "$KIMI_CONTENT" | jq -Rs .)}")
    else KIMI_ERR="empty_content"; fi   # пусто при малом бюджете = thinking съел max_tokens
  else
    KIMI_ERR="http_$KIMI_HTTP: $(jq -r '.error.message // tostring' < "$KIMI_OUT" | head -c 200)"
  fi
  KIMI_IN=$(echo "$KIMI_USAGE" | jq -r '.prompt_tokens // 0')
  KIMI_OUT_T=$(echo "$KIMI_USAGE" | jq -r '.completion_tokens // 0')
fi

# Cost estimate (GPT-5 ~$5/M in + $20/M out; Gemini 2.5 Pro $1.25/M in + $5/M out; Kimi K3 $3/M in + $15/M out)
GPT_IN=$(echo "$GPT_USAGE" | jq -r '.prompt_tokens // 0')
GPT_OUT_T=$(echo "$GPT_USAGE" | jq -r '.completion_tokens // 0')
GEM_IN=$(echo "$GEM_USAGE" | jq -r '.promptTokenCount // 0')
GEM_OUT_T=$(echo "$GEM_USAGE" | jq -r '.candidatesTokenCount // 0')
COST=$(awk -v gi="$GPT_IN" -v go="$GPT_OUT_T" -v ggi="$GEM_IN" -v ggo="$GEM_OUT_T" -v ki="$KIMI_IN" -v ko="$KIMI_OUT_T" \
  'BEGIN{printf "%.4f", gi*5/1e6 + go*20/1e6 + ggi*1.25/1e6 + ggo*5/1e6 + ki*3/1e6 + ko*15/1e6}')

jq -nc \
  --argjson gpt "$GPT_JSON" --argjson gem "$GEM_JSON" --argjson kimi "$KIMI_JSON" \
  --arg gpt_err "$GPT_ERR" --arg gem_err "$GEM_ERR" --arg kimi_err "$KIMI_ERR" \
  --argjson gpt_in "$GPT_IN" --argjson gpt_out "$GPT_OUT_T" \
  --argjson gem_in "$GEM_IN" --argjson gem_out "$GEM_OUT_T" \
  --argjson kimi_in "$KIMI_IN" --argjson kimi_out "$KIMI_OUT_T" \
  --arg kimi_on "$RESEARCH_KIMI" \
  --arg cost "$COST" \
  '{
    gpt: $gpt, gemini: $gem
  }
  + (if $kimi_on=="1" then {kimi: $kimi} else {} end)
  + {
    errors: ([ ($gpt_err|select(.!="")), ($gem_err|select(.!="")), ($kimi_err|select(.!="")) ]),
    usage: ({
      gpt: {input_tokens:$gpt_in, output_tokens:$gpt_out},
      gemini: {input_tokens:$gem_in, output_tokens:$gem_out},
      cost_usd: $cost
    } + (if $kimi_on=="1" then {kimi:{input_tokens:$kimi_in, output_tokens:$kimi_out}} else {} end))
  }'
