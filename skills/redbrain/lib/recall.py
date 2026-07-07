#!/usr/bin/env python3
"""redbrain recall — бесплатный (без LLM) lookup: текст промта → релевантные факты графа.

Ядро UserPromptSubmit-хука авто-recall'а. На промт пользователя дёшево матчит
сущности графа (узлы + алиасы) как whole-word/phrase, ранжирует по специфичности
и связности, достаёт их прямые рёбра + source_doc — «на всякий случай по задаче
уже есть факты». Read-only на граф (SELECT, mode=ro), work-scope ЖЁСТКО зашит
(private fail-closed). Без LLM, без сети.

Дизайн-ревью: plan-panel ultra (2026-07-06) → NEEDS-WORK@0.88 (потолок панели);
фиксы #2/#3/#4/#6/#7/#8/#10 + shadow внесены. Спека: .plan-panel/…redbrain-recall-hook/.

Modes:
  recall.py --hook        stdin = hook JSON {prompt, session_id} → stdout = UserPromptSubmit
                          JSON (hookSpecificOutput.additionalContext) или пусто. ВСЕГДА exit 0.
  recall.py --text        stdin = сырой текст промта → stdout = plain-блок или пусто (debug).
                          [--session <id>] для проверки dedupe.
  recall.py --self-test   встроенные тесты на временной БД.

Тюнинг через env (все опциональны): REDBRAIN_RECALL_{DISABLE,SHADOW,LOG,MIN_LEN,
MIN_PROMPT,MAX_ENTITIES,MAX_FACTS,SCORE_FLOOR,CONCEPT_FLOOR,SESSION_CAP,DEADLINE_MS,
STOP,CACHE}, REDBRAIN_DB_DIR (для тестов).

Инварианты (finalize 2026-07-06): (1) watchdog — ТОЛЬКО main-thread top-level
CLI-процесса (signal.* иначе бросает ValueError; в production хук = процесс на
вызов → всегда main). НЕ импортировать в threaded caller. (2) session-dedupe =
best-effort: TOCTOU-гонка при одинаковом session_id известна и принята (хуки
одной сессии сериализованы рантаймом; повторная инъекция раз в сессию = терпимо).
(3) load_index читает весь граф на вызов — O(nodes+edges); порог демон-миграции
p95>60мс ИЛИ nodes>2000 (SKILL.md). SHADOW снимать только после `--report` + DoD.
"""
import sys, os, re, json, sqlite3, time, signal, threading
from collections import Counter

def _envi(k, d):
    try: return int(os.environ.get(k, d))
    except Exception: return int(d)
def _envf(k, d):
    try: return float(os.environ.get(k, d))
    except Exception: return float(d)

DISABLE        = os.environ.get("REDBRAIN_RECALL_DISABLE") == "1"
SHADOW         = os.environ.get("REDBRAIN_RECALL_SHADOW") == "1"   # считать, НЕ инъектить (замер)
LOG_EVENTS     = os.environ.get("REDBRAIN_RECALL_LOG", "1") != "0"
MIN_WORD_LEN   = _envi("REDBRAIN_RECALL_MIN_LEN", 4)
MIN_PROMPT_LEN = _envi("REDBRAIN_RECALL_MIN_PROMPT", 12)
MAX_ENTITIES   = _envi("REDBRAIN_RECALL_MAX_ENTITIES", 3)
MAX_FACTS      = _envi("REDBRAIN_RECALL_MAX_FACTS", 6)
SCORE_FLOOR    = _envf("REDBRAIN_RECALL_SCORE_FLOOR", 5)
CONCEPT_FLOOR  = _envf("REDBRAIN_RECALL_CONCEPT_FLOOR", 7)   # concept single-word — строже (#2)
SESSION_CAP    = _envi("REDBRAIN_RECALL_SESSION_CAP", 18)    # потолок уник. сущностей/сессия (#8)
DEADLINE_MS    = _envi("REDBRAIN_RECALL_DEADLINE_MS", 150)   # внутренний watchdog (#4)
SQLITE_TIMEOUT = _envf("REDBRAIN_RECALL_SQLITE_TIMEOUT", 0.1)
NGRAM_MAX      = 5
SEEN_TTL_SEC   = 12 * 3600
STALE_CACHE_SEC= 48 * 3600
LOG_MAX        = 512 * 1024

# work-scope ЖЁСТКО зашит: REDBRAIN_SCOPE НЕ читаем для recall-пути вообще (#6) —
# чужой/забытый env не должен переключить хук на private.db и всплыть IP/SSH/
# клиентские суммы/ФИО в КАЖДЫЙ промт. Env-scope — только для ручного query.py.
DB_DIR    = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                               "~/Library/Application Support/graph-memory"))
DB        = os.path.join(DB_DIR, "work.db")
CACHE_DIR = os.path.expanduser(os.environ.get("REDBRAIN_RECALL_CACHE",
                               "~/.cache/redbrain/recall"))
EVENTS_LOG = os.path.join(CACHE_DIR, "events.log")

# ---- present-context (S3 temporal-layers): «что с Игорем сейчас» ----
# Не хранилище — сборка на лету: интервальные факты AS OF now (только субъект-«я»
# и презентные relation) + кэш календаря (пишет отдельный джоб, hook БЕЗ сети) +
# хвост эпизодов. Всё fail-open: нет колонок/кэша/таблиц → блок молча пуст.
PRESENT_SUBJECTS = set(filter(None, os.environ.get(
    "REDBRAIN_PRESENT_SUBJECTS", "игорь,igor").split(",")))
CAL_CACHE   = os.path.expanduser(os.environ.get("REDBRAIN_CAL_CACHE",
                                 "~/.cache/redbrain/calendar.json"))
CAL_TTL_SEC = _envi("REDBRAIN_CAL_TTL", 2 * 3600)   # старше 2ч = stale → пропускаем
PRESENT_MAX_EPISODES = _envi("REDBRAIN_PRESENT_EPISODES", 5)

def _presence_relations():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "golden", "relations-allow.txt")
    try:
        return [ln.strip() for ln in open(p, encoding="utf-8")
                if ln.strip() and not ln.startswith("#")]
    except OSError:
        return []

def present_context(c):
    """→ строка-блок «Сейчас» или "". Бюджет: 2 маленьких SQL + чтение файла (#S3 ≤10мс)."""
    try:
        from datetime import datetime, timezone
        nowdt = datetime.now(timezone.utc)
        nowiso = nowdt.isoformat(timespec="seconds")
        lines = []
        # 1) интервальные факты AS OF now (только про «меня», презентные relation)
        pres = _presence_relations()
        has_temporal = any(r[1] == "status" for r in c.execute("PRAGMA table_info(edges)"))
        if pres and has_temporal:
            ph = ",".join("?" * len(pres))
            sph = ",".join("?" * len(PRESENT_SUBJECTS))
            for s, rel, d, va, ia in c.execute(f"""
                SELECT n1.name, e.relation, n2.name, e.valid_at, e.invalid_at
                FROM edges e JOIN nodes n1 ON n1.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
                WHERE e.status='confirmed' AND e.relation IN ({ph}) AND n1.name IN ({sph})
                  AND e.valid_at <= ? AND (e.invalid_at IS NULL OR ? < e.invalid_at)
                LIMIT 8""", pres + sorted(PRESENT_SUBJECTS) + [nowiso, nowiso]):
                iv = f" [{(va or '')[:10]} → {(ia or 'сейчас')[:10]}]"
                lines.append(f"• {s} —{rel}→ {d}{iv}")
        # 2) календарь сегодня (кэш от джоба; stale/нет → пропуск)
        try:
            if os.path.exists(CAL_CACHE) and time.time() - os.path.getmtime(CAL_CACHE) < CAL_TTL_SEC:
                cal = json.load(open(CAL_CACHE))
                from datetime import timedelta as _td
                loc = nowdt.astimezone().date()
                days = {loc.isoformat(): "", (loc + _td(days=1)).isoformat(): "завтра "}
                evs = [e for e in cal.get("events", [])
                       if (e.get("start") or "")[:10] in days][:5]
                for e in evs:
                    t = e["start"][11:16] if "T" in e.get("start", "") else "весь день"
                    lines.append(f"◦ календарь {days[e['start'][:10]]}{t}: {e.get('summary', '')[:60]}")
        except Exception:
            pass
        # 3) последние эпизоды 24ч (голос/чат — «что происходило»)
        if has_temporal:
            try:
                cutoff = datetime.fromtimestamp(nowdt.timestamp() - 86400, tz=timezone.utc)\
                         .isoformat(timespec="seconds")
                for ts, ch, cont in c.execute(
                        """SELECT ts, channel, content FROM episodes WHERE ts >= ?
                           ORDER BY ts DESC LIMIT ?""", (cutoff, PRESENT_MAX_EPISODES)):
                    lines.append(f"◦ {ts[11:16]} {ch}: {cont[:70]}")
            except sqlite3.OperationalError:
                pass
        if not lines:
            return ""
        return "⏱ Сейчас (present-context, дата " + nowiso[:10] + "):\n" + "\n".join(lines)
    except Exception:
        return ""

# deny-лист generic-узлов (частые слова + аббревиатуры из РЕАЛЬНЫХ данных work.db:
# git/mac/vps/... существуют как узлы и матчатся впустую). Concept-single-word
# дополнительно душит CONCEPT_FLOOR. Ценные короткие (beget/tom1/groq/plaud/
# fable/reve/игорь) намеренно НЕ здесь.
_DEFAULT_STOP = ("api,code,git,ssh,json,url,mcp,hook,test,bash,python,agent,claude,"
    "skill,tool,note,data,text,user,name,type,work,scope,memory,graph,node,edge,"
    "repo,main,plan,mode,flow,run,job,card,gate,queue,judge,audio,video,cart,svg,"
    "ssrf,inn,cpmo,mac,vps,xcode,project,proj,readme,"
    "код,файл,задача,память,граф,хук,тест,агент,скилл,узел,связь,факт,система,"
    "проект,карточка,очередь,гейт,режим,задачи,поле")
DENYLIST = set(filter(None, (os.environ.get("REDBRAIN_RECALL_STOP") or _DEFAULT_STOP).split(",")))

_PUNCT = ".,;:!?()[]{}«»\"'`…—–/\\|"

def norm(s): return " ".join(s.lower().strip().split())

def tokenize(text):
    out = []
    for w in norm(text).split():
        w = w.strip(_PUNCT)
        if w: out.append(w)
    return out

def ngrams(toks, nmax=NGRAM_MAX):
    hi = min(nmax, len(toks))
    for n in range(1, hi + 1):
        for i in range(len(toks) - n + 1):
            yield " ".join(toks[i:i + n])

# ---- internal deadline watchdog (#4) ----
class _Deadline(Exception): pass
def _alarm(_s, _f): raise _Deadline()
def _arm():
    # watchdog только в main-thread top-level процесса (иначе signal.* → ValueError;
    # инвариант (1)). Явная проверка вместо тихого проглатывания ValueError.
    try:
        if (DEADLINE_MS > 0 and hasattr(signal, "setitimer")
                and threading.current_thread() is threading.main_thread()):
            signal.signal(signal.SIGALRM, _alarm)
            signal.setitimer(signal.ITIMER_REAL, DEADLINE_MS / 1000.0)
    except Exception: pass
def _disarm():
    try:
        if hasattr(signal, "setitimer"):
            signal.setitimer(signal.ITIMER_REAL, 0)
    except Exception: pass

# ---- index / matching ----
def load_index(c):
    """→ (forms: surface→canonical_name, by_name: name→{ids,types,degree}).
    Группировка по ИМЕНИ (#10): nodes.name НЕ уникально — один name живёт в N
    типах; рёбра тянем по всем node_id этого имени (паритет с query.resolve())."""
    by_name = {}
    for nid, name, typ in c.execute("SELECT id, name, type FROM nodes"):
        e = by_name.setdefault(name, {"ids": [], "types": set(), "degree": 0})
        e["ids"].append(nid); e["types"].add(typ)
    deg = Counter()
    for (s,) in c.execute("SELECT src_id FROM edges"): deg[s] += 1
    for (d,) in c.execute("SELECT dst_id FROM edges"): deg[d] += 1
    id2name = {}
    for name, e in by_name.items():
        e["degree"] = sum(deg.get(i, 0) for i in e["ids"])
        for i in e["ids"]: id2name[i] = name
    forms = {name: name for name in by_name}
    for alias, nid in c.execute("SELECT alias, node_id FROM aliases"):
        nm = id2name.get(nid)
        if nm: forms.setdefault(alias, nm)   # не перетираем прямое имя узла
    return forms, by_name

def match(text, forms, by_name):
    """→ [(name, score)] по убыванию. Type-aware floor: concept single-word строже (#2)."""
    hits = {}
    for gram in ngrams(tokenize(text)):
        name = forms.get(gram)
        if not name: continue
        info = by_name.get(name)
        if not info: continue
        words = gram.split()
        single = len(words) == 1
        if single and (len(gram) < MIN_WORD_LEN or gram in DENYLIST):
            continue
        score = len(gram) + 3 * (len(words) - 1) + min(info["degree"], 20) * 0.3
        floor = CONCEPT_FLOOR if (single and info["types"] <= {"concept"}) else SCORE_FLOOR
        if score < floor: continue
        if name not in hits or score > hits[name]:
            hits[name] = score
    # subsumption (#6): дропнуть короткую форму, если её надмножество по словам уже
    # в hits ('redcontrol' при 'redcontrol autopilot') — не съедать слот MAX_ENTITIES
    if len(hits) > 1:
        hits = {a: sa for a, sa in hits.items()
                if not any(b != a and set(a.split()) < set(b.split()) and hits[b] >= sa
                           for b in hits)}
    return sorted(hits.items(), key=lambda kv: kv[1], reverse=True)

def facts_for(c, names, by_name):
    ids = []
    for nm in names: ids += by_name[nm]["ids"]
    if not ids: return []
    ph = ",".join("?" * len(ids))
    # S3: кандидаты/инвалидированные НЕ инъектируются (контракт Слоя 2:
    # неподтверждённый факт не влияет на поведение). Fail-open на до-v3 базе.
    sf = (" AND e.status='confirmed'"
          if any(r[1] == "status" for r in c.execute("PRAGMA table_info(edges)")) else "")
    rows = c.execute(f"""
        SELECT n1.name, e.relation, n2.name, e.source_doc, e.weight
        FROM edges e JOIN nodes n1 ON n1.id = e.src_id JOIN nodes n2 ON n2.id = e.dst_id
        WHERE (e.src_id IN ({ph}) OR e.dst_id IN ({ph})){sf}
        ORDER BY e.weight DESC""", ids + ids).fetchall()
    seen, facts = set(), []
    for src, rel, dst, doc, _w in rows:
        k = (src, rel, dst, doc)            # дедуп по (src,rel,dst,doc) (#10)
        if k in seen: continue
        seen.add(k); facts.append((src, rel, dst, doc))
        if len(facts) >= MAX_FACTS: break
    return facts

def format_block(names, facts):
    lines = [f"🧠 RedBrain — по задаче в памяти уже есть связанные факты (сущности: {', '.join(names)}):"]
    docs = set()
    for src, rel, dst, doc in facts:
        lines.append(f"• {src} —{rel}→ {dst}" + (f"  ({doc})" if doc else ""))
        if doc: docs.add(doc)
    if docs:
        lines.append(f"↳ полный контекст — открой memory-файл(ы): {', '.join(sorted(docs))}")
    lines.append("(граф — указатель; проигнорируй, если к задаче нерелевантно.)")
    return "\n".join(lines)

# ---- session dedupe (best-effort; #7) ----
def _cache_ready():
    os.makedirs(CACHE_DIR, exist_ok=True)
    try: os.chmod(CACHE_DIR, 0o700)
    except Exception: pass

def _cache_path(session_id):
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session_id)[:80]
    return os.path.join(CACHE_DIR, "seen-" + safe)

def load_seen(session_id):
    if not session_id: return set()
    try:
        p = _cache_path(session_id)
        if os.path.exists(p) and time.time() - os.path.getmtime(p) < SEEN_TTL_SEC:
            return set(json.load(open(p)))
    except Exception: pass
    return set()

def save_seen(session_id, seen):
    if not session_id: return
    try:
        _cache_ready()
        p = _cache_path(session_id)
        tmp = p + ".tmp"
        json.dump(sorted(seen), open(tmp, "w"))
        os.replace(tmp, p)                 # атомарно (#7)
        try: os.chmod(p, 0o600)            # приватность seen-файла (#4)
        except Exception: pass
        _sweep_cache()
    except Exception: pass

def _sweep_cache():
    """Чистка протухших seen (#7) НЕ чаще раза в час (маркер) — иначе per-call
    listdir на каждый промт = лишняя латентность (finalize: было +138мс/вызов)."""
    try:
        marker = os.path.join(CACHE_DIR, ".last-sweep")
        if os.path.exists(marker) and time.time() - os.path.getmtime(marker) < 3600:
            return
        open(marker, "w").close()                  # следующий свип не раньше чем через час
        cutoff = time.time() - STALE_CACHE_SEC
        for fn in os.listdir(CACHE_DIR):
            if not fn.startswith("seen-"): continue
            p = os.path.join(CACHE_DIR, fn)
            if os.path.isfile(p) and os.path.getmtime(p) < cutoff:
                os.unlink(p)
    except Exception: pass

# ---- observability (#3): append-only, БЕЗ текста промта/фактов, с ротацией ----
def _log(session_id, text, matched, nfacts, outcome, t0):
    if not LOG_EVENTS: return
    try:
        _cache_ready()
        if os.path.exists(EVENTS_LOG) and os.path.getsize(EVENTS_LOG) > LOG_MAX:
            os.replace(EVENTS_LOG, EVENTS_LOG + ".1")   # 1 бэкап, дальше — перезапись
        rec = {"ts": int(time.time()), "sid": (session_id or "")[:40],
               "plen": len(text or ""), "matched": matched, "facts": nfacts,
               "ms": int((time.time() - t0) * 1000), "outcome": outcome,
               "shadow": bool(SHADOW)}
        with open(EVENTS_LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        try: os.chmod(EVENTS_LOG, 0o600)   # приватность лога (#4)
        except Exception: pass
    except Exception: pass

def recall(text, session_id=None):
    """→ (block, [names]). Пусто если нечего инъектить. Никогда не бросает. Логирует всегда."""
    t0 = time.time()
    if DISABLE:
        _log(session_id, text, [], 0, "disabled", t0); return "", []
    t = (text or "").strip()
    if len(t) < MIN_PROMPT_LEN or t.startswith("/"):
        _log(session_id, text, [], 0, "skip", t0); return "", []
    if not os.path.exists(DB):
        _log(session_id, text, [], 0, "error", t0); return "", []
    _arm()
    c = None
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=SQLITE_TIMEOUT)
        forms, by_name = load_index(c)
        ranked = match(text, forms, by_name)
        if not ranked:
            _log(session_id, text, [], 0, "miss", t0); return "", []
        seen = load_seen(session_id)
        if len(seen) >= SESSION_CAP:                       # #8 session cap
            _log(session_id, text, [n for n, _ in ranked[:MAX_ENTITIES]], 0, "throttled", t0)
            return "", []
        fresh = [n for n, _ in ranked if n not in seen][:MAX_ENTITIES]
        if not fresh:
            _log(session_id, text, [], 0, "dedup", t0); return "", []
        facts = facts_for(c, fresh, by_name)
        if not facts:
            _log(session_id, text, fresh, 0, "miss", t0); return "", []
        block = format_block(fresh, facts)
        pres = present_context(c)                           # S3: второй блок «Сейчас»
        if pres:
            block = block + "\n\n" + pres
        if SHADOW:                                          # #1b: замер без инъекции
            _log(session_id, text, fresh, len(facts), "shadow", t0); return "", []
        save_seen(session_id, seen | set(fresh))
        _log(session_id, text, fresh, len(facts), "hit", t0)
        return block, fresh
    except _Deadline:
        _log(session_id, text, [], 0, "timeout", t0); return "", []
    except Exception:
        _log(session_id, text, [], 0, "error", t0); return "", []
    finally:
        _disarm()
        try:
            if c: c.close()
        except Exception: pass

# ---------------- CLI ----------------
def _run_hook():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        text = data.get("prompt") or data.get("user_prompt") or ""
        sid = data.get("session_id") or data.get("sessionId") or ""
        block, _ = recall(text, sid)
        if block:
            sys.stdout.write(json.dumps({"hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit", "additionalContext": block}},
                ensure_ascii=False))
    except Exception:
        pass
    return 0

def _run_text(args):
    try: text = sys.stdin.read()
    except Exception: text = ""
    sid = args[args.index("--session") + 1] if "--session" in args else None
    block, _ = recall(text, sid)
    if block: print(block)
    return 0

def run_self_test():
    import tempfile, shutil
    global DB, DB_DIR, CACHE_DIR, EVENTS_LOG, SHADOW
    tmp = tempfile.mkdtemp(prefix="recall-test-")
    DB_DIR, DB = tmp, os.path.join(tmp, "work.db")
    CACHE_DIR = os.path.join(tmp, "cache"); EVENTS_LOG = os.path.join(CACHE_DIR, "events.log")
    c = sqlite3.connect(DB)
    c.executescript("""
      CREATE TABLE nodes(id TEXT PRIMARY KEY,type TEXT,name TEXT,created_at TEXT,updated_at TEXT);
      CREATE TABLE edges(id TEXT PRIMARY KEY,src_id TEXT,dst_id TEXT,relation TEXT,weight REAL,
                         source_doc TEXT,run_id TEXT,created_at TEXT);
      CREATE TABLE aliases(alias TEXT PRIMARY KEY,node_id TEXT);""")
    nd = lambda i, n, t="tool": c.execute("INSERT INTO nodes VALUES(?,?,?,?,?)", (i, t, n, "", ""))
    eg = lambda i, s, d, r, doc: c.execute("INSERT INTO edges VALUES(?,?,?,?,?,?,?,?)",
                                           (i, s, d, r, 1.0, doc, "run", ""))
    nd("n_plaud", "plaud", "tool"); nd("n_mia", "mia", "concept"); nd("n_tr", "yandex tracker", "tool")
    nd("n_auto", "redcontrol autopilot f2", "project"); nd("n_api", "api", "concept")
    nd("n_audio", "audio", "concept")                          # concept single-word → шум
    nd("n_rl1", "redloft", "project"); nd("n_rl2", "redloft", "skill")   # #10 неоднозначное имя
    nd("n_proj", "project", "memory-type"); nd("n_rc", "redcontrol", "project")  # #1 memtype / #6 subsumption
    eg("e1", "n_plaud", "n_mia", "feeds", "plaud-autopilot-stitch.md")
    eg("e2", "n_mia", "n_tr", "produces", "plaud-autopilot-stitch.md")
    eg("e3", "n_auto", "n_plaud", "related_to", "redcontrol-autopilot-f2.md")
    eg("e4", "n_api", "n_tr", "related_to", "misc.md")
    eg("e5", "n_rl1", "n_tr", "uses", "redloft-a.md")          # ребро на node_id #1
    eg("e6", "n_rl2", "n_plaud", "part_of", "redloft-b.md")    # ребро на node_id #2
    for _k, _s in enumerate(["n_plaud", "n_mia", "n_auto", "n_rl1", "n_rl2", "n_tr"]):
        eg(f"ep{_k}", _s, "n_proj", "has_type", "x.md")        # 'project' высокая степень
    eg("e_rc", "n_rc", "n_tr", "uses", "rc.md")
    c.execute("INSERT INTO aliases VALUES(?,?)", ("плауд", "n_plaud"))
    c.commit(); c.close()

    checks = []
    def ck(name, cond): checks.append((name, bool(cond)))

    b, ids = recall("что там по plaud и mia сейчас творится в проекте", None)
    ck("latin-match-plaud", "plaud" in ids)
    ck("facts-rendered", "feeds" in b and "plaud-autopilot-stitch.md" in b)

    b, ids = recall("как поживает плауд в последнее время интересно", None)
    ck("cyrillic-alias-plaud", "plaud" in ids)

    b, ids = recall("нужно немного поправить api ближе к вечеру сегодня", None)
    ck("stopword-api-skip", "api" not in ids and b == "")

    b, ids = recall("надо записать audio дорожку подлиннее сегодня вечером", None)
    ck("concept-singleword-skip", "audio" not in ids)

    b, ids = recall("ок", None); ck("short-prompt-skip", b == "")
    b, ids = recall("/finalize сейчас прогоним по диффу изменений", None); ck("slash-skip", b == "")
    b, ids = recall("сегодня хорошая солнечная погода на улице совсем", None); ck("no-match-empty", b == "")

    b, ids = recall("глянь redcontrol autopilot f2 как там дела продвигаются", None)
    ck("multiword-match", "redcontrol autopilot f2" in ids)

    b, ids = recall("какой project мы сейчас делаем и что по нему вообще", None)
    ck("memtype-project-denylisted", "project" not in ids)

    b, ids = recall("глянь redcontrol autopilot f2 и redcontrol заодно разбор", None)
    ck("subsumption-drops-short", "redcontrol autopilot f2" in ids and "redcontrol" not in ids)

    # #10 неоднозначное имя redloft: одна сущность, рёбра из ОБОИХ node_id
    b, ids = recall("что там сейчас творится по redloft вообще интересно", None)
    ck("ambiguous-one-entity", ids.count("redloft") == 1)
    ck("ambiguous-both-edges", "redloft-a.md" in b and "redloft-b.md" in b)

    sid = "sess-1"
    b1, i1 = recall("что там сейчас по plaud происходит вообще", sid)
    b2, i2 = recall("ещё раз про plaud расскажи пожалуйста подробнее", sid)
    ck("dedupe-first-hits", "plaud" in i1)
    ck("dedupe-second-skips", "plaud" not in i2)

    # #6 negative: чужой REDBRAIN_SCOPE=private в env НЕ переключает нас с work.db
    os.environ["REDBRAIN_SCOPE"] = "private"
    b, ids = recall("что там по plaud стыковке автопилота сегодня", None)
    ck("ignores-REDBRAIN_SCOPE-env", "plaud" in ids and DB.endswith("work.db"))
    del os.environ["REDBRAIN_SCOPE"]

    # #8 session cap: набитый seen → throttle
    big = "sess-big"
    save_seen(big, {f"e{i}" for i in range(SESSION_CAP)})
    b, ids = recall("что там по plaud автопилоту сейчас происходит вообще", big)
    ck("session-cap-throttle", b == "")

    # #1b shadow: считает, но НЕ инъектит
    SHADOW = True
    b, ids = recall("что там по plaud автопилоту происходит сегодня вечером", None)
    ck("shadow-no-inject", b == "" and ids == [])
    SHADOW = False

    # #3 observability: events.log пишется и различает outcome
    ck("events-log-written", os.path.exists(EVENTS_LOG))
    try:
        outs = {json.loads(l)["outcome"] for l in open(EVENTS_LOG)}
    except Exception:
        outs = set()
    ck("events-log-outcomes", {"hit", "miss", "skip"} & outs == {"hit", "miss", "skip"} or
       ({"hit"} <= outs and "miss" in outs))

    t0 = time.time()
    recall("plaud mia yandex tracker redcontrol autopilot f2 полный разбор задачи", None)
    ck("latency-smoke-<0.5s", (time.time() - t0) < 0.5)

    okn = sum(1 for _, v in checks if v)
    for nm, v in checks: print(f"  [{'ok' if v else 'FAIL'}] {nm}")
    print(f"recall.py self-test: {okn}/{len(checks)}")
    shutil.rmtree(tmp, ignore_errors=True)
    return 0 if okn == len(checks) else 1

def _run_report():
    """Агрегатор events.log — операционное здоровье shadow/live-фазы."""
    events = []
    for p in (EVENTS_LOG, EVENTS_LOG + ".1"):
        if os.path.exists(p):
            for line in open(p):
                line = line.strip()
                if not line: continue
                try: events.append(json.loads(line))
                except Exception: pass
    if not events:
        print("events.log пуст — хук ещё не срабатывал (или LOG выключен)."); return 0
    oc = Counter(e.get("outcome", "?") for e in events)
    real = [e for e in events if e.get("sid")]            # с session_id = реальные срабатывания хука
    lat = sorted(e.get("ms", 0) for e in events)
    pct = lambda q: lat[min(len(lat) - 1, int(len(lat) * q))] if lat else 0
    ent = Counter()
    for e in events:
        for m in e.get("matched", []): ent[m] += 1
    total = len(events)
    injish = oc.get("hit", 0) + oc.get("shadow", 0)       # инъектнул бы (в shadow — «бы»)
    considered = total - oc.get("skip", 0) - oc.get("disabled", 0)
    shadow_evt = sum(1 for e in events if e.get("shadow"))
    print(f"events: {total}  (реальных срабатываний хука с sid: {len(real)}; в shadow: {shadow_evt})")
    print(f"outcome: {dict(oc)}")
    print(f"would-inject rate (hit+shadow / рассмотренных): "
          f"{(injish/considered*100 if considered else 0):.0f}%  [{injish}/{considered}]")
    print(f"latency ms: p50={pct(0.5)} p95={pct(0.95)} max={lat[-1] if lat else 0}")
    err = oc.get("error", 0) + oc.get("timeout", 0)
    print(f"health: error+timeout = {err}/{total}"
          + ("  ⚠️ есть поломки — проверь" if err else "  ✓"))
    print("top matched entities:")
    for name, cnt in ent.most_common(15):
        print(f"  {cnt:3d}  {name}")
    return 0

def _run_present():
    """Standalone-просмотр present-context (S3): отладка/тесты без полного recall."""
    try:
        c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=SQLITE_TIMEOUT)
        print(present_context(c) or "(present-context пуст)")
        c.close()
    except Exception as e:
        print(f"(error: {e})")
    return 0

def main():
    args = sys.argv[1:]
    if "--self-test" in args: return run_self_test()
    if "--report" in args: return _run_report()
    if "--present" in args: return _run_present()
    if "--hook" in args: return _run_hook()
    return _run_text(args)

if __name__ == "__main__":
    sys.exit(main())
