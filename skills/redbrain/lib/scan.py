#!/usr/bin/env python3
"""redbrain scan — детерминированная часть ingest (без LLM).

Для каждого *.md в источнике:
  1. content_hash (sha256) → сверка с sources: не менялся → skip (идемпотентность,
     Haiku не вызывается повторно — это и есть защита от недетерминизма LLM);
  2. secret-scrub ПЕРЕД тем как текст уйдёт в LLM: вставленный когда-то ключ не
     должен стать постоянным извлекаемым узлом графа;
  3. frontmatter (name/description/type) и wikilinks [[x]] парсятся детерминированно
     в det_triples — caller ОБЯЗАН слить их с LLM-триплетами и вставить ОДНИМ
     graphdb insert на документ (insert делает tombstone по source_id: две
     отдельные вставки для одного документа затёрли бы друг друга);
  4. pending-документы выгружаются в scrubbed-файлы для LLM-экстракции caller'ом.

Usage: scan.py <dir> [--force] [--prefix <str>]
  --prefix: namespace для source_id (напр. "projects/") — обязателен при
  инжесте второй директории, иначе одноимённые файлы из разных папок
  затирают друг друга tombstone'ом (source_id = prefix + basename).
Stdout: JSON {pending:[{source_id, content_hash, scrubbed_path, name, det_triples}],
              skipped: N, redactions: N, run_id}
"""
import sys, os, re, json, hashlib, subprocess, tempfile, uuid

LIB = os.path.dirname(os.path.abspath(__file__))
SECRET_PATTERNS = re.compile(
    r"(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}"
    r"|AIza[A-Za-z0-9_-]{10,}|op://[^\s\"')]+|xox[baprs]-[A-Za-z0-9-]{8,}"
    r"|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
    r"|Bearer\s+[A-Za-z0-9._~+/-]{16,}=*"
    r"|AKIA[0-9A-Z]{16}"                                    # AWS access key
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"
    r"|[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]{4,}@"          # scheme://user:pass@
    r"|(?:password|passwd|secret|client_secret|api_key|apikey|access_token)"
    r"\s*[:=]\s*['\"]?[A-Za-z0-9._~+/-]{12,}['\"]?)",
    re.IGNORECASE)

def scrub(text):
    return SECRET_PATTERNS.subn("[REDACTED-SECRET]", text)

def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m: return {}
    fm = {}
    for line in m.group(1).splitlines():
        kv = re.match(r"^(\w[\w-]*):\s*(.+)$", line.strip())
        if kv: fm[kv.group(1)] = kv.group(2).strip().strip("'\"")
    return fm

def db(cmd_args, stdin=None):
    r = subprocess.run([sys.executable, os.path.join(LIB, "graphdb.py")] + cmd_args,
                       input=stdin, capture_output=True, text=True)
    if r.returncode != 0: sys.exit(f"graphdb {cmd_args[0]} failed: {r.stderr}")
    return r.stdout.strip()

def main():
    src_dir = sys.argv[1]
    force = "--force" in sys.argv
    prefix = sys.argv[sys.argv.index("--prefix") + 1] if "--prefix" in sys.argv else ""
    run_id = f"scan-{uuid.uuid4().hex[:8]}"
    out_dir = tempfile.mkdtemp(prefix="redbrain-scrub-")
    pending, skipped, redactions = [], 0, 0

    for fn in sorted(os.listdir(src_dir)):
        if not fn.endswith(".md") or fn == "MEMORY.md": continue
        path = os.path.join(src_dir, fn)
        raw = open(path, encoding="utf-8").read()
        chash = hashlib.sha256(raw.encode()).hexdigest()[:16]
        sid = prefix + fn
        if not force and db(["check", sid, chash]) == "skip":
            skipped += 1; continue

        clean, n_red = scrub(raw); redactions += n_red
        fm = frontmatter(clean)
        doc_name = fm.get("name", fn.removesuffix(".md"))

        # бесплатные детерминированные рёбра: doc→type, doc→[[wikilink]].
        # НЕ вставляем здесь — отдаём caller'у для слияния с LLM-триплетами
        # в единый insert (tombstone-семантика: один документ = одна вставка).
        det = []
        if fm.get("type"):
            det.append({"src": doc_name, "src_type": "memory-doc",
                        "relation": "has_type", "dst": fm["type"], "dst_type": "memory-type"})
        for link in set(re.findall(r"\[\[([^\]|#]+)\]\]", clean)):
            det.append({"src": doc_name, "src_type": "memory-doc",
                        "relation": "links_to", "dst": link.strip(), "dst_type": "memory-doc"})

        spath = os.path.join(out_dir, fn)
        open(spath, "w", encoding="utf-8").write(clean)
        pending.append({"source_id": sid, "content_hash": chash,
                        "scrubbed_path": spath, "name": doc_name, "det_triples": det})

    # scope в выводе — entry-point видимость границы двух мозгов: caller ОБЯЗАН
    # сверить, что scope совпадает с намерением, до insert'ов
    print(json.dumps({"scope": os.environ.get("REDBRAIN_SCOPE", "work (default!)"),
                      "pending": pending, "skipped": skipped, "redactions": redactions,
                      "run_id": run_id, "scrub_dir": out_dir}, ensure_ascii=False, indent=1))

if __name__ == "__main__":
    main()
