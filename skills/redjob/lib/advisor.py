#!/usr/bin/env python3
"""redjob advisor — Фаза 2: советник размещения новой джобы.

Диспетчер РАЗРЕШАЕТ посадку, не сажает сам: строит занятость парка ТОЛЬКО из
jobs.yaml (инвариант — не читаем LaunchAgents напрямую), предлагает слот/
коалесинг/dependency-chain с обоснованием. Решает человек.

Перед советом гоняет doctor-drift-guard: если реестр разошёлся с диском/кодом —
отказывается советовать (советовать по неверной карте парка нельзя).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import registry
import doctor

DAY = 1440
HEAVY_BUFFER = 30      # мин: не сажать heavy-claude ближе к другому heavy
LOCK_BUFFER = 10       # мин: не сажать джобу с общим локом ближе к соседу по локу
HOURLY_EDGE = 5        # мин: ежечасные interval-джобы «занимают» :55–:05


def _cal_slots(job):
    out = []
    for e in (job.get("schedule") or {}).get("calendar") or []:
        if e.get("hour") is None:
            continue
        out.append((e.get("weekday"), e["hour"] * 60 + (e.get("minute") or 0)))
    return out


def _mark(forbidden, center, buf, reason, reasons):
    for d in range(-buf, buf + 1):
        forbidden.add((center + d) % DAY)
    reasons.setdefault(center, []).append(reason)


def drift_guard():
    """Вернуть список блокирующих находок (drift/secrets). Пусто = можно советовать."""
    _, findings = doctor.run()
    # Блокируем на классах, делающих КАРТУ парка недостоверной: реестр↔диск/код
    # разошёлся или секрет в реестре. not-loaded/file-hygiene/exit-code НЕ блокируют
    # (over-reserve в безопасную сторону; map-corrupting «plist пропал» ловит `drift`).
    blocking = [f for f in findings
                if f.rule in ("drift", "drift-code", "secrets")
                and f.sev in ("CRITICAL", "WARNING")]
    return blocking


def build_forbidden(data, spec):
    """Множество запретных минут суток + карта причин (почему занято).

    spec: {weight, locks, weekday(None=ежедневно)}. Учитываем только джобы,
    чьи дни пересекаются с днями новой (None = каждый день).
    """
    forbidden = set()
    reasons = {}
    # weekday 7≡0 (вс) — нормализуем спек (реестр уже нормализован в registry.load)
    new_wd = 0 if spec.get("weekday") == 7 else spec.get("weekday")
    new_heavy = spec.get("weight") == "heavy-claude"
    new_locks = set(spec.get("locks") or [])

    for j in data.get("jobs", []):
        if j.get("status") != "active":
            continue
        shared = new_locks & set(j.get("locks") or [])
        j_heavy = j.get("weight") == "heavy-claude"

        # calendar-соседи
        for wd, minute in _cal_slots(j):
            if not (new_wd is None or wd is None or new_wd == wd):
                continue
            if new_heavy and j_heavy:
                _mark(forbidden, minute, HEAVY_BUFFER,
                      f"heavy-claude сосед {j['label']} в {minute//60:02d}:{minute%60:02d}",
                      reasons)
            if shared:
                _mark(forbidden, minute, LOCK_BUFFER,
                      f"общий lock {sorted(shared)} с {j['label']}", reasons)

        # sub-daily interval-джобы с общим локом → занят край КАЖDОГО периода.
        # Обобщено с ==3600 на <=3600 (900/1800/3600): 24ч-фаза произвольна —
        # против неё не спланируешь, поэтому только период ≤1ч резервируем.
        isec = (j.get("schedule") or {}).get("interval_sec")
        if shared and j.get("kind") == "interval" and isinstance(isec, int) \
                and 60 <= isec <= 3600:
            period = isec // 60
            for m in range(0, DAY, period):
                _mark(forbidden, m, HOURLY_EDGE,
                      f"interval {j['label']} (каждые {period}мин, lock {sorted(shared)})",
                      reasons)

    return forbidden, reasons


def _clearance(minute, forbidden):
    """Расстояние (мин) до ближайшей запретной минуты (по кругу суток)."""
    if not forbidden:
        return DAY // 2
    best = DAY
    for f in forbidden:
        d = abs(minute - f)
        best = min(best, min(d, DAY - d))
    return best


def propose_slots(data, spec, n=3, granularity=15):
    """Топ-n свободных слотов, ранжированных по клиренсу (дальше от контеншена),
    разнесённых ≥120 мин. Возвращает [(minute, clearance, nearest_reason)]."""
    forbidden, reasons = build_forbidden(data, spec)
    candidates = []
    for m in range(0, DAY, granularity):
        if m in forbidden:
            continue
        candidates.append((m, _clearance(m, forbidden)))
    candidates.sort(key=lambda x: -x[1])
    picked = []
    for m, clr in candidates:
        if all(min(abs(m - pm), DAY - abs(m - pm)) >= 120 for pm, _ in picked):
            picked.append((m, clr))
        if len(picked) >= n:
            break
    return picked, reasons


def coalescing_candidates(data, spec):
    """Кандидаты на слияние: существующие джобы того же проекта, тот же auth,
    оба light, без внешних локов, близко по расписанию — advisory для «оптимизации
    количества джоб». Возвращает список текстовых предложений."""
    out = []
    proj = spec.get("project")
    same = [j for j in data.get("jobs", [])
            if j.get("status") == "active" and j.get("project") == proj
            and j.get("weight") == "light" and j.get("auth") == spec.get("auth")
            and not j.get("locks")]
    # пары уже существующих близких calendar-джоб проекта
    cal = []
    for j in same:
        for wd, mn in _cal_slots(j):
            cal.append((mn, wd, j["label"]))
    cal.sort()
    for i in range(len(cal)):
        for k in range(i + 1, len(cal)):
            (m1, wd1, l1), (m2, wd2, l2) = cal[i], cal[k]
            if l1 == l2:
                continue
            if (wd1 == wd2 or wd1 is None or wd2 is None) and abs(m1 - m2) <= 15:
                out.append(f"слить {l1} + {l2} (проект {proj}, оба light/{spec.get('auth')}, "
                           f"старт в {abs(m1-m2)}мин) → один скрипт-обёртка, "
                           f"последовательный вызов (−1 джоба)")
    return sorted(set(out))


def advise(spec):
    """Полный совет: drift-guard → слоты → коалесинг → dependency-chain."""
    blocking = drift_guard()
    if blocking:
        return {"refused": True, "reason": "drift",
                "findings": [(f.sev, f.rule, f.label, f.msg) for f in blocking]}
    data = registry.load()
    result = {"refused": False, "label": spec.get("label"),
              "slots": [], "coalescing": [], "dependency": None, "reasons": {}}

    if spec.get("kind") == "calendar":
        picked, reasons = propose_slots(data, spec)
        result["slots"] = [{"time": f"{m//60:02d}:{m%60:02d}", "clearance_min": clr}
                           for m, clr in picked]
        # ближайшие причины занятости для контекста
        result["reasons"] = {f"{k//60:02d}:{k%60:02d}": v for k, v in list(reasons.items())[:8]}
    result["coalescing"] = coalescing_candidates(data, spec)
    if spec.get("after"):
        result["dependency"] = (f"вместо времени — запускать ПОСЛЕ {spec['after']} через "
                                f"маркер-файл (dependency-chain, не по часам)")
    return result
