#!/usr/bin/env python3
"""redbrain sleep consolidate — M2 адъюдикация (Haiku, Mem0-операторы на файлах).

Берёт func-contradiction подозреваемых из триажа → для каждого собирает, КАКОЙ источник
утверждает какой dst + mtime файла (свежесть ДЕТЕРМИНИРОВАННО через manifest-резолвер) →
Haiku решает оператор (SUPERSEDE/ALIAS/NOOP) СЕМАНТИЧЕСКИ, свежесть НЕ выбирает.
Выход — карточки решений для гейта (TG ✅/❌ → sleep_apply).

--dry (default): собрать + построить промпт, НЕ звать Haiku (0 трат).
--apply: реальный Haiku через op run (ANTHROPIC_API_KEY из 1Password AI-Tokens).
"""
import sys, os, json, sqlite3, subprocess

LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)
import manifest  # noqa

SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
DB = os.path.join(os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
     "~/Library/Application Support/graph-memory")), f"{SCOPE}.db")
FUNCTIONAL_RELS = {"deployed_on", "hosted_on", "has_type", "replaces", "owned_by",
                   "born_in", "former_spouse", "located_in", "runs_on", "primary_domain"}


def _mtime(source_doc):
    r = manifest.resolve(source_doc)
    if r["status"] != "OK":
        return None, r["status"]
    return os.path.getmtime(r["path"]), r["path"]


def gather_contradictions(c):
    """src+relation (functional) → >1 distinct dst, с источником и mtime каждого dst."""
    out = []
    q = """SELECT n.name AS src, e.relation AS rel, n2.name AS dst, e.source_doc AS doc
           FROM edges e JOIN nodes n ON n.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
           WHERE e.relation IN (%s)""" % ",".join("?" * len(FUNCTIONAL_RELS))
    rows = c.execute(q, tuple(FUNCTIONAL_RELS)).fetchall()
    grp = {}
    for src, rel, dst, doc in rows:
        grp.setdefault((src, rel), []).append((dst, doc))
    for (src, rel), items in grp.items():
        dsts = {d for d, _ in items}
        if len(dsts) < 2:
            continue
        variants = []
        for dst, doc in items:
            mt, where = _mtime(doc)
            variants.append({"dst": dst, "source_doc": doc,
                             "mtime": mt, "resolved": where if mt else None,
                             "unresolvable": None if mt else where})
        # детерминированная свежесть: новейший источник среди резолвимых
        dated = [v for v in variants if v["mtime"]]
        newest = max(dated, key=lambda v: v["mtime"])["dst"] if dated else None
        out.append({"src": src, "relation": rel, "variants": variants,
                    "newest_by_mtime": newest})
    return out


def build_prompt(items):
    lines = ["Ты — редактор графа-памяти. По каждому «противоречию» (один субъект имеет",
             "функциональное отношение к НЕСКОЛЬКИМ объектам) реши оператор.",
             "СВЕЖЕСТЬ НЕ ВЫБИРАЙ — она дана детерминированно (newest_by_mtime).",
             "Операторы: SUPERSEDE(старое→новое, если это смена/миграция; победитель=свежий),",
             "ALIAS(если это ОДНО и то же под разными именами, напр. 'github'≈'github.com/x/y'),",
             "NOOP(если объекты легитимно сосуществуют, напр. приложение и в App Store, и в Google Play).",
             "Верни СТРОГО JSON-массив: [{\"src\",\"relation\",\"op\":\"SUPERSEDE|ALIAS|NOOP\",",
             "\"winner|canon\":\"...\",\"drop|alias\":\"...\",\"why\":\"кратко\"}].", "",
             "ВХОД:"]
    for it in items:
        lines.append(json.dumps(it, ensure_ascii=False, default=str))
    return "\n".join(lines)


def run_haiku(prompt):
    """Реальный Haiku через op run (ключ только в env дочернего процесса)."""
    import tempfile
    pf = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
    pf.write(prompt); pf.close()
    ef = tempfile.NamedTemporaryFile("w", suffix=".env", delete=False)
    ef.write("ANTHROPIC_API_KEY=op://AI-Tokens/Anthropic/credential\n"); ef.close()
    # промпт — через temp-файл (argv[1]); ключ — op инъектит в env из env-файла.
    py = ("import os,sys,json,urllib.request;"
          "p=open(sys.argv[1],encoding='utf-8').read();"
          "req=urllib.request.Request('https://api.anthropic.com/v1/messages',"
          "data=json.dumps({'model':'claude-haiku-4-5-20251001','max_tokens':2000,"
          "'messages':[{'role':'user','content':p}]}).encode(),"
          "headers={'x-api-key':os.environ['ANTHROPIC_API_KEY'],"
          "'anthropic-version':'2023-06-01','content-type':'application/json'});"
          "print(json.load(urllib.request.urlopen(req))['content'][0]['text'])")
    try:
        r = subprocess.run(["op", "run", f"--env-file={ef.name}", "--",
                            sys.executable, "-c", py, pf.name],
                           capture_output=True, text=True)
        return r.stdout, r.stderr, r.returncode
    finally:
        os.unlink(pf.name); os.unlink(ef.name)


SLEEP_DIR = os.path.join(os.path.dirname(DB), "sleep")
DISMISSED = os.path.join(SLEEP_DIR, "dismissed.jsonl")   # NOOP-пары: триаж их больше не флажит
DECISIONS = os.path.join(SLEEP_DIR, "decisions.jsonl")   # аудит всех решений


def parse_decisions(text):
    import re
    m = re.search(r"\[\s*\{.*\}\s*\]", text, re.S)
    return json.loads(m.group(0)) if m else []


def _hub_degree(c, name):
    """Сколько РАЗНЫХ субъектов ссылаются на узел `name` (как dst). >1 = общий хаб."""
    r = c.execute("""SELECT COUNT(DISTINCT e.src_id) FROM edges e
                     JOIN nodes n ON n.id=e.dst_id WHERE n.name=?""", (name,)).fetchone()
    return r[0] if r else 0


def verify(decisions, c):
    """Слой «не верь LLM слепо»: ALIAS общего хаба = порча графа → HAZARD."""
    for d in decisions:
        op = d.get("op")
        if op == "ALIAS":
            drop = d.get("alias", "")
            deg = _hub_degree(c, drop)
            if deg > 1:
                d["_risk"] = "HAZARD"
                d["_note"] = f"'{drop}' — общий хаб ({deg} субъектов ссылаются); алиас склеит несвязанное"
            else:
                d["_risk"] = "safe"; d["_note"] = ""
        elif op == "SUPERSEDE":
            d["_risk"] = "review"; d["_note"] = "дроп фактов — убедиться, что миграция, а не потеря"
        else:
            d["_risk"] = "safe"; d["_note"] = "легитимное сосуществование"
    return decisions


def record(decisions):
    os.makedirs(SLEEP_DIR, exist_ok=True)
    with open(DECISIONS, "a", encoding="utf-8") as f:
        for d in decisions:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
    n_dismiss = 0
    with open(DISMISSED, "a", encoding="utf-8") as f:
        for d in decisions:
            if d.get("op") == "NOOP":
                f.write(json.dumps({"src": d["src"], "relation": d["relation"],
                                    "why": d.get("why", "")}, ensure_ascii=False) + "\n")
                n_dismiss += 1
    return n_dismiss


def print_cards(decisions):
    mark = {"HAZARD": "🔴", "review": "🟡", "safe": "🟢"}
    print("\n=== КАРТОЧКИ РЕШЕНИЙ (риск-метки — верификация поверх Haiku) ===")
    for d in decisions:
        r = d.get("_risk", "safe")
        tgt = d.get("winner") or d.get("canon") or ""
        print(f"{mark.get(r,'⚪')} [{d['op']}] {d['src']} {d['relation']} → {tgt}"
              + (f"  (drop: {d.get('drop') or d.get('alias')})" if d.get('drop') or d.get('alias') else ""))
        if d.get("_note"):
            print(f"     ⚠ {d['_note']}")
        print(f"     why: {d.get('why','')}")


def main():
    c = sqlite3.connect(DB)
    if "record" in sys.argv:  # обработать сохранённый вывод Haiku без повторной траты
        src = sys.argv[sys.argv.index("--from") + 1]
        decisions = verify(parse_decisions(open(src, encoding="utf-8").read()), c)
        nd = record(decisions)
        print_cards(decisions)
        print(f"\n▸ записано решений: {len(decisions)}; NOOP→dismissed: {nd} (триаж их больше не флажит)")
        return
    dry = "--apply" not in sys.argv
    items = gather_contradictions(c)
    prompt = build_prompt(items)
    print(f"# consolidate · scope={SCOPE} · противоречий={len(items)} · mode={'DRY' if dry else 'APPLY'}\n")
    if dry:
        print("=== детерминированная свежесть (mtime источников) ===")
        for it in items:
            print(f"\n▸ {it['src']} {it['relation']} → newest={it['newest_by_mtime']}")
            for v in it["variants"]:
                tag = v["resolved"].split("/")[-1] if v["resolved"] else f"[{v['unresolvable']}]"
                import datetime
                mt = datetime.datetime.fromtimestamp(v["mtime"], datetime.timezone.utc).strftime("%Y-%m-%d") if v["mtime"] else "—"
                print(f"    {v['dst']:<28} ← {tag} (mtime {mt})")
        print("\n=== ПРОМПТ, который уйдёт в Haiku (в --apply) ===")
        print(prompt[:1200] + ("\n…(truncated)" if len(prompt) > 1200 else ""))
        print(f"\n[dry] Haiku НЕ вызван. Реальный прогон: --apply (~1-2¢).")
    else:
        out, err, rc = run_haiku(prompt)
        print(out or f"ERROR rc={rc}: {err}")
        decisions = verify(parse_decisions(out), c)
        nd = record(decisions)
        print_cards(decisions)
        print(f"\n▸ записано: {len(decisions)}; NOOP→dismissed: {nd}")


if __name__ == "__main__":
    main()
