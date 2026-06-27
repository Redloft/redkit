# Role self-improvement loop (feedback → solidify)

The deterministic toolkit (fetch.sh/cffi_get/playbook) improves itself via
telemetry + `/finalize`. The **LLM roles** (deep-reader, source-hunter, scoper,
synth, judge) improve via a human-in-loop **feedback → solidify** loop — the
same pattern as `/panel-solidify` and `/redloft-solidify`.

## 1. Capture (cheap, during normal use)

When a role under- or over-performs, log it — one line, takes seconds:

```bash
bash lib/role-feedback.sh deep-reader "missed the pricing table — only grabbed the hero text"
bash lib/role-feedback.sh source-hunter "returned 3 SEO-aggregators instead of primary sources" 
bash lib/role-feedback.sh deep-reader "quote-extraction was spot on for the RFC" --good
bash lib/role-feedback.sh --list          # see accumulated counts
```

Feedback lands in `feedback/<role>.jsonl` (`{ts, role, kind, note}`).
Keep the positives too — they tell solidify what NOT to break.

## 2. Solidify (periodic, when ≥~5 notes for a role)

A bounded, reviewed prompt edit — NOT autonomous rewriting:

1. Read `feedback/<role>.jsonl` + the current `roles/<role>.md`.
2. Cluster the issues (recurring failure modes > one-offs). Ignore noise.
3. Propose a **minimal** prompt edit that fixes the recurring modes without
   regressing the positives. Surface trade-offs.
4. **Human reviews & applies** the edit (or asks for changes).
5. Append a line to `roles/<role>.md` changelog: `solidified YYYY-MM-DD: <what changed, which feedback ids>`.
6. Archive the consumed feedback: `mv feedback/<role>.jsonl feedback/<role>.$(date +%F).done.jsonl`.

This can be driven by an agent on request ("solidify deep-reader from feedback"),
exactly like `/panel-solidify` — the agent does steps 1–3 and proposes a diff;
you keep control of step 4.

## Guardrails (why this stays safe)
- **Never** auto-applies prompt edits — a human approves every change.
- Solidify edits **prompts only** (`roles/*.md`), never the deterministic code
  (that path is `/finalize`).
- One-off complaints don't move the prompt; only **recurring** patterns do.
- Positives are first-class: solidify must not regress what already works.
