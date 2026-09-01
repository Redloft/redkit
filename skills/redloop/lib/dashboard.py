#!/usr/bin/env python3
"""dashboard.py — карточка прогона redloop для показа в чате (mcp__visualize__show_widget).

Читает ТОЛЬКО факты прогона: contract.json, events.jsonl, вывод detect.sh scan.
Принцип: не досочинять. Нет данных — в карточке «—» с причиной, а не правдоподобная цифра
(память: «нет событий ≠ успех»). Знаменатель обязателен везде, где есть счётчик.

Usage: dashboard.py <run_dir> [--stage S3] > widget.html
"""
import json, os, subprocess, sys, html, datetime

STAGES = [("S1", "разведка"), ("S2", "контракт"), ("S3", "промпт"),
          ("S4", "запуск"), ("S5", "прогон"), ("S6", "разбор")]

def read_events(rd):
    p = os.path.join(rd, "events.jsonl"); out = []
    if os.path.exists(p):
        for ln in open(p):
            ln = ln.strip()
            if ln:
                try: out.append(json.loads(ln))
                except json.JSONDecodeError: pass
    return out

def detectors(rd):
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        r = subprocess.run(["bash", os.path.join(here, "detect.sh"), "scan", rd],
                           capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout or "[]")
    except Exception:
        return []

def esc(s): return html.escape(str(s), quote=True)

def build(rd, stage):
    contract = {}
    cp = os.path.join(rd, "contract.json")
    if os.path.exists(cp):
        try: contract = json.load(open(cp))
        except json.JSONDecodeError: pass
    ev = read_events(rd); det = detectors(rd)

    dod = contract.get("dod") or []
    dod_total = len(dod)
    # ⚠ статус проверки = ПОСЛЕДНЕЕ её событие, а не «когда-либо была зелёной».
    # Иначе проверка, позеленевшая на 3-й итерации и упавшая на 15-й, навсегда остаётся
    # зелёной, и карточка рапортует «прогон завершён» поверх красного прогона.
    # Та же семантика, что у PREMATURE-EXIT в detect.sh — один смысл на двух потребителей.
    last_by_check = {}
    for e in sorted((x for x in ev if x.get("event_type") == "check_result"),
                    key=lambda x: x.get("seq", 0)):
        last_by_check[e["payload"].get("check_id")] = e
    green = {c for c, e in last_by_check.items()
             if e.get("kind") != "blocked" and e["payload"].get("exit_code") == 0}
    blocked = {c for c, e in last_by_check.items() if e.get("kind") == "blocked"}
    red = {c for c, e in last_by_check.items()
           if e.get("kind") != "blocked" and e["payload"].get("exit_code") != 0}
    iters = [e for e in ev if e.get("event_type") == "iter_done"]
    iter_n = len(iters)
    iter_of = (contract.get("budget") or {}).get("max_iters")
    assumptions = len([e for e in ev if e.get("event_type") == "assumption"])
    interventions = len([e for e in ev if e.get("event_type") == "question"
                         and e["payload"].get("allowed") is False]) \
                  + len([e for e in ev if e.get("event_type") == "escalation"])
    infra = len([e for e in ev if e.get("kind") == "infra_failure"])
    neg = len([e for e in ev if e.get("kind") == "negative_verdict"])
    done_ev = [e for e in ev if e.get("event_type") == "run_done"]

    hard = [d for d in det if not d.get("shadow")]
    if done_ev and dod_total and len(green) == dod_total:
        status, tone = "прогон завершён", "success"
    elif done_ev and blocked and not red and (len(green) + len(blocked)) == dod_total:
        # «ждёт владельца» только когда ВСЕ строки DoD разобраны: иначе недоделанная работа
        # маскируется под внешнюю блокировку
        status, tone = "закрыт частично · ждёт владельца", "warning"
    elif hard:
        status, tone = "нужен человек", "danger"
    elif det:
        status, tone = "идёт, есть сигналы", "warning"
    elif ev:
        status, tone = "идёт", "accent"
    else:
        status, tone = "не начат", "muted"

    order = [s[0] for s in STAGES]
    cur = stage if stage in order else ("S5" if ev else "S2")
    ci = order.index(cur)

    def pill(i, code, name):
        if i < ci: bg, fg, bd, ico = "var(--bg-success)", "var(--text-success)", "var(--border-success)", "ti-check"
        elif i == ci: bg, fg, bd, ico = "var(--bg-accent)", "var(--text-accent)", "var(--border-accent)", "ti-player-play"
        else: bg, fg, bd, ico = "transparent", "var(--text-muted)", "var(--border)", "ti-point"
        return (f'<div style="flex:1;min-width:96px;background:{bg};border:1px solid {bd};border-radius:var(--radius);'
                f'padding:8px 10px"><div style="font-family:var(--font-mono);font-size:11px;color:{fg}">'
                f'<i class="ti {ico}" aria-hidden="true"></i> {code}</div>'
                f'<div style="font-size:13px;color:{fg};margin-top:2px">{name}</div></div>')

    def kpi(label, value, sub=""):
        return (f'<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:12px 14px">'
                f'<div style="font-size:11px;color:var(--text-muted)">{label}</div>'
                f'<div style="font-size:20px;font-weight:500;color:var(--text-primary);'
                f'font-family:var(--font-mono);margin-top:2px">{value}</div>'
                f'<div style="font-size:12px;color:var(--text-secondary)">{sub}</div></div>')

    pct = int(100 * len(green) / dod_total) if dod_total else 0
    tone_fg = {"success": "var(--text-success)", "danger": "var(--text-danger)",
               "warning": "var(--text-warning)", "accent": "var(--text-accent)",
               "muted": "var(--text-muted)"}[tone]
    tone_bg = {"success": "var(--bg-success)", "danger": "var(--bg-danger)",
               "warning": "var(--bg-warning)", "accent": "var(--bg-accent)",
               "muted": "var(--surface-1)"}[tone]

    checks = []
    for d in dod:
        cid = d.get("id", "?")
        if cid in green: ico, col, note = "ti-circle-check", "var(--text-success)", "зелёная"
        elif cid in blocked: ico, col, note = "ti-lock", "var(--text-warning)", "заблокирована внешним"
        elif cid in red: ico, col, note = "ti-circle-x", "var(--text-danger)", "красная"
        elif not d.get("cmd"): ico, col, note = "ti-user", "var(--text-secondary)", "приёмка человеком"
        else: ico, col, note = "ti-circle-dashed", "var(--text-muted)", "не запускалась"
        cmd = d.get("cmd") or d.get("desc", "")
        checks.append(
            f'<div style="display:flex;gap:8px;align-items:baseline;padding:6px 0;border-bottom:1px solid var(--border)">'
            f'<i class="ti {ico}" style="color:{col};font-size:16px" aria-hidden="true"></i>'
            f'<code style="font-family:var(--font-mono);font-size:12px;color:var(--text-primary)">{esc(cmd)}</code>'
            f'<span style="margin-left:auto;font-size:12px;color:{col}">{note}</span></div>')
    checks_html = "".join(checks) or '<div style="color:var(--text-muted);font-size:13px">контракт ещё не собран</div>'

    if det:
        chips = "".join(
            f'<span style="display:inline-block;padding:3px 9px;border-radius:999px;font-size:12px;'
            f'background:{"var(--bg-warning)" if d.get("shadow") else "var(--bg-danger)"};'
            f'color:{"var(--text-warning)" if d.get("shadow") else "var(--text-danger)"};'
            f'border:1px solid {"var(--border-warning)" if d.get("shadow") else "var(--border-danger)"};'
            f'margin:0 6px 6px 0">{esc(d["detector"])}'
            f'{" · тихий режим" if d.get("shadow") else " · эскалация"}</span>' for d in det)
        det_html = chips + (f'<div style="font-size:12px;color:var(--text-secondary);margin-top:2px">'
                            f'{esc(det[0]["evidence"])}</div>' if det else "")
    else:
        det_html = ('<div style="font-size:13px;color:var(--text-muted)">тихо — ни один детектор не сработал'
                    f' на {iter_n} итерациях</div>')

    task = contract.get("task") or "задача не задана"
    runner = contract.get("runner") or "—"
    psha = (contract.get("patterns_sha") or "—")[:8]
    upd = datetime.datetime.now().strftime("%H:%M")

    return f"""<h2 class="sr-only">Карточка автономного прогона redloop: стадия {cur}, {len(green)} из {dod_total} проверок зелёные, статус — {status}</h2>
<div style="padding:2px 0 4px;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap">
  <span style="font-family:var(--font-mono);font-size:12px;color:var(--text-accent)">REDLOOP</span>
  <span style="font-size:16px;color:var(--text-primary)">{esc(task)}</span>
  <span style="margin-left:auto;padding:3px 10px;border-radius:999px;font-size:12px;background:{tone_bg};color:{tone_fg}">{status}</span>
</div>
<div style="display:flex;gap:6px;flex-wrap:wrap;margin:10px 0 14px">{"".join(pill(i, c, n) for i, (c, n) in enumerate(STAGES))}</div>
<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px;margin-bottom:12px">
  <div style="display:flex;justify-content:space-between;font-size:13px;color:var(--text-secondary)">
    <span>контракт готовности</span><span style="font-family:var(--font-mono)">{len(green)} / {dod_total}</span></div>
  <div style="height:6px;border-radius:999px;background:var(--surface-0);margin:8px 0 12px;overflow:hidden">
    <div style="height:6px;width:{pct}%;background:var(--text-success)"></div></div>
  {checks_html}
</div>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:12px">
  {kpi("итерация", f"{iter_n} / {iter_of if iter_of else '—'}", "из бюджета")}
  {kpi("вмешательств", interventions, "человек трогал прогон")}
  {kpi("допущений", assumptions, "решил сам, записал")}
  {kpi("сбои / красные", f"{infra} / {neg}", "инфра · вердикт")}
</div>
<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px">
  <div style="font-size:13px;color:var(--text-secondary);margin-bottom:8px">детекторы</div>
  {det_html}
</div>
<div style="display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--text-muted);margin-top:10px">
  <span>раннер: {esc(runner)}</span><span>приёмы: {esc(psha)}</span>
  <span>обновлено {upd}</span>
</div>"""

def _self_test():
    """Минимальная проверка ветки статусов: зелёная→красная и зелёная→blocked."""
    import tempfile, subprocess, shutil
    here = os.path.dirname(os.path.abspath(__file__)); fails = []
    def run(rd, *args):
        subprocess.run(["bash", os.path.join(here, "events.sh"), "append", rd] + list(args),
                       capture_output=True)
    def fixture(tmp, name, seq):
        rd = os.path.join(tmp, name); os.makedirs(rd, exist_ok=True)
        json.dump({"task": "t", "budget": {"max_iters": 5},
                   "dod": [{"id": "a", "cmd": "x", "expect_exit": 0},
                           {"id": "b", "cmd": "y", "expect_exit": 0}]},
                  open(os.path.join(rd, "contract.json"), "w"))
        run(rd, "run_start", '{"runner":"session","contract_sha":"a"}')
        run(rd, "iter_done", '{"task_id":"t","files_changed":1,"checkboxes_done":1}', "--iter", "1", "--of", "2")
        for payload in seq:
            run(rd, "check_result", payload, "--iter", "1")
        run(rd, "run_done", '{"verdict":"partial","iters":1,"interventions":0}')
        return rd
    tmp = tempfile.mkdtemp()
    os.environ["REDLOOP_INDEX"] = os.path.join(tmp, "index.jsonl")   # боевой реестр не трогаем
    try:
        # была зелёной, стала красной — карточка обязана показать красную, а не «завершён»
        rd = fixture(tmp, "regress", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"b","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"a","cmd_hash":"h","exit_code":1}'])
        html = build(rd, "S6")
        if "прогон завершён" in html: fails.append("регрессия зелёной проверки выдана за успех")
        if "красная" not in html: fails.append("красная проверка не показана")
        # зелёная + заблокированная внешним = «ждёт владельца»
        rd = fixture(tmp, "blocked", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"b","cmd_hash":"h","exit_code":1,"result":"blocked_owner_action"}'])
        html = build(rd, "S6")
        if "ждёт владельца" not in html: fails.append("blocked-прогон не помечен как ждущий владельца")
        if "заблокирована внешним" not in html: fails.append("blocked-строка не подписана")
        # частичное покрытие DoD не должно выдаваться за «ждёт владельца»
        rd = fixture(tmp, "partial", ['{"check_id":"a","cmd_hash":"h","exit_code":1,"result":"blocked_by_env"}'])
        html = build(rd, "S6")
        if "ждёт владельца" in html: fails.append("недоделанный DoD замаскирован под внешнюю блокировку")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails: print("  ✗", f)
    print("✓ dashboard self-test passed" if not fails else "✗ dashboard self-test FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    if len(sys.argv) < 2:
        print("usage: dashboard.py <run_dir> [--stage S3]", file=sys.stderr); sys.exit(1)
    rd = sys.argv[1]
    st = sys.argv[sys.argv.index("--stage") + 1] if "--stage" in sys.argv else ""
    sys.stdout.write(build(rd, st))
