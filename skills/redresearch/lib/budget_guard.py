#!/usr/bin/env python3
"""
budget_guard.py — атомарный дневной бюджет-гард для платных SourceEngine-движков.

Зачем (finalize-панель 2026-07-20, гейт перед врезкой в research.js): параллельный fan-out
source-hunter'ов зовёт exa/perplexity/tavily одновременно — без общего атомарного счётчика
дневной лимит обходится. Здесь — PESSIMISTIC RESERVE: стоимость резервируется ДО вызова API
(под flock), поэтому конкурентные вызовы видят уже зарезервированное и не перерасходуют.

Атомарность: fcntl.flock (macOS не имеет util-linux `flock`; fcntl работает и на macOS, и на Linux).
Состояние: <dir>/<YYYY-MM-DD>.json = {engine: spent_usd}. Файл на день — авто-ротация (старые игнорятся).
  dir = $REDRESEARCH_BUDGET_DIR или ~/.claude/skills/redresearch/.budget

Лимит на движок: env <ENGINE>_BUDGET_USD_DAY (напр. EXA_BUDGET_USD_DAY) или дефолт из _DEFAULT_CAP.
Оценка стоимости вызова: аргумент est ИЛИ дефолт из _EST.

CLI:
  budget_guard.py reserve <engine> [est_usd]   # exit 0 = зарезервировано (можно звать API);
                                               # exit 3 = превышен лимит (НЕ звать); exit 1 = ошибка (fail-open: звать)
  budget_guard.py spent <engine>               # → потрачено сегодня (usd) в stdout
  budget_guard.py status                       # → JSON {engine: {spent, cap}} по сегодня
  budget_guard.py --self-test                  # exit 0/1
"""
import sys, os, json, fcntl, datetime

_DEFAULT_CAP = {"exa": 1.0, "perplexity": 1.0, "tavily": 1.0}
_EST = {"exa": 0.005, "perplexity": 0.010, "tavily": 0.008}   # консервативная оценка $/вызов
_FALLBACK_CAP = 1.0
_FALLBACK_EST = 0.01


def _dir() -> str:
    d = os.environ.get("REDRESEARCH_BUDGET_DIR") or os.path.expanduser(
        "~/.claude/skills/redresearch/.budget")
    os.makedirs(d, exist_ok=True)
    return d


def _today() -> str:
    return datetime.date.today().isoformat()


def _cap(engine: str) -> float:
    env = os.environ.get("%s_BUDGET_USD_DAY" % engine.upper())
    if env:
        try:
            v = float(env)
            if v > 0:                       # <=0 (мусор/опечатка) → игнорим, берём дефолт
                return v
        except ValueError:
            pass
    return _DEFAULT_CAP.get(engine, _FALLBACK_CAP)


def _est(engine: str, arg) -> float:
    if arg is not None:
        try:
            return float(arg)
        except (TypeError, ValueError):
            pass
    return _EST.get(engine, _FALLBACK_EST)


def _with_lock(fn):
    """Выполнить fn(state_dict)->(result, dirty) под эксклюзивным flock; сохранить если dirty."""
    d = _dir()
    lock_path = os.path.join(d, ".lock")
    state_path = os.path.join(d, _today() + ".json")
    with open(lock_path, "w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            state = {}
            if os.path.exists(state_path):
                try:
                    state = json.load(open(state_path))
                except Exception:
                    state = {}
            result, dirty = fn(state)
            if dirty:
                tmp = state_path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(state, f)
                os.replace(tmp, state_path)   # атомарная запись
            return result
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def reserve(engine: str, est_arg=None) -> int:
    """0 = зарезервировано; 3 = over-budget. Резерв ПЕССИМИСТИЧЕСКИЙ (до вызова API)."""
    est = _est(engine, est_arg)
    cap = _cap(engine)

    def op(state):
        spent = float(state.get(engine, 0) or 0)
        if spent + est > cap:
            return (3, False)
        state[engine] = round(spent + est, 6)
        return (0, True)

    return _with_lock(op)


def spent(engine: str) -> float:
    def op(state):
        return (float(state.get(engine, 0) or 0), False)
    return _with_lock(op)


def status() -> dict:
    def op(state):
        out = {}
        for e in set(list(_DEFAULT_CAP) + list(state)):
            out[e] = {"spent": round(float(state.get(e, 0) or 0), 6), "cap": _cap(e)}
        return (out, False)
    return _with_lock(op)


# ─────────────────────────── self-test ───────────────────────────
def _self_test() -> int:
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp()
    os.environ["REDRESEARCH_BUDGET_DIR"] = tmp
    os.environ["EXA_BUDGET_USD_DAY"] = "0.02"   # маленький лимит для теста

    # 4 резерва по 0.005 = 0.02 (в лимите), 5-й перебор
    codes = [reserve("exa", 0.005) for _ in range(4)]
    if codes != [0, 0, 0, 0]:
        fails.append("first 4 reserves should pass: %r" % codes)
    over = reserve("exa", 0.005)   # 0.025 > 0.02
    if over != 3:
        fails.append("5th reserve should be over-budget(3), got %r" % over)
    s = spent("exa")
    if abs(s - 0.02) > 1e-6:
        fails.append("spent should be 0.02, got %r" % s)

    # другой движок независим
    if reserve("tavily", 0.008) != 0:
        fails.append("tavily independent reserve should pass")

    # over-budget НЕ увеличивает счётчик (не двигаем spent при отказе)
    reserve("exa", 999)
    if abs(spent("exa") - 0.02) > 1e-6:
        fails.append("rejected reserve must not change spent")

    if fails:
        print("✗ budget_guard self-test FAILED:")
        for f in fails:
            print("  -", f)
        return 1
    print("✓ budget_guard self-test passed (5 checks)")
    return 0


def main():
    args = sys.argv[1:]
    if "--self-test" in args:
        sys.exit(_self_test())
    if not args:
        print("usage: budget_guard.py reserve <engine> [est] | spent <engine> | status", file=sys.stderr)
        sys.exit(1)
    cmd = args[0]
    try:
        if cmd == "reserve":
            sys.exit(reserve(args[1], args[2] if len(args) > 2 else None))
        elif cmd == "spent":
            print(spent(args[1]))
            sys.exit(0)
        elif cmd == "status":
            print(json.dumps(status(), ensure_ascii=False))
            sys.exit(0)
        else:
            print("unknown command: %s" % cmd, file=sys.stderr)
            sys.exit(1)
    except IndexError:
        print("missing engine arg", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        # fail-open: ошибка гарда НЕ должна блокировать движок (лучше перерасход, чем немой отказ)
        print("budget_guard error (fail-open): %r" % e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
