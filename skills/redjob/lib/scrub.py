#!/usr/bin/env python3
"""redjob scrub — secrets-lint реестра и безопасное цитирование логов.

Маскировщик `mask()` — встроенный (или внешний через REDJOB_MASK_MODULE) + key-префиксы. Инвариант scrub-on-render (plan v2,
critical #1): всё, что redjob печатает наружу (list --md, doctor-отчёт,
цитаты логов, TG-алерт), проходит через scrub_text — единая точка.
"""
import os
import re
import importlib.util

# Необязательный внешний модуль-маскировщик (единый стиль в своей экосистеме).
# Задаётся env REDJOB_MASK_MODULE=/path/to/mod.py с функцией mask(str)->str.
# Не задан → встроенный fallback (полноценный, self-contained для OSS).
_MG = os.environ.get("REDJOB_MASK_MODULE")


def _load_mask():
    """mask из REDJOB_MASK_MODULE если задан; иначе встроенный фолбэк."""
    try:
        if not _MG or not os.path.exists(_MG):
            raise ImportError
        spec = importlib.util.spec_from_file_location("_redjob_mask_ext", _MG)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.mask
    except Exception:
        def _mask(frag):
            frag = (frag or "").strip()[:40]
            if len(frag) <= 4:
                return (frag[:1] or "•") + "•" * max(len(frag) - 1, 0)
            return frag[:2] + "•" * (len(frag) - 4) + frag[-2:]
        return _mask


mask = _load_mask()

# Ключ-префиксы известных провайдеров + op:// ЗНАЧЕНИЯ (не ссылки-в-обёртке).
# op://AI-Tokens/Item/credential как СТРОКА-значение в реестре = утечка модели
# доступа; сама ссылка внутри `op run --env-file` — легитимна, но её в jobs.yaml
# быть не должно (реестр хранит только имена env, шаг 1).
SECRET_PATTERNS = [
    (re.compile(r"sk-[A-Za-z0-9_\-]{16,}"), "OpenAI/Anthropic-ключ (sk-)"),
    (re.compile(r"ghp_[A-Za-z0-9]{20,}"), "GitHub token (ghp_)"),
    (re.compile(r"gho_[A-Za-z0-9]{20,}"), "GitHub OAuth (gho_)"),
    (re.compile(r"AIza[A-Za-z0-9_\-]{20,}"), "Google API key (AIza)"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"), "Slack token (xox)"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key (AKIA)"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}"), "JWT/сервисный токен"),
    # Telegram bot token: <bot_id>:AA<35 base64url>
    (re.compile(r"\b\d{6,12}:AA[A-Za-z0-9_\-]{30,}"), "Telegram bot token"),
    # op:// ЗНАЧЕНИЕ любого секрет-поля (не только credential/password/token)
    (re.compile(r"op://[^\s\"']+/(?:credential|password|token|secret|api[_-]?key|key)\b"),
     "op:// значение секрета"),
    # PEM-заголовок приватного ключа
    (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
     "PEM приватный ключ"),
    # пароль в URL: scheme://user:pass@host
    (re.compile(r"://[^/\s:@]+:[^/\s@]+@"), "пароль в URL (user:pass@)"),
    # обобщённо: pass/secret/token/api_key = <значение> (assignment-контекст, не голый hex)
    (re.compile(r"(?i)\b(?:pass(?:word)?|secret|token|api[_-]?key)\s*[:=]\s*['\"]?[^\s'\"]{6,}"),
     "секрет в присваивании (pass/secret/token/api_key=…)"),
]


def find_secrets(text):
    """Список (label, masked_fragment) для всех совпадений. Пустой = чисто."""
    hits = []
    for rx, label in SECRET_PATTERNS:
        for m in rx.finditer(text or ""):
            hits.append((label, mask(m.group(0))))
    return hits


def scrub_text(text):
    """Заменить все секрет-подобные фрагменты на маску. Единая точка render."""
    out = text or ""
    for rx, _ in SECRET_PATTERNS:
        out = rx.sub(lambda m: mask(m.group(0)), out)
    return out


def lint_registry_file(path):
    """Прогнать сырой файл jobs.yaml через детектор. Список (label, masked)."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return find_secrets(f.read())
