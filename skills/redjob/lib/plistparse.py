#!/usr/bin/env python3
"""redjob plistparse — читает launchd plist в нормальную dict-модель.

Покрывает ВСЕ три стиля расписания (иначе seed/doctor слепнут):
  1. StartCalendarInterval как dict  → один calendar-триггер
  2. StartCalendarInterval как list  → несколько (tg-draft пн/ср/пт)
  3. StartInterval (int сек)          → interval
  4. KeepAlive (bool|dict) + RunAtLoad → keepalive/persistent

plistlib из stdlib читает и binary, и XML plist — plutil не нужен.
"""
import os
import json
import plistlib
import subprocess

_WD = {0: "Sun", 1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat", 7: "Sun"}


def load_plist(path):
    """Читать plist, с фолбэком на plutil при строгих XML-ошибках.

    plistlib использует expat (строгий): сырой control-байт в комментарии
    (реальный случай) валит парс, хотя launchd
    и plutil такой plist принимают. Фолбэк через `plutil -convert json` =
    ровно то, что видит сам launchd. Возвращает (dict, lenient_flag).
    """
    try:
        with open(path, "rb") as f:
            return plistlib.load(f), False
    except Exception:
        r = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                           capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            raise ValueError(f"plutil тоже не смог: {r.stderr.strip()}")
        return json.loads(r.stdout), True


def _norm_cal(entry):
    """dict StartCalendarInterval → {'hour','minute','weekday'} (None где не задано).

    launchd трактует Weekday 0 И 7 как воскресенье — нормализуем 7→0, иначе
    коллизия двух вс-джоб (одна с 0, другая с 7) не поймается."""
    wd = entry.get("Weekday")
    if wd == 7:
        wd = 0
    return {
        "hour": entry.get("Hour"),
        "minute": entry.get("Minute"),
        "weekday": wd,
    }


def parse(path):
    """Вернуть нормализованную модель джобы из plist-файла."""
    try:
        pl, lenient = load_plist(path)
    except Exception as e:
        return {"_error": f"plist parse failed: {e}", "plist": path,
                "label": os.path.basename(path).replace(".plist", "")}

    prog_args = pl.get("ProgramArguments")
    program = pl.get("Program")
    if prog_args:
        interpreter = prog_args[0]
        script = prog_args[1] if len(prog_args) > 1 else None
        argv = prog_args
    elif program:
        interpreter = program
        script = None
        argv = [program]
    else:
        interpreter = script = None
        argv = []

    # Определяем kind + machine-schedule.
    kind = "unknown"
    schedule = []          # список calendar-триггеров
    interval_sec = None
    keepalive = False

    sci = pl.get("StartCalendarInterval")
    if sci is not None:
        kind = "calendar"
        if isinstance(sci, list):
            schedule = [_norm_cal(e) for e in sci]
        elif isinstance(sci, dict):
            schedule = [_norm_cal(sci)]
    elif pl.get("StartInterval") is not None:
        kind = "interval"
        interval_sec = int(pl["StartInterval"])
    if pl.get("KeepAlive"):
        keepalive = True
        if kind == "unknown":
            kind = "keepalive"

    env = pl.get("EnvironmentVariables") or {}

    return {
        "label": pl.get("Label", os.path.basename(path).replace(".plist", "")),
        "plist": path,
        "kind": kind,
        "interpreter": interpreter,
        "script": script,
        "argv": argv,
        "schedule": schedule,
        "interval_sec": interval_sec,
        "keepalive": keepalive,
        "run_at_load": bool(pl.get("RunAtLoad")),
        "env": dict(env),
        "env_path": env.get("PATH"),
        "stdout": pl.get("StandardOutPath"),
        "stderr": pl.get("StandardErrorPath"),
        "lenient_parse": lenient,   # True = прошёл только через plutil (не строгий XML)
    }


def schedule_human(model):
    """Человекочитаемое расписание для list/отчётов."""
    k = model.get("kind")
    if k == "calendar":
        parts = []
        for s in model.get("schedule", []):
            wd = _WD.get(s["weekday"], "*") if s.get("weekday") is not None else "*"
            hh = "??" if s.get("hour") is None else f"{s['hour']:02d}"
            mm = "00" if s.get("minute") is None else f"{s['minute']:02d}"
            parts.append(f"{wd} {hh}:{mm}")
        return ", ".join(parts) or "calendar(?)"
    if k == "interval":
        sec = model.get("interval_sec") or 0
        if sec % 3600 == 0:
            return f"каждые {sec // 3600}ч"
        if sec % 60 == 0:
            return f"каждые {sec // 60}мин"
        return f"каждые {sec}с"
    if k in ("keepalive",) or model.get("keepalive"):
        return "persistent (KeepAlive)"
    return k or "?"
