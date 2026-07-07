#!/usr/bin/env python3
"""redjob tests — assert-таблица «фикстура → правило → severity» (не глазами).

Генерит битые plist+скрипты во временном каталоге, гоняет doctor.run на них,
проверяет что каждый целевой класс поломки пойман с нужной severity, и что
на чистой фикстуре ложных CRITICAL нет. Плюс юнит-проверки валидатора/scrub.
"""
import os
import sys
import stat
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "lib")
sys.path.insert(0, LIB)

import registry
import doctor
import scrub

PLIST_TMPL = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>{script}</string></array>
{env}
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>{hour}</integer><key>Minute</key><integer>{minute}</integer></dict>
</dict></plist>
"""

ENV_PATH = ("  <key>EnvironmentVariables</key><dict><key>PATH</key>"
            "<string>/opt/homebrew/bin:/usr/bin:/bin</string></dict>")

# plist БЕЗ единого триггера (SCI/StartInterval/KeepAlive) и RunAtLoad=false —
# репродукция реального инцидента: launchd такой примет и будет вечно молчать.
NOTRIG_TMPL = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>{script}</string></array>
  <key>RunAtLoad</key><false/>
</dict></plist>
"""


def write_script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/bash\n" + body + "\n")
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)


def make_fixtures(root):
    agents = os.path.join(root, "agents")
    scripts = os.path.join(root, "scripts")
    os.makedirs(agents); os.makedirs(scripts)

    def plist(label, script, hour=2, minute=0, env=False):
        p = os.path.join(agents, label + ".plist")
        with open(p, "w") as f:
            f.write(PLIST_TMPL.format(label=label, script=script, hour=hour,
                                      minute=minute, env=ENV_PATH if env else ""))
        return p

    jobs = []

    # 1. path-fail: deps gtimeout, нет PATH, нет login-shell → CRITICAL path-resolve
    s = os.path.join(scripts, "pathfail.sh")
    write_script(s, "gtimeout 5 echo hi")
    plist("fix.pathfail", s, hour=1)
    jobs.append({"label": "fix.pathfail", "project": "alpha", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 1, "minute": 0, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.pathfail.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": ["gtimeout"], "auth": "none",
                 "weight": "light", "status": "active"})

    # 2. missing-bin: несуществующий бинарь → CRITICAL path-resolve
    s = os.path.join(scripts, "missing.sh")
    write_script(s, "echo noop")
    plist("fix.missingbin", s, hour=1, minute=30, env=True)
    jobs.append({"label": "fix.missingbin", "project": "alpha", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 1, "minute": 30, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.missingbin.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": ["totallynotreal_xyz"],
                 "auth": "none", "weight": "light", "status": "active"})

    # 3. op-no-sa: зовёт op напрямую, нет SA/op_env → CRITICAL op-safety
    s = os.path.join(scripts, "opnosa.sh")
    write_script(s, "op read op://vault/item/cred")
    plist("fix.opnosa", s, hour=3, env=True)
    jobs.append({"label": "fix.opnosa", "project": "beta", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 3, "minute": 0, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.opnosa.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": ["op"], "auth": "op-sa",
                 "weight": "light", "status": "active"})

    # 4. op-wrapper (depth>1): auth op-sa, op НЕ виден в скрипте, нет SA → WARNING op-safety
    s = os.path.join(scripts, "opwrap.sh")
    write_script(s, "some_wrapper_that_calls_op_internally")
    plist("fix.opwrap", s, hour=5, env=True)
    jobs.append({"label": "fix.opwrap", "project": "beta", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 5, "minute": 0, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.opwrap.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": [], "auth": "op-sa",
                 "weight": "light", "status": "active"})

    # 5+6. collision-heavy: два heavy-claude в 20мин
    for i, mn in enumerate((0, 20)):
        s = os.path.join(scripts, f"heavy{i}.sh")
        write_script(s, "claude -p 'do work' --model sonnet")
        plist(f"fix.heavy{i}", s, hour=7, minute=mn, env=True)
        jobs.append({"label": f"fix.heavy{i}", "project": "beta", "kind": "calendar",
                     "schedule": {"calendar": [{"hour": 7, "minute": mn, "weekday": None}]},
                     "plist": os.path.join(agents, f"fix.heavy{i}.plist"), "script": s,
                     "interpreter": "/bin/bash", "deps_bins": [], "auth": "none",
                     "weight": "heavy-claude", "status": "active"})

    # 3b. abspath-op (#3): op зовётся АБСОЛЮТНЫМ путём, нет SA → CRITICAL op-safety
    s = os.path.join(scripts, "abspathop.sh")
    write_script(s, "/opt/homebrew/bin/op read op://vault/item/cred")
    plist("fix.abspathop", s, hour=6, minute=30, env=True)
    jobs.append({"label": "fix.abspathop", "project": "beta", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 6, "minute": 30, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.abspathop.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": [], "auth": "op-sa",
                 "weight": "light", "status": "active"})

    # 3c. comment-safe (#2): op зовётся, а гвард лишь в КОММЕНТАРИИ → всё равно CRITICAL
    s = os.path.join(scripts, "commentsafe.sh")
    write_script(s, "# OP_SERVICE_ACCOUNT_TOKEN выставляется в zshenv, всё ок\nop read op://v/i/c")
    plist("fix.commentsafe", s, hour=6, minute=50, env=True)
    jobs.append({"label": "fix.commentsafe", "project": "beta", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 6, "minute": 50, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.commentsafe.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": ["op"], "auth": "op-sa",
                 "weight": "light", "status": "active"})

    # 7. drift-code: скрипт зовёт op, но реестр auth=none → WARNING drift-code
    s = os.path.join(scripts, "drift.sh")
    write_script(s, "op signin && echo done")
    plist("fix.drift", s, hour=9, env=True)
    jobs.append({"label": "fix.drift", "project": "beta", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 9, "minute": 0, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.drift.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": ["op"], "auth": "none",
                 "weight": "light", "status": "active"})

    # 8. clean: PATH ок, бинарь резолвится, без op → НЕ должен дать CRITICAL/WARNING
    s = os.path.join(scripts, "clean.sh")
    write_script(s, "echo clean")
    plist("fix.clean", s, hour=12, env=True)
    jobs.append({"label": "fix.clean", "project": "alpha", "kind": "calendar",
                 "schedule": {"calendar": [{"hour": 12, "minute": 0, "weekday": None}]},
                 "plist": os.path.join(agents, "fix.clean.plist"), "script": s,
                 "interpreter": "/bin/bash", "deps_bins": [], "auth": "none",
                 "weight": "light", "status": "active"})

    # 9. no-trigger: plist без SCI/StartInterval/KeepAlive, RunAtLoad=false →
    # CRITICAL no-trigger. Реестр при этом врёт kind=keepalive (ровно так seed
    # отмыл kind=unknown в реальном инциденте) — правило обязано смотреть в plist.
    s = os.path.join(scripts, "notrigger.sh")
    write_script(s, "echo dead")
    p = os.path.join(agents, "fix.notrigger.plist")
    with open(p, "w") as f:
        f.write(NOTRIG_TMPL.format(label="fix.notrigger", script=s))
    jobs.append({"label": "fix.notrigger", "project": "alpha", "kind": "keepalive",
                 "plist": p, "script": s, "interpreter": "/bin/bash",
                 "deps_bins": [], "auth": "none", "weight": "light", "status": "active"})

    # external с ИСЧЕЗНУВШИМ plist → НЕ должен давать drift-CRITICAL (QA1)
    jobs.append({"label": "com.google.SomeVendor", "project": "external",
                 "kind": "keepalive", "plist": os.path.join(agents, "com.google.SomeVendor.plist"),
                 "status": "external", "notes": "сторонний — без проверок"})

    # реестр с секретом в notes → secrets-lint CRITICAL (пишем СЫРЫМ текстом,
    # atomic_write бы отверг env_required со значением — тут секрет в notes)
    reg_path = os.path.join(root, "jobs.yaml")
    data = {"schema_version": registry.SCHEMA_VERSION, "jobs": jobs}
    text = registry.dump_str(data)
    text += "\n# leaked: sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345\n"
    text += "# leaked-tg: 123456789:AA" + "Ffake_bot_token_value_01234567890123\n"
    with open(reg_path, "w") as f:
        f.write(text)
    return reg_path, agents


EXPECT = [
    ("fix.pathfail", "path-resolve", "CRITICAL"),
    ("fix.missingbin", "path-resolve", "CRITICAL"),
    ("fix.opnosa", "op-safety", "CRITICAL"),
    ("fix.abspathop", "op-safety", "CRITICAL"),    # #3 op по абсолютному пути
    ("fix.commentsafe", "op-safety", "CRITICAL"),  # #2 гвард в комментарии ≠ safe
    ("fix.opwrap", "op-safety", "WARNING"),
    ("fix.drift", "drift-code", "WARNING"),
    ("fix.notrigger", "no-trigger", "CRITICAL"),
    ("jobs.yaml", "secrets", "CRITICAL"),
]


def has(findings, label, rule, sev):
    return any(f.label == label and f.rule == rule and f.sev == sev for f in findings)


def run():
    failures = []
    with tempfile.TemporaryDirectory() as root:
        reg_path, agents = make_fixtures(root)
        _, findings = doctor.run(reg_path=reg_path, la_dir=agents)

        for label, rule, sev in EXPECT:
            if has(findings, label, rule, sev):
                print(f"  ✓ {label:16} {rule:14} → {sev}")
            else:
                got = [f"{f.rule}:{f.sev}" for f in findings if f.label == label]
                failures.append(f"{label} {rule}:{sev} НЕ найдено (есть: {got})")
                print(f"  ✗ {label:16} {rule:14} → ожидал {sev}, есть {got}")

        # collision-heavy между fix.heavy0/heavy1
        if any(f.rule == "collision-heavy" and "fix.heavy0" in f.label and "fix.heavy1" in f.label
               for f in findings):
            print("  ✓ collision-heavy   fix.heavy0 ↔ fix.heavy1 → WARNING")
        else:
            failures.append("collision-heavy heavy0↔heavy1 не найдено")
            print("  ✗ collision-heavy   heavy0↔heavy1 не пойман")

        # scrub-on-render end-to-end (gap панели): рендер НЕ пропускает сырой секрет
        rendered, _ = doctor.render(findings)
        raw = ["sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
               "123456789:AA" + "Ffake_bot_token_value_01234567890123"]
        leaked_render = [s for s in raw if s in rendered]
        if leaked_render:
            failures.append(f"render пропустил сырой секрет: {leaked_render}")
            print(f"  ✗ render пропустил сырой секрет в stdout")
        else:
            print("  ✓ render             маскирует секрет в выводе (scrub-on-render)")

        # external с исчезнувшим plist НЕ даёт drift-CRITICAL (QA1)
        ext_crit = [f for f in findings if f.label == "com.google.SomeVendor"
                    and f.sev == "CRITICAL"]
        if ext_crit:
            failures.append(f"external дал CRITICAL: {[(f.rule) for f in ext_crit]}")
            print(f"  ✗ external plist-missing дал CRITICAL (QA1 регресс)")
        else:
            print("  ✓ external          исчезнувший plist не даёт CRITICAL (QA1)")

        # clean не должен дать CRITICAL/WARNING по ДИАГНОСТИЧЕСКИМ правилам.
        # not-loaded исключаем: фикстуры не грузятся в launchctl — это корректно,
        # а не ложное срабатывание (проверяем именно path/op/hygiene-логику).
        clean_bad = [f for f in findings if f.label == "fix.clean"
                     and f.sev in ("CRITICAL", "WARNING") and f.rule != "not-loaded"]
        if clean_bad:
            failures.append(f"fix.clean дал ложные: {[(f.rule, f.sev) for f in clean_bad]}")
            print(f"  ✗ fix.clean ложные срабатывания: {[(f.rule, f.sev) for f in clean_bad]}")
        else:
            print("  ✓ fix.clean         без ложных CRITICAL/WARNING")

    # юнит: валидатор ловит секрет-значение в env_required
    bad = {"schema_version": 1, "jobs": [{"label": "x", "project": "p", "kind": "calendar",
            "status": "active", "env_required": ["FOO=sk-secret"]}]}
    if any("env_required" in e for e in registry.validate(bad)):
        print("  ✓ validate          отвергает env_required со значением")
    else:
        failures.append("validate не отверг env_required со значением")
        print("  ✗ validate не отверг env_required со значением")

    # юнит #1: parse_path_assignments разворачивает $HOME (не отбрасывает как переменную)
    import common
    eff = common.parse_path_assignments('export PATH="$HOME/.local/bin:$PATH"',
                                        common.LAUNCHD_DEFAULT_PATH)
    if os.path.join(common.HOME, ".local/bin") in eff.split(":"):
        print("  ✓ parse_path       разворачивает $HOME/.local/bin")
    else:
        failures.append(f"parse_path не развернул $HOME (eff={eff})")
        print(f"  ✗ parse_path не развернул $HOME: {eff}")

    # юнит #3: invokes ловит вызов по абсолютному пути
    if common.invokes("/opt/homebrew/bin/op whoami", "op") and \
       not common.invokes("# просто упоминание op в комменте", "op"):
        print("  ✓ invokes           ловит abspath, игнорит комментарий")
    else:
        failures.append("invokes: abspath/comment логика неверна")
        print("  ✗ invokes: abspath/comment логика неверна")

    # юнит: scrub маскирует ключ + TG bot token (C2) + url-пароль
    key = "sk-ABCDEFGHIJKLMNOPQRSTUV0123"
    tg = "123456789:AA" + "Ffake_Bot_Token_Value_012345678901234"
    url = "https://user:supersecret@host/x"
    masked = scrub.scrub_text(f"a {key} b {tg} c {url}")
    leaked = [x for x in (key, tg, "supersecret") if x in masked]
    if not leaked:
        print("  ✓ scrub             маскирует ключ/TG-токен/url-пароль")
    else:
        failures.append(f"scrub не замаскировал: {leaked}")
        print(f"  ✗ scrub не замаскировал: {leaked}")

    # ---- Фаза 2: советник + генератор ----
    import advisor, plistgen
    # advisor Done-when: heavy-новичок не садится рядом с heavy-соседями (07:30–09:00)
    synth = {"schema_version": 1, "jobs": [
        {"label": "h1", "project": "p", "kind": "calendar", "weight": "heavy-claude",
         "auth": "op-sa", "status": "active",
         "schedule": {"calendar": [{"hour": 8, "minute": 0, "weekday": None}]}},
        {"label": "h2", "project": "p", "kind": "calendar", "weight": "heavy-claude",
         "auth": "op-sa", "status": "active",
         "schedule": {"calendar": [{"hour": 8, "minute": 30, "weekday": None}]}},
    ]}
    picked, _ = advisor.propose_slots(synth, {"weight": "heavy-claude", "locks": [], "weekday": None})
    bad = [f"{m//60:02d}:{m%60:02d}" for m, _ in picked if 7*60+30 <= m <= 9*60]
    if picked and not bad:
        print("  ✓ advisor           heavy-новичок избегает окна heavy-соседей 07:30–09:00")
    else:
        failures.append(f"advisor предложил слот в heavy-окне: {bad or 'нет слотов'}")
        print(f"  ✗ advisor: слот в heavy-окне {bad}")

    # advisor коалесинг: две light same-project same-auth близко → предложение слить
    coal_data = {"schema_version": 1, "jobs": [
        {"label": "a", "project": "gamma", "kind": "calendar", "weight": "light",
         "auth": "none", "locks": [], "status": "active",
         "schedule": {"calendar": [{"hour": 10, "minute": 0, "weekday": 1}]}},
        {"label": "b", "project": "gamma", "kind": "calendar", "weight": "light",
         "auth": "none", "locks": [], "status": "active",
         "schedule": {"calendar": [{"hour": 10, "minute": 5, "weekday": 1}]}},
    ]}
    cc = advisor.coalescing_candidates(coal_data, {"project": "gamma", "auth": "none"})
    if cc:
        print("  ✓ advisor           коалесинг ловит близкие light-джобы (−1 джоба)")
    else:
        failures.append("advisor не предложил коалесинг близких light-джоб")
        print("  ✗ advisor коалесинг не сработал")

    # plistgen self-doctor гейт: чистая → 0 crit; битая → crit>0
    clean = {"label": "test.clean", "project": "redjob", "kind": "calendar",
             "script": os.path.join(os.path.dirname(HERE), "bin", "redjob"),
             "interpreter": "/bin/bash", "weight": "light", "auth": "none",
             "deps_bins": ["python3"], "calendar": {"Hour": 11, "Minute": 30}}
    _, _, nc_clean = plistgen.stage_and_check(clean)
    bad_spec = dict(clean, label="test.bad", deps_bins=["totallynotreal_xyz"])
    _, _, nc_bad = plistgen.stage_and_check(bad_spec)
    if nc_clean == 0 and nc_bad > 0:
        print("  ✓ plistgen          self-doctor: чистая PASS, битая CRITICAL (гейт)")
    else:
        failures.append(f"plistgen гейт: clean_crit={nc_clean} bad_crit={nc_bad}")
        print(f"  ✗ plistgen гейт неверен: clean={nc_clean} bad={nc_bad}")

    # F3: label с traversal → CRITICAL label, файл НЕ пишется
    trav = dict(clean, label="../pwned")
    tp, tf, tnc = plistgen.stage_and_check(trav)
    pwned = os.path.join(os.path.dirname(plistgen.STAGING), "pwned.plist")
    if tp is None and tnc >= 1 and any(f.rule == "label" for f in tf) \
            and not os.path.exists(pwned):
        print("  ✓ plistgen          label-traversal завёрнут до записи (F3/F4)")
    else:
        failures.append(f"plistgen label-traversal НЕ завёрнут (path={tp}, pwned_exists={os.path.exists(pwned)})")
        print("  ✗ plistgen: label-traversal прошёл")
        if os.path.exists(pwned):
            os.unlink(pwned)

    # F2: секрет в spec.env → CRITICAL secrets, install не показать
    sec = dict(clean, label="test.envsecret",
               env={"ANTHROPIC_API_KEY": "sk-FAKEABCDEFGHIJKLMNOP012345"})
    _, sf, snc = plistgen.stage_and_check(sec)
    if snc >= 1 and any(f.rule == "secrets" for f in sf):
        print("  ✓ plistgen          секрет в spec.env → CRITICAL (F2)")
    else:
        failures.append(f"plistgen не поймал секрет в spec.env (crit={snc})")
        print("  ✗ plistgen: секрет в spec.env прошёл")

    # F1: гейт видит park-коллизию (self-contained: впрыснутый парк с heavy @08:00)
    coll_park = {"schema_version": 1, "jobs": [
        {"label": "park.heavyA", "project": "p", "kind": "calendar", "weight": "heavy-claude",
         "auth": "none", "status": "active",
         "schedule": {"calendar": [{"hour": 8, "minute": 0, "weekday": None}]}}]}
    coll = dict(clean, label="test.collide", project="p",
                weight="heavy-claude", calendar={"Hour": 8, "Minute": 15})
    _, cf, _ = plistgen.stage_and_check(coll, park_data=coll_park)
    if any(f.rule == "collision-heavy" and "test.collide" in f.label for f in cf):
        print("  ✓ plistgen          гейт видит park-коллизию heavy (F1)")
    else:
        failures.append("plistgen гейт не увидел park-коллизию heavy")
        print("  ✗ plistgen: park-коллизия невидима гейту")

    # FIX2: секрет в spec.script тоже ловится гейтом (не только env/args)
    ssec = dict(clean, label="test.scriptsecret",
                script="sk-FAKEABCDEFGHIJKLMNOP012345")
    _, ssf, ssnc = plistgen.stage_and_check(ssec)
    if ssnc >= 1 and any(f.rule == "secrets" for f in ssf):
        print("  ✓ plistgen          секрет в spec.script → CRITICAL (FIX2)")
    else:
        failures.append("plistgen не поймал секрет в spec.script")
        print("  ✗ plistgen: секрет в spec.script прошёл")

    # FIX3: короткий несвязанный label НЕ вытягивает чужие коллизии (точный матч).
    # Впрыснутый парк с ЧУЖОЙ heavy-парой @08:00/08:15; новая 'zz' @13:00 — вне её.
    unrel_park = {"schema_version": 1, "jobs": [
        {"label": "otherA", "project": "p", "kind": "calendar", "weight": "heavy-claude",
         "auth": "none", "status": "active",
         "schedule": {"calendar": [{"hour": 8, "minute": 0, "weekday": None}]}},
        {"label": "otherB", "project": "p", "kind": "calendar", "weight": "heavy-claude",
         "auth": "none", "status": "active",
         "schedule": {"calendar": [{"hour": 8, "minute": 15, "weekday": None}]}}]}
    unrel = dict(clean, label="zz", weight="light", calendar={"Hour": 13, "Minute": 0})
    _, uf, _ = plistgen.stage_and_check(unrel, park_data=unrel_park)
    if not any(f.rule.startswith("collision") for f in uf):
        print("  ✓ plistgen          несвязанный label не тянет чужие коллизии (FIX3)")
    else:
        failures.append(f"plistgen: чужая коллизия просочилась в 'zz': {[f.label for f in uf if f.rule.startswith('collision')]}")
        print("  ✗ plistgen: чужая коллизия просочилась")

    # no-trigger в self-doctor гейте: kind-опечатка → build_plist_dict молча
    # игнорит calendar → plist без триггера → CRITICAL до показа install
    ntspec = dict(clean, label="test.notrigger", kind="calender")   # опечатка намеренно
    _, ntf, ntnc = plistgen.stage_and_check(ntspec)
    if ntnc >= 1 and any(f.rule == "no-trigger" and f.sev == "CRITICAL" for f in ntf):
        print("  ✓ plistgen          kind-опечатка → plist без триггера → CRITICAL no-trigger")
    else:
        failures.append(f"plistgen гейт пропустил plist без триггера (crit={ntnc})")
        print(f"  ✗ plistgen: plist без триггера прошёл гейт (crit={ntnc})")

    # no-trigger + RunAtLoad=true → мягче: WARNING (запуск раз на login — бывает намеренно)
    ntw = dict(clean, label="test.notrigger.ral", kind="oneshot", run_at_load=True)
    _, wf, wnc = plistgen.stage_and_check(ntw)
    if wnc == 0 and any(f.rule == "no-trigger" and f.sev == "WARNING" for f in wf):
        print("  ✓ plistgen          no-trigger+RunAtLoad → WARNING (не блокирует)")
    else:
        failures.append(f"no-trigger+RunAtLoad: ожидал WARNING без CRITICAL "
                        f"(crit={wnc}, rules={[(f.rule, f.sev) for f in wf]})")
        print("  ✗ plistgen: no-trigger+RunAtLoad severity неверна")

    # сгенерированный plist валиден по plutil
    path = plistgen._staging_path("test.clean")
    import subprocess as _sp
    ok = _sp.run(["plutil", "-lint", path], capture_output=True).returncode == 0
    if ok:
        print("  ✓ plistgen          сгенерированный plist проходит plutil -lint")
    else:
        failures.append("plistgen: plist не проходит plutil -lint")
        print("  ✗ plistgen: невалидный plist")

    print()
    if failures:
        print(f"FAIL: {len(failures)} провалов")
        for f in failures:
            print("  - " + f)
        return 1
    print("PASS: все asserts зелёные")
    return 0


if __name__ == "__main__":
    sys.exit(run())
