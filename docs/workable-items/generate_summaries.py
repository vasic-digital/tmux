#!/usr/bin/env python3
"""Generate Issues_Summary.md + Fixed_Summary.md from the workable-items CLI.

Deterministic: every number is parsed from `workable-items report` output;
nothing is hand-entered. The report footer ("N row(s) reported (total in DB:
M)") is the control needle that proves the parse is complete and not blind.

Source of truth: docs/workable_items.db (via the CLI, §11.4.93/§11.4.95).
"""

import hashlib
import re
import subprocess
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "cmd/workable-items/workable-items"

STATUS_RE = re.compile(r"^(TMX-\d+) \[([^/]+)/([^\]]+)\] (.*)$")
FOOTER_RE = re.compile(r"^(\d+) row\(s\) reported \(total in DB: (\d+)\)$")


def run_report():
    out = subprocess.run(
        [str(BIN), "report"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    rows, reported, total = [], None, None
    for line in out.splitlines():
        m = STATUS_RE.match(line)
        if m:
            rows.append({"id": m.group(1), "type": m.group(2),
                         "status": m.group(3).strip(), "title": m.group(4)})
            continue
        m = FOOTER_RE.match(line.strip())
        if m:
            reported, total = int(m.group(1)), int(m.group(2))
    if total is None or reported != len(rows) or reported != total:
        raise SystemExit(
            f"control-needle FAIL: parsed {len(rows)} rows, report says "
            f"{reported}/{total} — refusing to emit a partial summary"
        )
    return rows, total


def is_terminal(item):
    return "→ Fixed.md" in item["status"]


def table(pairs):
    lines = ["| Value | Count |", "|---|---:|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(pairs.items())]
    return "\n".join(lines)


def render(path, items, title, scope):
    by_status = Counter(i["status"] for i in items)
    by_type = Counter(i["type"] for i in items)
    # §11.4.86 drift-proof fingerprint: sha256 of the SORTED item keyset,
    # NOT mtime/generation time. Two runs over unchanged data are byte-identical;
    # any changed row changes the fingerprint (deterministic, auditable).
    fingerprint = hashlib.sha256(
        "\n".join(
            f"{i['id']}|{i['type']}|{i['status']}"
            for i in sorted(items, key=lambda x: x["id"])
        ).encode()
    ).hexdigest()
    out = [
        f"# {title}",
        "",
        "**Revision:** 1",
        f"**Content SHA256:** {fingerprint}",
        "",
        "> GENERATED FILE — do not hand-edit. Every figure below is derived from",
        "> `./cmd/workable-items/workable-items report` against the git-tracked",
        "> SQLite SSoT `docs/workable_items.db` (§11.4.93 / §11.4.95).",
        "",
        "## Scope",
        "",
        scope,
        "",
        "## Counts by status",
        "",
        table(by_status),
        f"| **Total** | **{len(items)}** |",
        "",
        "## Counts by type",
        "",
        table(by_type),
        f"| **Total** | **{len(items)}** |",
        "",
        "## Per-item ledger",
        "",
        "| TMX-ID | Type | Status |",
        "|---|---|---|",
    ]
    out += [f"| {i['id']} | {i['type']} | {i['status']} |"
            for i in sorted(items, key=lambda x: x["id"])]
    out += [
        "",
        "## Provenance",
        "",
        "Control needle: the `report` footer reported the same total as the",
        "number of parsed ledger rows; a mismatch aborts generation.",
        "`Reopens` (§11.4.55) is not emitted by the current `report` command;",
        "this summary does not invent it. Honest gap, tracked under TMX-102.",
        "",
    ]
    path.write_text("\n".join(out), encoding="utf-8")
    print(f"{path.name}: {len(items)} item(s); statuses={dict(by_status)}; types={dict(by_type)}")


def main():
    rows, total = run_report()
    open_items = [r for r in rows if not is_terminal(r)]
    fixed_items = [r for r in rows if is_terminal(r)]
    if len(open_items) + len(fixed_items) != total:
        raise SystemExit("partition does not cover the DB total")
    render(ROOT / "Issues_Summary.md", open_items,
           "Issues — Workable-items Summary (generated)",
           "OPEN / non-terminal items — the rows that live in `Issues.md`.")
    render(ROOT / "Fixed_Summary.md", fixed_items,
           "Fixed — Workable-items Summary (generated)",
           "TERMINAL closure items (Fixed / Implemented / Completed / Obsolete) "
           "— the rows that live in `Fixed.md`.")
    print(f"DB total={total}; open={len(open_items)}; fixed={len(fixed_items)} "
          "(partition covers 100%)")


if __name__ == "__main__":
    main()
