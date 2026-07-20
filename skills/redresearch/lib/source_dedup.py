#!/usr/bin/env python3
"""
source_dedup.py — canonical-key нормализация + дедупликация источников для redresearch.

Зачем (plan-panel 2026-07-20, доминирующий critical, конвергенция 5 ролей):
когда источники приходят из нескольких движков (Serper/WebSearch + Exa + academic +
Perplexity), один и тот же источник не должен читаться deep-reader'ом дважды, а judge/C4
должны отличать «два независимых источника» от «один найден двумя движками».

Контракт:
    normalize_source_key(url) -> canonical_key (str)
        - strip fragment + tracking-параметры (utm_*, ref, fbclid, gclid, ...)
        - unify scheme (→https для ключа) + host (lowercase, strip www)
        - trailing slash нормализуется
        - arxiv abs↔pdf → один ключ (arxiv:ID)
        - DOI (doi.org/… или arxiv) → ключ doi:… ; DOI приоритетнее URL
    dedup_sources(sources, *, doi_field="doi") -> {kept, dropped, index}
        - kept: список источников, каждый с added-полями _canonical_key + _engines[]
        - при дубле остаётся источник с бОльшим score (tie → первый), провенанс движков сливается
        - DOI-ключ побеждает URL-ключ (если у любого дубля есть DOI)

CLI:
    echo '<json массив sources>' | source_dedup.py            # → deduped json массив (stdout)
    source_dedup.py --self-test                                 # unit+integration тесты (exit 0/1)

Источник в JSON: {url, title?, snippet?, score?, doi?, engine?|_engines?}
"""
import sys, json, re
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

# tracking-параметры, которые НЕ влияют на идентичность контента
_TRACKING_RE = re.compile(r'^(utm_|ga_|_hs|mc_|pk_)', re.I)
_TRACKING_EXACT = {
    "ref", "referrer", "fbclid", "gclid", "dclid", "yclid", "msclkid",
    "igshid", "source", "spm", "cmpid", "cid", "ncid", "_ga", "gws_rd",
}

_ARXIV_RE = re.compile(r'arxiv\.org/(?:abs|pdf|html)/([0-9]{4}\.[0-9]{4,5}(?:v[0-9]+)?)', re.I)
_DOI_IN_URL_RE = re.compile(r'(?:doi\.org/|/doi/(?:abs/|full/|pdf/)?)(10\.\d{4,9}/[^\s?#]+)', re.I)
_DOI_BARE_RE = re.compile(r'^(?:doi:)?\s*(10\.\d{4,9}/\S+)$', re.I)


def _normalize_doi(doi: str) -> str:
    doi = doi.strip().lower()
    m = _DOI_BARE_RE.match(doi)
    if m:
        doi = m.group(1)
    return "doi:" + doi.rstrip("/.")


def normalize_source_key(url: str, doi: str | None = None) -> str:
    """Каноничный ключ идентичности источника. DOI приоритетнее URL."""
    if doi:
        return _normalize_doi(doi)
    if not url:
        return ""
    url = url.strip()

    # DOI, спрятанный в URL (doi.org/10.… или журнальный /doi/…)
    m = _DOI_IN_URL_RE.search(url)
    if m:
        return _normalize_doi(m.group(1))

    # arxiv abs↔pdf → единый ключ (без версии — v1/v2 = один препринт)
    m = _ARXIV_RE.search(url)
    if m:
        arxiv_id = m.group(1).lower().split("v")[0]
        return "arxiv:" + arxiv_id

    parts = urlsplit(url if "://" in url else "https://" + url)
    scheme = "https"  # схема не влияет на идентичность
    host = (parts.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    port = "" if parts.port in (None, 80, 443) else ":%d" % parts.port

    # путь: убрать trailing slash (кроме корня)
    path = parts.path or "/"
    if len(path) > 1:
        path = path.rstrip("/")

    # query: выкинуть tracking, отсортировать остаток (порядок не влияет)
    kept_q = []
    for k, v in parse_qsl(parts.query, keep_blank_values=True):
        if _TRACKING_RE.match(k) or k.lower() in _TRACKING_EXACT:
            continue
        kept_q.append((k, v))
    query = urlencode(sorted(kept_q))

    return urlunsplit((scheme, host + port, path, query, ""))  # fragment всегда отброшен


def _score(x) -> float:
    """Безопасное приведение score (нечисловой score от движка не должен ронять весь дедуп)."""
    try:
        return float(x or 0)
    except (TypeError, ValueError):
        return 0.0


def _engines_of(s: dict) -> list:
    if s.get("_engines"):
        return list(s["_engines"])
    # контракт SourceEngine помечает движок в source_id; engine — legacy-алиас
    e = s.get("source_id") or s.get("engine")
    return [e] if e else []


def dedup_sources(sources, doi_field: str = "doi"):
    """
    Слить дубликаты по canonical_key. Возвращает {kept, dropped, index}.
    kept: победитель на ключ (макс score), с _canonical_key и слитым _engines[].
    """
    index = {}   # canonical_key -> winner source
    order = []   # для стабильного порядка
    dropped = []
    for s in sources:
        if not isinstance(s, dict):
            continue
        key = normalize_source_key(s.get("url", ""), s.get(doi_field))
        if not key:
            continue
        engines = _engines_of(s)
        if key not in index:
            w = dict(s)
            w["_canonical_key"] = key
            w["_engines"] = engines
            index[key] = w
            order.append(key)
        else:
            w = index[key]
            # объединённый провенанс = движки текущего победителя + движки новой записи.
            # НЕ мутируем w["_engines"] in-place: иначе dropped-запись унесёт движок,
            # добавленный в ЭТОЙ итерации, и провенанс dropped станет недостоверным.
            merged = list(w["_engines"])
            for e in engines:
                if e not in merged:
                    merged.append(e)
            # победитель — больший score (safe-coercion, не роняем дедуп на мусорном score)
            if _score(s.get("score")) > _score(w.get("score")):
                w2 = dict(s)
                w2["_canonical_key"] = key
                w2["_engines"] = merged          # новый победитель получает полный провенанс
                index[key] = w2
                dropped.append(w)                # старый победитель — со своим набором, без мутации
            else:
                w["_engines"] = merged           # победитель остаётся — обновляем ТОЛЬКО его провенанс
                dropped.append(s)
    kept = [index[k] for k in order]
    return {"kept": kept, "dropped": dropped, "index": {k: index[k].get("url") for k in order}}


# ─────────────────────────── self-test ───────────────────────────
def _self_test() -> int:
    fails = []
    checks = [0]

    def eq(a, b, msg):
        checks[0] += 1
        if a != b:
            fails.append("%s: %r != %r" % (msg, a, b))

    # arxiv abs↔pdf↔html + версия → один ключ
    k_abs = normalize_source_key("https://arxiv.org/abs/2301.01234")
    k_pdf = normalize_source_key("https://arxiv.org/pdf/2301.01234v2")
    k_html = normalize_source_key("https://arxiv.org/html/2301.01234v1")
    eq(k_abs, k_pdf, "arxiv abs==pdf")
    eq(k_abs, k_html, "arxiv abs==html")
    eq(k_abs, "arxiv:2301.01234", "arxiv canonical")

    # DOI: doi.org, журнальный /doi/, bare, поле doi — всё в один ключ
    d1 = normalize_source_key("https://doi.org/10.1145/3292500.3330701")
    d2 = normalize_source_key("https://dl.acm.org/doi/abs/10.1145/3292500.3330701")
    d3 = normalize_source_key("", "10.1145/3292500.3330701")
    eq(d1, d2, "doi.org==journal /doi/")
    eq(d1, d3, "doi url==doi field")
    eq(d1, "doi:10.1145/3292500.3330701", "doi canonical")

    # tracking/query strip + scheme/www/trailing-slash
    a = normalize_source_key("http://www.Example.com/Page/?utm_source=x&fbclid=y&a=1#frag")
    b = normalize_source_key("https://example.com/Page?a=1")
    eq(a, b, "tracking+scheme+www+slash+frag")

    # разные страницы одного домена — РАЗНЫЕ ключи (не переслить)
    p1 = normalize_source_key("https://example.com/a")
    p2 = normalize_source_key("https://example.com/b")
    if p1 == p2:
        fails.append("different paths collapsed")

    # DOI приоритетнее URL: тот же контент, один с url, другой с doi → один ключ
    doi_url = normalize_source_key("https://any.mirror.net/paper", "10.9999/xyz")
    doi_only = normalize_source_key("", "10.9999/xyz")
    eq(doi_url, doi_only, "doi beats url")

    # integration: overlap двух движков (по source_id-контракту) → ОДИН kept, оба в провенансе
    srcs = [
        {"url": "https://arxiv.org/html/2301.01234", "score": 0.8, "source_id": "exa"},
        {"url": "https://arxiv.org/pdf/2301.01234v2", "score": 0.9, "source_id": "serper"},
        {"url": "https://example.com/other", "score": 0.5, "source_id": "serper"},
    ]
    r = dedup_sources(srcs)
    eq(len(r["kept"]), 2, "overlap→2 kept")
    arxiv = next(s for s in r["kept"] if s["_canonical_key"].startswith("arxiv:"))
    eq(sorted(arxiv["_engines"]), ["exa", "serper"], "provenance merged (source_id)")
    eq(arxiv.get("score"), 0.9, "winner=higher score")

    # crash-guard: нечисловой score от движка НЕ роняет дедуп (fail-open инвариант)
    try:
        r2 = dedup_sources([
            {"url": "https://a.com/x", "score": "bad", "source_id": "exa"},
            {"url": "https://a.com/x", "score": 0.5, "source_id": "serper"},
        ])
        eq(len(r2["kept"]), 1, "bad-score→no-crash, 1 kept")
        eq(_score("bad"), 0.0, "bad score coerces to 0")
    except Exception as e:
        fails.append("bad-score crashed dedup: %r" % e)

    # провенанс dropped-записи не мутируется задним числом (aliasing fix)
    r3 = dedup_sources([
        {"url": "https://p.com/1", "score": 0.5, "source_id": "A"},
        {"url": "https://p.com/1", "score": 0.9, "source_id": "B"},
        {"url": "https://p.com/1", "score": 0.99, "source_id": "C"},
    ])
    eq(sorted(r3["kept"][0]["_engines"]), ["A", "B", "C"], "winner has full provenance")
    b_dropped = next(s for s in r3["dropped"] if s.get("source_id") == "B")
    if "C" in b_dropped.get("_engines", []):
        fails.append("dropped B retroactively gained engine C (aliasing)")

    if fails:
        print("✗ source_dedup self-test FAILED:")
        for f in fails:
            print("  -", f)
        return 1
    print("✓ source_dedup self-test passed (%d checks)" % checks[0])
    return 0


def main():
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    raw = sys.stdin.read().strip()
    if not raw:
        print("[]")
        return
    data = json.loads(raw)
    if isinstance(data, dict):
        data = data.get("sources") or data.get("results") or []
    out = dedup_sources(data)
    json.dump(out["kept"], sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
