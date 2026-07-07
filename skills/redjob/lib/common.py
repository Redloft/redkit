#!/usr/bin/env python3
"""redjob common — пути, парс launchd-стейта, ANSI-хелперы.

Фаза 1 read-only: НИКАКИХ launchctl load/unload, никаких правок plist.
Здесь только чтение (`launchctl list`, `pmset -g log`) и константы.
"""
import os
import re
import subprocess

HOME = os.path.expanduser("~")
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JOBS_YAML = os.path.join(SKILL_DIR, "jobs.yaml")
LAUNCH_AGENTS = os.path.join(HOME, "Library", "LaunchAgents")

# Дефолтный PATH процесса под launchd (НЕ логин-шелл: ~/.zshenv не читается).
# Это ключ к классу поломок «health.sh 127» — homebrew-бинарей тут нет.
LAUNCHD_DEFAULT_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
HOMEBREW_BIN = "/opt/homebrew/bin"

# Явные вендорские префиксы — не «наши», в drift показываются как external.
# Дополняется через env REDJOB_EXTERNAL_PREFIXES (запятые).
EXTERNAL_PREFIXES = tuple(filter(None, (
    "com.apple.", "com.google.", "homebrew.mxcl.",
    *os.environ.get("REDJOB_EXTERNAL_PREFIXES", "").split(","))))

SEV_ORDER = {"CRITICAL": 0, "WARNING": 1, "INFO": 2}


# ---------- ANSI ----------
def _supports_color():
    return os.isatty(1) and os.environ.get("NO_COLOR") is None


_C = _supports_color()


def c(text, code):
    return f"\033[{code}m{text}\033[0m" if _C else text


def sev_color(sev):
    return {"CRITICAL": "1;31", "WARNING": "1;33", "INFO": "0;36"}.get(sev, "0")


# ---------- launchctl (read-only) ----------
def launchctl_list():
    """Вернуть {label: {'pid': int|None, 'last_exit': int|None}} из `launchctl list`.

    Таблица: PID  Status  Label. Status = last exit code (0 = ок, 127 = not found…).
    Показывает ТОЛЬКО загруженные джобы — выгруженная = отсутствует (сигнал drift).
    """
    out = {}
    try:
        r = subprocess.run(["launchctl", "list"], capture_output=True,
                           text=True, timeout=15)
    except Exception:
        return out
    for line in r.stdout.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 3:
            parts = line.split()
        if len(parts) < 3:
            continue
        pid_s, status_s, label = parts[0], parts[1], parts[-1]
        pid = int(pid_s) if pid_s.lstrip("-").isdigit() else None
        last = int(status_s) if status_s.lstrip("-").isdigit() else None
        out[label] = {"pid": pid, "last_exit": last}
    return out


def pmset_last_wakes(n=5):
    """Последние n wake-событий из `pmset -g log` (для thundering-herd INFO).

    Возвращает список строк 'YYYY-MM-DD HH:MM'. Best-effort — пусто при сбое.
    """
    wakes = []
    try:
        r = subprocess.run(["pmset", "-g", "log"], capture_output=True,
                           text=True, timeout=20)
    except Exception:
        return wakes
    for line in r.stdout.splitlines():
        if " Wake " in line or "Wake from" in line:
            m = re.match(r"(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}):\d{2}", line)
            if m:
                stamp = f"{m.group(1)} {m.group(2)}"
                if not wakes or wakes[-1] != stamp:   # дедуп подряд идущих
                    wakes.append(stamp)
    return wakes[-n:]


def is_external_label(label):
    return any(label.startswith(p) for p in EXTERNAL_PREFIXES)


def project_from_label(label):
    """Проект из reverse-DNS label: com.<project>.<name> → <project>.
    Generic (без хардкода имён): com.foo.bar→foo, ai.x.api→x."""
    parts = (label or "").split(".")
    if len(parts) >= 3:
        return parts[1]
    if len(parts) == 2:
        return parts[0]
    return parts[0] if parts and parts[0] else "misc"


# ---------- честный анализ скриптов (исход, не паттерн) ----------
def strip_comments(text):
    """Убрать full-line комментарии (чтобы не матчить бинари в пояснениях)."""
    return "\n".join(l for l in (text or "").splitlines()
                     if not l.lstrip().startswith("#"))


# Позиции, где токен — это ВЫЗОВ команды, а не упоминание в строке/переменной.
_CMD_BOUNDARY = (r"(?:^|[|;&`]|\$\(|\bexec\b|\bcommand\b|\bthen\b|\bdo\b|"
                 r"\bif\b|\bwhile\b|\buntil\b|\belif\b|\{)\s*")
# Опциональный путь-префикс: `/opt/homebrew/bin/op` тоже вызов op (на launchd
# частый паттерн — homebrew не в PATH, потому бинарь зовут абсолютным путём).
_PATH_PREFIX = r"(?:[\w./~-]*/)?"


def invokes(text, binname):
    """True, если binname вызывается как команда — по имени ИЛИ по пути."""
    code = strip_comments(text)
    rx = _CMD_BOUNDARY + _PATH_PREFIX + re.escape(binname) + r"\b"
    return re.search(rx, code, re.M) is not None


def uses_login_shell(text):
    """Скрипт делегирует в login-shell (zsh -lc / bash -l …)?

    Login-shell грузит ~/.zshenv/.zprofile → PATH к ~/.local/bin, homebrew.
    Статический PATH-резолв такое подтвердить не может — не CRITICAL.
    """
    return bool(re.search(r"\b(?:zsh|bash|sh)\s+-[A-Za-z]*l[A-Za-z]*c?\b|-lc\b",
                          strip_comments(text)))


def parse_path_assignments(text, base):
    """Собрать эффективный PATH: base + все реальные PATH=… присвоения из скрипта.

    Разворачивает $HOME/~; литеральные каталоги prepend'ятся (скрипт сам чинит
    PATH — ровно как run_headless.sh: PATH="$HOME/.local/bin:$PATH")."""
    dirs = [d for d in base.split(":") if d]
    for m in re.finditer(r'(?m)^\s*(?:export\s+)?PATH=("?)([^"\n]+?)\1\s*$',
                         strip_comments(text)):
        for tok in m.group(2).split(":"):
            tok = tok.strip()
            if not tok:
                continue
            # РАЗВЕРНУТЬ $HOME/~ ДО проверки на переменную — иначе канонический
            # `$HOME/.local/bin` отбрасывался бы как «переменная» (был мёртвый код).
            tok = (tok.replace("${HOME}", HOME).replace("$HOME", HOME))
            if tok.startswith("~"):
                tok = HOME + tok[1:]
            # оставшиеся ссылки на переменные ($PATH, ${OTHER}) резолвить нечем — пропуск
            if tok.startswith("$") or tok.startswith("${"):
                continue
            if tok.startswith("/") and tok not in dirs:
                dirs.insert(0, tok)
    return ":".join(dirs)
