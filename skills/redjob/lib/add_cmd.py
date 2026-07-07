#!/usr/bin/env python3
"""redjob add — Фаза 2 CLI: советник размещения + (опц.) генерация plist.

  redjob add <spec.json>              совет: слоты/коалесинг/dependency (read-only)
  redjob add <spec.json> --generate   + сгенерить plist, прогнать self-doctor,
                                       напечатать install/rollback (НЕ выполнять)

spec.json (пример):
  {"label":"com.redjob.selfcheck","project":"redjob","kind":"calendar",
   "script":"/path/selfcheck.sh","weight":"light","auth":"none",
   "deps_bins":["python3"],"calendar":{"Hour":11,"Minute":30}}
"""
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import advisor
import plistgen
import scrub


def _print(s=""):
    print(scrub.scrub_text(str(s)))


def main(argv):
    if not argv:
        _print(__doc__)
        return 2
    spec_path = argv[0]
    generate = "--generate" in argv
    try:
        with open(spec_path, encoding="utf-8") as f:
            spec = json.load(f)
    except Exception as e:
        _print(f"не прочитать spec.json: {e}")
        return 2
    if not spec.get("label") or not spec.get("script"):
        _print("spec обязан содержать 'label' и 'script'")
        return 2

    # --- совет размещения ---
    adv = advisor.advise(spec)
    if adv.get("refused"):
        _print(common.c("⛔ Совет отклонён: реестр разошёлся с диском/кодом (drift).", "1;31"))
        _print("   Почини реестр (`redjob doctor` → `redjob seed --write`) и повтори.")
        for sev, rule, label, msg in adv.get("findings", []):
            _print(f"   [{sev}] {rule} · {label}: {msg}")
        return 1

    _print(common.c(f"Совет по размещению «{spec['label']}»", "1"))
    if adv["slots"]:
        _print("\nСвободные слоты (по клиренсу от контеншена):")
        for s in adv["slots"]:
            _print(f"  • {s['time']}  (клиренс {s['clearance_min']}мин до ближайшей занятой)")
    elif spec.get("kind") == "calendar":
        _print("\n  ⚠ свободных слотов не найдено — парк плотный, рассмотри коалесинг/цепочку")
    if adv.get("reasons"):
        _print("\nПочему часть суток занята (контекст):")
        for t, why in adv["reasons"].items():
            _print(f"  {t}: {why[0]}")
    if adv["coalescing"]:
        _print(common.c("\nКандидаты на коалесинг (−джобы, «оптимизация количества»):", "1"))
        for c in adv["coalescing"]:
            _print(f"  • {c}")
    if adv.get("dependency"):
        _print(f"\nАльтернатива: {adv['dependency']}")
    _print(common.c("\n→ Диспетчер РАЗРЕШАЕТ посадку, но сажает человек. "
                    "Выбери слот и запусти с --generate.", "2"))

    if not generate:
        return 0

    # --- генерация plist + self-doctor гейт ---
    # kind вне VALID_KIND → build_plist_dict молча не пишет НИ ОДНОГО триггера
    # (реальный инцидент: джоба месяц молчала) — заворачиваем на входе.
    if spec.get("kind") not in ("calendar", "interval", "keepalive"):
        _print(f"\n⚠ kind={spec.get('kind')!r} — обязан быть calendar|interval|keepalive, "
               "иначе plist выйдет без триггера и launchd его никогда не запустит.")
        return 2
    if spec.get("kind") == "calendar" and not spec.get("calendar"):
        _print("\n⚠ для --generate у calendar-джобы нужен конкретный 'calendar' "
               "(напр. {\"Hour\":11,\"Minute\":30}) — выбери слот из совета выше.")
        return 2
    if spec.get("kind") == "interval":
        try:
            if int(spec.get("interval_sec")) <= 0:
                raise ValueError
        except (TypeError, ValueError):
            _print("\n⚠ для interval-джобы нужен целочисленный 'interval_sec' > 0.")
            return 2

    path, findings, n_crit = plistgen.stage_and_check(spec)
    _print(common.c(f"\nСгенерирован plist → {path}", "1"))
    crit = [f for f in findings if f.sev == "CRITICAL"]
    warn = [f for f in findings if f.sev == "WARNING"]
    if n_crit:
        _print(common.c("⛔ self-doctor: сгенерированный plist НЕ проходит "
                        "(install-команды НЕ печатаем — почини вход):", "1;31"))
        for f in crit:
            _print(f"   [CRITICAL] {f.rule}: {f.msg}")
            if f.fix:
                _print(f"       fix: {f.fix}")
        return 1
    for f in warn:
        _print(f"   [WARNING] {f.rule}: {f.msg}")
    _print(common.c("✓ self-doctor: plist чист (0 CRITICAL)", "1;32"))

    snap = plistgen.pre_install_snapshot()
    _print(f"\npre-install snapshot: {snap}")
    install, rollback, lock_warn = plistgen.install_commands(spec, path)
    _print(common.c("\nУстановить (выполни сам, диспетчер не сажает):", "1"))
    for cmd in install:
        _print(f"  $ {cmd}")
    _print(common.c("\nОткат:", "1"))
    for cmd in rollback:
        _print(f"  $ {cmd}")
    _print("  # + пометь запись retired в jobs.yaml")
    if lock_warn:
        _print(common.c(f"\n{lock_warn}", "1;33"))
    _print(common.c("\nПосле установки: `redjob seed --write` (внести в реестр) + "
                    "`redjob doctor` (проверить).", "2"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
