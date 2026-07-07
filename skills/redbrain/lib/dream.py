#!/usr/bin/env python3
"""redbrain sleep dream — M4 REM-фаза «Сна». Генеративная, НЕ гигиена.

Fable синтезирует из графа (work+private) относительно манифеста/вектора Игоря:
связки (неочевидные соединения далёких узлов) · паттерны · прогнозы/идеи · сверку с
манифестом (дрейф/сходимость). Каждый пункт ОБЯЗАН цитировать факт (анти-конфабуляция,
как redresearch). Тон — НАБЛЮДЕНИЯ, не директивы (метод архитектора: «поле подсказывает»).

Выход — дневник снов (private). Читает оба скоупа (личный вектор × рабочая активность —
там и живут лучшие связки), но ВЫХОД и манифест — только private.

--dry (default): собрать контекст + промпт, НЕ звать Fable (0 трат).
--apply: Fable (claude-fable-5) через op run (ключ из 1Password).
"""
import sys, os, json, sqlite3, subprocess

CC = os.environ.get("CLAUDECORE_PATH", "")
SELF = os.path.join(CC, "личные данные ", "self")
DBDIR = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
        "~/Library/Application Support/graph-memory"))
SLEEP_DIR = os.path.join(DBDIR, "sleep")


def load_vector():
    """Манифест + профиль вектора — якорь REM."""
    out = []
    for fn in ("manifest.md", "vector-profile.md"):
        p = os.path.join(SELF, fn)
        if os.path.isfile(p):
            out.append(f"### {fn}\n" + open(p, encoding="utf-8").read())
    return "\n\n".join(out)


# REM про вектор/смыслы, НЕ про инфру и PII. Скраб ПЕРЕД LLM (протокол секретов):
# паспорт/ИНН/ОГРНИП/IP не должны уйти в Fable-промпт (это и шум, и утечка).
# Паттерн вынесен в pii.py (S1 temporal-layers): тот же скраб на входе episodes.
from pii import PII_RE
# Инфра-узлы (сервера/SSH/домены/IP) — вырезаем из REM целиком: сенситив + не про вектор.
INFRA_TYPES = {"server", "ssh_alias", "fqdn", "ipv6", "ipv4", "datacenter", "ip"}
# Идентификационный «досье»-слой: REM про вектор, не про паспортные данные → срезаем отношения.
PII_RELATIONS = {"has_full_name", "has_inn", "has_passport", "has_snils", "has_phone",
                 "has_email", "has_address", "has_ogrnip", "has_bank_account",
                 "born_date", "has_bik", "has_account",
                 # денежные суммы / условия сделок — не для рефлексии, только риск-утечка
                 "costs", "price", "rate", "hourly_rate", "contract_sum", "paid_fact",
                 "revenue", "salary", "budget", "deal_value", "amount", "earns_amount"}


def _scrub(s):
    return PII_RE.sub("[PII]", s)


def graph_digest(scope, top_n=40, edges_per=6, exclude_types=frozenset()):
    """Компактный дайджест: топ-узлы по степени + исходящие связи. С фильтром типов и скрабом PII."""
    db = os.path.join(DBDIR, f"{scope}.db")
    if not os.path.exists(db):
        return f"(нет {scope}.db)"
    c = sqlite3.connect(db)
    top = c.execute("""
        SELECT n.name, n.type, COUNT(*) deg FROM nodes n
        JOIN edges e ON n.id IN (e.src_id, e.dst_id)
        GROUP BY n.id ORDER BY deg DESC LIMIT ?""", (top_n * 2,)).fetchall()
    lines = []
    for name, typ, deg in top:
        if typ in exclude_types:
            continue
        outs = c.execute("""
            SELECT e.relation, n2.name, n2.type FROM edges e
            JOIN nodes n1 ON n1.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
            WHERE n1.name=? LIMIT ?""", (name, edges_per * 2)).fetchall()
        rels = "; ".join(f"{r}→{d}" for r, d, dt in outs
                         if dt not in exclude_types and r not in PII_RELATIONS)
        line = f"- {name} ({typ}): {rels}" if rels else f"- {name} ({typ})"
        lines.append(_scrub(line))
        if len(lines) >= top_n:
            break
    return "\n".join(lines)


def build_prompt(vector, work_digest, private_digest):
    return f"""Ты — REM-фаза «Сна» персональной граф-памяти Игоря. Ночью ты не чистишь —
ты СВЯЗЫВАЕШЬ: ищешь неочевидное в его памяти относительно его вектора.

ЕГО ВЕКТОР (манифест + профиль — это ЯКОРЬ, по нему сверяй сходимость/дрейф):
{vector}

ФАКТЫ ПАМЯТИ — РАБОЧИЙ КОНТУР (проекты, инструменты, активность):
{work_digest}

ФАКТЫ ПАМЯТИ — ЛИЧНЫЙ КОНТУР:
{private_digest}

ЗАДАЧА. Верни JSON:
{{"связки":[...], "паттерны":[...], "прогнозы_идеи":[...], "сверка_с_манифестом":{{"сходимость":[...],"дрейф":[...]}}}}
Правила:
- КАЖДЫЙ пункт — объект {{"текст": "...", "цитата": ["факт1","факт2"], "уверенность": "высокая|средняя|низкая"}}.
- «связки» — соединяй ДАЛЁКИЕ узлы (напр. навык из проекта A + потребность из B → возможность).
- Ранг по релевантности вектору × неочевидности. Максимум 4 связки, 3 паттерна, 3 идеи.
- ТОН — наблюдения, НЕ команды («я заметил…», не «ты должен»). Метод архитектора: поле подсказывает.
- НИКАКОЙ конфабуляции: нет факта в памяти — не выдумывай. Цитата обязательна.
- Русский. СТРОГО валидный JSON, без обрамляющего текста."""


_FABLE_SCRIPT = '''import os,sys,json,urllib.request,urllib.error
p=open(sys.argv[1],encoding="utf-8").read()
req=urllib.request.Request("https://api.anthropic.com/v1/messages",
  data=json.dumps({"model":os.environ.get("DREAM_MODEL","claude-fable-5"),
  "max_tokens":8000,"messages":[{"role":"user","content":p}]}).encode(),
  headers={"x-api-key":os.environ["ANTHROPIC_API_KEY"],
  "anthropic-version":"2023-06-01","content-type":"application/json"})
try:
    r=json.load(urllib.request.urlopen(req))
except urllib.error.HTTPError as e:
    print("HTTP",e.code,e.read().decode("utf-8","replace")); sys.exit(2)
# берём ТЕКСТОВЫЕ блоки (Fable может вернуть thinking-блок первым)
t="".join(b.get("text","") for b in r.get("content",[]) if b.get("type")=="text")
print(t or json.dumps(r,ensure_ascii=False))
'''


def run_fable(prompt, model=None):
    import tempfile
    pf = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
    pf.write(prompt); pf.close()
    sf = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
    sf.write(_FABLE_SCRIPT); sf.close()
    ef = tempfile.NamedTemporaryFile("w", suffix=".env", delete=False)
    ef.write("ANTHROPIC_API_KEY=op://AI-Tokens/Anthropic/credential\n"); ef.close()
    env = dict(os.environ)
    if model:
        env["DREAM_MODEL"] = model
    try:
        r = subprocess.run(["op", "run", f"--env-file={ef.name}", "--",
                            sys.executable, sf.name, pf.name],
                           capture_output=True, text=True, env=env)
        return r.stdout, r.stderr, r.returncode
    finally:
        for f in (pf.name, sf.name, ef.name):
            os.unlink(f)


def main():
    dry = "--apply" not in sys.argv
    vector = load_vector()
    work_d = graph_digest("work", exclude_types=INFRA_TYPES)
    priv_d = graph_digest("private", exclude_types=INFRA_TYPES)
    prompt = build_prompt(vector, work_d, priv_d)
    print(f"# dream (REM) · mode={'DRY' if dry else 'APPLY'} · vector={len(vector)}ch "
          f"· work-digest={work_d.count(chr(10))+1} строк · private-digest={priv_d.count(chr(10))+1} строк\n")
    if dry:
        print("=== ЛИЧНЫЙ ДАЙДЖЕСТ (private, вход REM) ===")
        print(priv_d[:1200])
        print("\n=== ПРОМПТ Fable (первые 1400 симв.) ===")
        print(prompt[:1400] + "\n…(truncated)")
        print(f"\n[dry] Fable НЕ вызван. Полный сон: --apply (~$0.1–0.3). Промпт целиком: {len(prompt)} симв.")
    else:
        os.makedirs(SLEEP_DIR, exist_ok=True)
        out, err, rc = run_fable(prompt)
        if rc != 0 or not out:
            print(f"ERROR rc={rc}: {err}"); return
        print(out)
        with open(os.path.join(SLEEP_DIR, "last-dream.json"), "w", encoding="utf-8") as f:
            f.write(out)


if __name__ == "__main__":
    main()
