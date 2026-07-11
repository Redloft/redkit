#!/usr/bin/env python3
"""redjob vault-audit — детерминированная развёртка «кто может открыть окно сейфа».

Класс поломки: `op` (1Password CLI) без OP_SERVICE_ACCOUNT_TOKEN под GUI-запуском
Claude Code (Dock не читает ~/.zshenv) или в headless-цепочке → op лезет в
десктоп-1Password/биометрию → macOS-окно TCC «доступ к данным» / Touch ID.

ПОЧЕМУ статика, а не лог: события tccd SystemPolicyAppData и биометрии НЕ попадают
в `log show` (приватны на дефолтном уровне) — проверено эмпирически. Значит
рантайм-форензика невозможна; атрибуция строится детерминированно из конфигов и
кода. Живые `op`-процессы СОЗНАТЕЛЬНО не флагаются: op-sa делает `exec op`, потому
в `ps` обёртка неотличима от голого `op` → флаг был бы гаданием (ложные срабат.).

Слепые зоны, которые закрывает (мимо doctor op-safety depth=1):
  1. MCP-серверы в ~/.claude.json (+ project .mcp.json) с `command:"op"` без обёртки;
  2. headless-цепочки launchd-джоб глубже depth-1 (джоба → дочерний скрипт зовёт
     `op` и НИ звена цепочки не гардит токен) — класс: op в дочернем скрипте цепочки.

Гард = любой из: обёртка op-sa, `source op_env.sh`, экспорт OP_SERVICE_ACCOUNT_TOKEN,
`security find-generic-password ... op-service-account`.

СТРОГО read-only. Секретов не касается: где фикс требует операции с credential
(ротация/запись) — делегируется скиллу `secrets` (текст фикса это указывает).
"""
import os
import re
import sys
import glob
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import scrub

CLAUDE_JSON = os.path.join(common.HOME, ".claude.json")
# Маркеры гарда токена в теле скрипта/обёртки (по comment-stripped тексту).
# ИЗВЕСТНЫЙ tradeoff (принят): substring-OR по всей цепочке — маркер в несвязанной
# строке (лог-сообщение, dead branch) пометит цепочку safe даже если фактический
# `op`-вызов гардом не покрыт. False-negative-риск; полный reachability-анализ —
# оверкилл для bash-статики. Осознанно оставлено дешёвой эвристикой.
GUARD_MARKERS = ("op-sa", "op_env.sh", "OP_SERVICE_ACCOUNT_TOKEN",
                 "op-service-account")


# ---------- модель находки (тот же контракт, что doctor.Finding, + area/target) ----------
class VFinding:
    __slots__ = ("sev", "area", "target", "msg", "fix")

    def __init__(self, sev, area, target, msg, fix=None):
        self.sev, self.area, self.target, self.msg, self.fix = sev, area, target, msg, fix


# ---------- гард-детекторы ----------
def _read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        return ""


def script_guarded(path):
    """True, если скрипт сам гардит SA-токен (по коду, не по комментарию)."""
    code = common.strip_comments(_read(path))
    return any(m in code for m in GUARD_MARKERS)


def _basename(cmd):
    return os.path.basename((cmd or "").strip())


def _is_text_script(path):
    """True только для текстовых скриптов (расширение .sh/.py ИЛИ shebang).

    Защита от ложных срабатываний: скомпилированный бинарь (mach-O MCP-сервер)
    случайно содержит байты «op» — грепать его как скрипт НЕЛЬЗЯ."""
    if path.endswith((".sh", ".py", ".bash", ".zsh")):
        return True
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except Exception:
        return False


def classify_command(command, args=None):
    """Классифицировать executable+args MCP-команды по риску окна сейфа.

    Возврат: ('critical'|'ok'|'not-op', причина).
    - basename == 'op'      → голый op-run (виновник TCC-класса) → critical
    - basename == 'op-sa'   → headless-обёртка → ok
    - иной скрипт-command, который сам зовёт `op` → guarded? читаем тело
    - op СПРЯТАН в args generic-обёртки (`bash -c "op run …"`, npx-цепочка) →
      critical/ok по наличию гарда в args (основная реальная форма: MCP заводят
      через npx/bash/sh, а не голым `command:op`).
    - всё прочее → not-op (мимо нашего класса)

    ЗАМЕТКА о глубине: command-скрипт резолвится на 1 хоп (тело + маркеры), а
    launchd-скан (_chain_texts) ходит на depth=2 — асимметрия сознательная:
    MCP-обёртка обычно однослойна; редкий двухступенчатый wrapper недо-резолвится
    (документированный false-positive-риск, не тихий).
    """
    base = _basename(command)
    if base == "op":
        return "critical", "прямой `command: op` без обёртки"
    if base == "op-sa":
        return "ok", "через op-sa"
    # обёртка-скрипт как command? ТОЛЬКО текстовые скрипты — бинарь не грепаем
    if command and os.path.exists(command) and _is_text_script(command):
        body = common.strip_comments(_read(command))
        if common.invokes(body, "op"):
            return ("ok", f"обёртка {base} гардит токен") if script_guarded(command) \
                else ("critical", f"обёртка {base} зовёт `op` без гарда токена")
    # op спрятан в args generic-обёртки: `command:bash args:["-c","op run …"]`.
    # common.invokes() тут НЕ годится — `op` внутри `-c …` не в командной позиции
    # его boundary-набора. Токенизируем args и ищем `op`/`.../op` как отдельный
    # токен; op-sa/гард-маркер → безопасно (проверяем, чтобы не дать ложный critical).
    joined = " ".join(str(a) for a in (args or []))
    toks = re.split(r"""[\s;|&()"']+""", joined)
    has_op = any(t == "op" or t.endswith("/op") for t in toks)
    has_guard = (any(t == "op-sa" or t.endswith("/op-sa") for t in toks)
                 or any(m in joined for m in GUARD_MARKERS))
    if has_op and not has_guard:
        return "critical", "op в args generic-обёртки без гарда токена"
    if has_op or has_guard:
        return "ok", "op в args через op-sa/гард"
    return "not-op", "не op-вызыватель"


# ---------- 1. MCP-конфиги ----------
def _iter_mcp_servers(obj):
    """Рекурсивно выдать (server_name, entry) из любого mcpServers-словаря."""
    if isinstance(obj, dict):
        srv = obj.get("mcpServers")
        if isinstance(srv, dict):
            for name, entry in srv.items():
                if isinstance(entry, dict):
                    yield name, entry
        for v in obj.values():
            yield from _iter_mcp_servers(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _iter_mcp_servers(v)


def _mcp_config_paths():
    paths = [CLAUDE_JSON]
    # project-scoped .mcp.json (best-effort, неглубоко)
    for pat in (os.path.join(common.HOME, ".mcp.json"),
                os.path.join(common.HOME, "dev", "*", ".mcp.json")):
        paths.extend(glob.glob(pat))
    return [p for p in dict.fromkeys(paths) if os.path.exists(p)]


def scan_mcp_configs():
    findings = []
    seen = set()
    for path in _mcp_config_paths():
        try:
            data = json.loads(_read(path))
        except Exception:
            # НЕ тихий пропуск: WARNING виден в выводе + main() пометит скан НЕПОЛНЫМ,
            # чтобы битый конфиг не читался как «чисто» (false-clean = худшее для аудита).
            findings.append(VFinding("WARNING", "mcp-config", _rel(path),
                                     "не удалось распарсить JSON — MCP-развёртка ЭТОГО файла "
                                     "пропущена (развёртка неполна)"))
            continue
        for name, entry in _iter_mcp_servers(data):
            verdict, why = classify_command(entry.get("command", ""), entry.get("args"))
            if verdict == "not-op":
                continue
            # dedup по (path, name): одноимённый critical-сервер в РАЗНЫХ конфигах —
            # разные находки (иначе второй файл тихо терялся).
            key = (path, name, verdict)
            if key in seen:
                continue
            seen.add(key)
            if verdict == "critical":
                findings.append(VFinding(
                    "CRITICAL", "mcp-config", f"{_rel(path)} → mcpServers.{name}",
                    f"MCP-сервер зовёт op небезопасно ({why}) → под GUI-Claude без "
                    f"SA-токена откроет окно сейфа на каждый (ре)старт",
                    fix="command → ~/.claude/bin/op-sa (тянет SA-токен из Keychain, "
                        "biometric=false); credential-операции — через skill `secrets`"))
    return findings


# ---------- 2. headless launchd-цепочки глубже depth-1 ----------
_CHILD_RX = re.compile(r'([\w./~$-]+\.(?:sh|py))\b')


def _resolve_child(tok, base_dir):
    t = (tok.replace("$HOME", common.HOME).replace("${HOME}", common.HOME)
            .replace("$DIR", base_dir).replace("${DIR}", base_dir))
    if t.startswith("~"):
        t = common.HOME + t[1:]
    if not t.startswith("/"):
        t = os.path.join(base_dir, t)
    return t if os.path.exists(t) else None


def _chain_texts(script, max_depth=2):
    """Собрать (script + sourced + вызываемые дочерние .sh/.py) до max_depth.

    Возвращает {path: code_text}. Ограничение глубины — backstop от циклов."""
    out, queue, depth = {}, [(script, 0)], None
    while queue:
        path, d = queue.pop(0)
        if not path or path in out or d > max_depth or not os.path.exists(path):
            continue
        txt = _read(path)
        out[path] = common.strip_comments(txt)
        base_dir = os.path.dirname(os.path.abspath(path))
        # source X  +  вызовы дочерних скриптов по пути
        for m in re.finditer(r"(?m)^\s*(?:source|\.)\s+([^\s;#]+)", txt):
            r = _resolve_child(m.group(1), base_dir)
            if r:
                queue.append((r, d + 1))
        for m in _CHILD_RX.finditer(out[path]):
            r = _resolve_child(m.group(1), base_dir)
            if r and r != path:
                queue.append((r, d + 1))
    return out


def scan_launchd_chains():
    import registry
    findings = []
    try:
        data = registry.load()
    except Exception:
        return findings
    for job in data.get("jobs", []):
        if job.get("status") in ("external", "retired"):
            continue
        if job.get("op_safety") == "manually-verified":
            continue
        script = job.get("script")
        if not script or not os.path.exists(script):
            continue
        chain = _chain_texts(script)
        # звено, которое РЕАЛЬНО зовёт op (по коду)
        callers = [p for p, code in chain.items() if common.invokes(code, "op")]
        if not callers:
            continue
        # гард в ЛЮБОМ звене цепочки → токен наследуется вниз → безопасно
        guarded = any(any(mk in code for mk in GUARD_MARKERS)
                      for code in chain.values())
        if guarded:
            continue
        # depth-1 уже ловит doctor op-safety; здесь ценность — когда op в ДОЧЕРНЕМ
        # звене (не в самом script) и вся цепочка без гарда.
        deep = [p for p in callers if os.path.abspath(p) != os.path.abspath(script)]
        if not deep:
            continue
        findings.append(VFinding(
            "CRITICAL", "launchd-chain", job["label"],
            f"джоба через цепочку вызывает `op` в дочернем звене "
            f"({', '.join(_rel(p) for p in deep)}) — ни одно звено не гардит "
            f"SA-токен → риск окна сейфа под launchd",
            fix="в звене-вызывателе: `op run` → ~/.claude/bin/op-sa ИЛИ source "
                "op_env.sh выше по цепочке; либо тег op_safety:manually-verified"))
    return findings


# ---------- сборка ----------
def _rel(path):
    h = common.HOME
    return path.replace(h + "/.claude/", "").replace(h, "~") if path else path


def scan():
    """Полная развёртка. Возвращает список VFinding (несортированный)."""
    return scan_mcp_configs() + scan_launchd_chains()


def render(findings):
    order = {"CRITICAL": 0, "WARNING": 1, "INFO": 2}
    findings = sorted(findings, key=lambda f: (order.get(f.sev, 9), f.area, f.target))
    n_crit = sum(1 for f in findings if f.sev == "CRITICAL")
    n_warn = sum(1 for f in findings if f.sev == "WARNING")
    lines = [common.c("redjob vault-audit", "1") +
             f" — CRITICAL={n_crit} WARNING={n_warn}",
             common.c("  (детерминированная развёртка; секреты не читаются, "
                      "credential-фиксы → skill secrets)", "2"), ""]
    for f in findings:
        head = common.c(f"[{f.sev}]", common.sev_color(f.sev))
        lines.append(f"{head} {common.c(f.area, '1')} · {f.target}")
        lines.append(f"    {f.msg}")
        if f.fix:
            lines.append(common.c(f"    fix: {f.fix}", "2"))
    if not findings:
        lines.append(common.c("✓ незагардированных op-вызывателей не найдено", "1;32"))
    # scrub-on-render — единая точка, как в doctor.render (защита от утечки).
    return scrub.scrub_text("\n".join(lines)), n_crit


def main(argv):
    findings = scan()
    text, n_crit = render(findings)
    print(text)
    # Явный INCOMPLETE-сигнал: если какой-то конфиг не распарсился, «CRITICAL=0»
    # ещё НЕ значит «чисто» — часть развёртки не выполнилась.
    if any(f.area == "mcp-config" and f.sev == "WARNING" for f in findings):
        print(common.c("⚠ развёртка НЕПОЛНА: часть конфигов не распарсилась "
                       "(см. WARNING) — не считать чистым результатом", "1;33"))
    return 1 if n_crit else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
