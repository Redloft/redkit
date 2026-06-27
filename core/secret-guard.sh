#!/usr/bin/env bash
# secret-guard.sh — keyword-детектор секретов для СТРУКТУРНЫХ machine-payload (state/events/escalation).
# Почему не strip-secrets.sh: его энтропийный детектор ложно срабатывает на легитимных UUID/путях/SHA
# (run_path в temp-dir, deploy_intent_id, build_sha). Здесь — только известные токен-паттерны.
# Глубинная защита остаётся в дизайне: redwork НИКОГДА не кладёт raw stdout/stderr команд в payload —
# поля конструируются из контролируемых значений (коды, статусы, enum, id).
#
# source secret-guard.sh; kw_secret_found "<str>"  → exit 0 если найден секрет-паттерн, 1 если чисто.

# split-литералы в комментах примеров не нужны; regex матчит префиксы, не содержит самих токенов.
# NB: op:// НЕ включён намеренно — это БЕЗОПАСНАЯ ссылка (значение в 1Password), а не секрет;
# его блокировка ложно роняла легит-рефы в payload/escalation (DoS). Ловим только секрет-ЗНАЧЕНИЯ.
SECRET_KW_RE='sk-[A-Za-z0-9]{8}|ghp_[A-Za-z0-9]|gho_[A-Za-z0-9]|github_pat_|AIza[0-9A-Za-z_-]{10}|xox[baprs]-[0-9]|-----BEGIN|eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}|(password|passwd|secret|token|api[_-]?key)[=:][^[:space:]"]{4,}'

kw_secret_found() {
  printf '%s' "${1:-}" | grep -qiE "$SECRET_KW_RE"
}
