#!/usr/bin/env python3
"""redjob registry — jobs.yaml как БД: схема, валидатор, atomic-write, миграции.

Инварианты (из plan v2, шаг 1):
  * первое поле файла — schema_version (миграция = bump + migrate-функция);
  * ЛЮБАЯ программная запись — temp-файл + os.replace под flock + re-parse-валидация,
    иначе откат из git (реестр не должен деградировать в битый файл);
  * env_required хранит ТОЛЬКО имена переменных — значение секрета в схеме запрещено
    (первая линия обороны от утечки; secrets-lint doctor'а — вторая).
"""
import os
import re
import fcntl
import tempfile

try:
    import yaml
except ImportError:
    yaml = None

from common import JOBS_YAML

SCHEMA_VERSION = 1

VALID_KIND = {"calendar", "interval", "keepalive"}
VALID_AUTH = {"none", "op-sa", "chrome-session"}
VALID_WEIGHT = {"light", "heavy-claude"}
VALID_STATUS = {"active", "external", "retired"}

REQUIRED_FIELDS = ("label", "project", "kind", "status")
# Значение секрета в env_required = провал валидации (не только doctor-lint).
SECRET_VALUE_RE = re.compile(r"(=)|(sk-)|(ghp_)|(AIza)|(op://)", re.I)


class RegistryError(Exception):
    pass


def _require_yaml():
    if yaml is None:
        raise RegistryError(
            "PyYAML недоступен. Установи (`pip3 install pyyaml`) или используй "
            "venv ~/.claude/parsing-venv.")


def load(path=JOBS_YAML):
    _require_yaml()
    if not os.path.exists(path):
        return {"schema_version": SCHEMA_VERSION, "jobs": []}
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    data = migrate(data)
    _normalize_weekdays(data)
    return data


def _normalize_weekdays(data):
    """launchd: Weekday 0 И 7 = воскресенье. Нормализуем 7→0 на ЕДИНОЙ границе
    чтения — чтобы все потребители (doctor-коллизии, advisor, list) сравнивали
    дни одинаково даже если реестр правили руками (7 из raw plist)."""
    for j in data.get("jobs", []):
        for e in ((j.get("schedule") or {}).get("calendar") or []):
            if isinstance(e, dict) and e.get("weekday") == 7:
                e["weekday"] = 0


def migrate(data):
    """Привести реестр к текущей SCHEMA_VERSION (сейчас миграций нет — v1).

    ИНВАРИАНТ: каждый bump SCHEMA_VERSION ТРЕБУЕТ ветку миграции здесь — иначе
    validate() (строгое равенство) завернёт старый реестр, а atomic_write будет
    откатывать любую запись. Fail-closed, но чинится только новой migrate-веткой."""
    v = data.get("schema_version", 0)
    if v == 0:
        data.setdefault("jobs", [])
        data["schema_version"] = SCHEMA_VERSION
    # будущие миграции: while v < SCHEMA_VERSION: ...
    return data


def validate(data):
    """Вернуть список ошибок (пустой = valid). Не бросает — собирает всё."""
    errs = []
    if not isinstance(data, dict):
        return ["корень реестра — не mapping"]
    if data.get("schema_version") != SCHEMA_VERSION:
        errs.append(f"schema_version != {SCHEMA_VERSION} "
                    f"(got {data.get('schema_version')!r})")
    jobs = data.get("jobs")
    if not isinstance(jobs, list):
        return errs + ["'jobs' отсутствует или не список"]

    seen = set()
    for i, j in enumerate(jobs):
        tag = j.get("label", f"#{i}") if isinstance(j, dict) else f"#{i}"
        if not isinstance(j, dict):
            errs.append(f"{tag}: запись — не mapping")
            continue
        for f in REQUIRED_FIELDS:
            if not j.get(f):
                errs.append(f"{tag}: нет обязательного поля '{f}'")
        lbl = j.get("label")
        if lbl in seen:
            errs.append(f"{tag}: дублирующийся label")
        seen.add(lbl)
        if j.get("kind") and j["kind"] not in VALID_KIND:
            errs.append(f"{tag}: kind='{j['kind']}' не из {sorted(VALID_KIND)}")
        if j.get("auth") and j["auth"] not in VALID_AUTH:
            errs.append(f"{tag}: auth='{j['auth']}' не из {sorted(VALID_AUTH)}")
        if j.get("weight") and j["weight"] not in VALID_WEIGHT:
            errs.append(f"{tag}: weight='{j['weight']}' не из {sorted(VALID_WEIGHT)}")
        if j.get("status") and j["status"] not in VALID_STATUS:
            errs.append(f"{tag}: status='{j['status']}' не из {sorted(VALID_STATUS)}")
        # env_required — только ИМЕНА переменных, без значений/секретов
        for e in (j.get("env_required") or []):
            if not isinstance(e, str) or SECRET_VALUE_RE.search(e) or " " in e:
                errs.append(f"{tag}: env_required['{e}'] — должно быть ИМЯ переменной, "
                            f"не значение (схема запрещает секреты в реестре)")
        for lst in ("deps_bins", "locks", "env_required"):
            if lst in j and not isinstance(j[lst], list):
                errs.append(f"{tag}: '{lst}' должно быть списком")
        # секрет-значение в ЛЮБОМ поле джобы (не только env_required) — блок записи.
        # Вторая линия к SECRET_VALUE_RE: ловит TG-токены, url-пароли, PEM и пр.
        for reason, masked in _scan_secrets(_serialize_job(j)):
            errs.append(f"{tag}: секрет-значение в поле ({reason}, ~{masked}) — "
                        f"реестр хранит только имена/пути, не значения секретов")
    return errs


def _serialize_job(j):
    try:
        return dump_str({"schema_version": SCHEMA_VERSION, "jobs": [j]})
    except Exception:
        return str(j)


def _scan_secrets(text):
    """Обёртка над scrub.find_secrets (ленивый импорт — избежать цикла)."""
    try:
        from scrub import find_secrets
        return find_secrets(text)
    except Exception:
        return []


def dump_str(data):
    _require_yaml()
    # schema_version первым ключом — стабильный порядок для git-diff
    ordered = {"schema_version": data.get("schema_version", SCHEMA_VERSION),
               "jobs": data.get("jobs", [])}
    return yaml.safe_dump(ordered, allow_unicode=True, sort_keys=False,
                          default_flow_style=False, width=100)


def atomic_write(data, path=JOBS_YAML):
    """Атомарная запись под flock + пост-запись re-parse-валидация.

    Порядок: flock(lockfile) → temp в том же каталоге → fsync → os.replace →
    перечитать → validate. Ошибка валидации после записи = RegistryError
    (вызывающий откатывает из git).
    """
    _require_yaml()
    errs = validate(data)
    if errs:
        raise RegistryError("отказ записи: реестр не валиден:\n  " + "\n  ".join(errs))
    lock_path = path + ".lock"
    d = os.path.dirname(path) or "."
    # снапшот старого содержимого — для настоящего all-or-nothing отката (P4)
    old_bytes = None
    if os.path.exists(path):
        with open(path, "rb") as f:
            old_bytes = f.read()
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".jobs.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(dump_str(data))
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, path)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            # re-parse СТРОГО (без migrate!): migrate «чинил» бы schema_version-регресс
            # и rollback его не поймал бы. Читаем сырой yaml как есть.
            with open(path, encoding="utf-8") as rf:
                reloaded = yaml.safe_load(rf) or {}
            rerr = validate(reloaded)
            if rerr:
                # откат: восстановить прежние байты (или снести, если файла не было)
                if old_bytes is not None:
                    with open(path, "wb") as f:
                        f.write(old_bytes)
                        f.flush()
                        os.fsync(f.fileno())
                elif os.path.exists(path):
                    os.unlink(path)
                raise RegistryError("пост-запись re-parse провалился (откат выполнен):\n  "
                                    + "\n  ".join(rerr))
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def jobs_by_status(data, status):
    return [j for j in data.get("jobs", []) if j.get("status") == status]
