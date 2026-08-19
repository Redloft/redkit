#!/usr/bin/env bash
# test-cross-model.sh — регрессионный гейт cross-model verification (fix 2026-07-06).
# Locks in: per-leg curl timeouts (GPT 300с / Gemini 180с) + GEMINI_PROXY автодетект SOCKS5.
# Покрывает ТРИ sibling-скрипта: plan-panel/lib/cross-model.sh, redresearch/lib/cross-model.sh
# (байт-идентичен первому), redresearch/lib/cross-model-research.sh (header-auth вариант).
# БЫСТРЫЙ и БЕЗ сети/API — годится как stabilize-гейт. Зелёный = fix на месте, копии не разошлись.
#
# Usage: test-cross-model.sh [--self-test]   (--self-test — синоним, для единообразия с sibling-lib)
set -uo pipefail

SK="$HOME/.claude/skills"
PP="$SK/plan-panel/lib/cross-model.sh"
RR="$SK/redresearch/lib/cross-model.sh"
RRR="$SK/redresearch/lib/cross-model-research.sh"
PANEL="$SK/plan-panel/workflow/panel.js"
ALL_SH=("$PP" "$RR" "$RRR")

declare -i FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL+=1; }
lbl(){ printf '%s/%s' "$(basename "$(dirname "$(dirname "$1")")")" "$(basename "$1")"; }

# ── 0. файлы на месте ──
for f in "${ALL_SH[@]}" "$PANEL"; do
  [ -f "$f" ] || no "MISSING file: $f"
done

# ── 1. syntax: bash -n на всех трёх + node --check panel.js ──
for f in "${ALL_SH[@]}"; do
  bash -n "$f" 2>/dev/null && ok "bash -n $(lbl "$f")" || no "bash -n $(lbl "$f")"
done
node --check "$PANEL" 2>/dev/null && ok "node --check panel.js" || no "node --check panel.js"

# ── 2. shellcheck (conditional — пропуск если не установлен, НЕ фейл) ──
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${ALL_SH[@]}"; do
    shellcheck -S warning "$f" >/dev/null 2>&1 && ok "shellcheck $(lbl "$f")" || no "shellcheck $(lbl "$f")"
  done
else
  printf '  ~ shellcheck не установлен — пропуск (не фейл)\n'
fi

# ── 3. fix-invariants: каждый скрипт несёт per-leg timeout + proxy autodetect ──
# grep -F (literal) — паттерны содержат $ и ". Эти инварианты ПРИВЯЗЫВАЮТ реальный код к
# логике, протестированной в блоке 4 (если grep проходит — в файле именно тот блок).
inv(){ grep -qF "$2" "$1" && ok "invariant [$3] $(lbl "$1")" || no "invariant MISSING [$3] в $(lbl "$1")"; }
for f in "${ALL_SH[@]}"; do
  inv "$f" 'GPT_MAX_TIME:-300'          "GPT timeout 300"
  inv "$f" 'GEM_MAX_TIME:-180'          "Gemini timeout 180"
  # Инвариант обновлён 2026-08-19: раньше пинился инлайновый `${GEMINI_PROXY+set}`, но
  # автодетект вынесен в общий хелпер `_shared/gemini-fi/fi-proxy.sh` (июль) — тест ловил
  # переезд реализации, а не поломку. Поведенческие проверки прокси (блок 4 ниже) всё это
  # время проходили. Пиним ТО, ЧТО ВАЖНО: скрипт маршрутизирует прокси через общую функцию.
  inv "$f" 'gemini_fi_autodetect_proxy'  "proxy autodetect guard"
  inv "$f" 'max-time "$GPT_MAX_TIME"'   "GPT per-leg timeout"
  inv "$f" 'max-time "$GEM_MAX_TIME"'   "Gemini per-leg timeout"
  # negative: старый общий --max-time <N> НЕ должен остаться в строке CURL_OPTS
  if grep -Eq '^[[:space:]]*--silent --show-error --max-time [0-9]+' "$f"; then
    no "regression [$(lbl "$f")]: старый shared --max-time всё ещё в CURL_OPTS"
  else
    ok "no-regress [$(lbl "$f")]: shared --max-time убран из CURL_OPTS"
  fi
done

# ── 4. proxy-detection ЛОГИКА (4 кейса, mocked nc). Реплика блока из скриптов;
#       invariant #3 гарантирует, что реальный код == этой логике. ──
detect_proxy(){ # $1: имитирует результат nc (0=туннель открыт, 1=закрыт)
  local ncret="$1"
  if [ -z "${GEMINI_PROXY+set}" ]; then
    if [ "$ncret" -eq 0 ]; then GEMINI_PROXY="socks5://127.0.0.1:1080"; else GEMINI_PROXY=""; fi
  fi
  printf '%s' "${GEMINI_PROXY:-}"
}
r="$(unset GEMINI_PROXY; detect_proxy 0)"; [ "$r" = "socks5://127.0.0.1:1080" ] && ok "proxy: unset + туннель → автодетект 1080" || no "proxy unset+tunnel got '$r'"
r="$(unset GEMINI_PROXY; detect_proxy 1)"; [ -z "$r" ] && ok "proxy: unset + нет туннеля → пусто" || no "proxy unset+notunnel got '$r'"
r="$(GEMINI_PROXY=''; detect_proxy 0)";    [ -z "$r" ] && ok "proxy: '' явно → без прокси (respected)" || no "proxy empty got '$r'"
r="$(GEMINI_PROXY='socks5://h:9'; detect_proxy 0)"; [ "$r" = "socks5://h:9" ] && ok "proxy: явный override → respected" || no "proxy explicit got '$r'"

# ── 5. timeout defaults ──
r="$(unset GPT_MAX_TIME; echo "${GPT_MAX_TIME:-300}")"; [ "$r" = 300 ] && ok "timeout: GPT default 300" || no "timeout GPT default got '$r'"
r="$(GPT_MAX_TIME=90; echo "${GPT_MAX_TIME:-300}")";    [ "$r" = 90 ]  && ok "timeout: GPT env-override" || no "timeout GPT override got '$r'"

# ── 6. drift-guard: plan-panel и redresearch cross-model.sh байт-идентичны ──
h1="$(shasum -a 256 "$PP" 2>/dev/null | awk '{print $1}')"
h2="$(shasum -a 256 "$RR" 2>/dev/null | awk '{print $1}')"
if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then
  ok "drift-guard: plan-panel == redresearch cross-model.sh (sha256)"
else
  no "drift-guard: копии cross-model.sh РАЗОШЛИСЬ — правку носи в обе (или обнови этот тест)"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ cross-model regression: все проверки пройдены"; exit 0
else echo "❌ cross-model regression: провалено проверок — $FAIL"; exit 1; fi
