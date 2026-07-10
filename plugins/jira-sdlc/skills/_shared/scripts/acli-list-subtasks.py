#!/usr/bin/env python3
"""acli-list-subtasks.py — list a Jira parent's sub-tasks.

`acli jira workitem view <KEY> --json` omits `subtasks` by default, so a
naive JSON parse finds nothing. This script requests `--fields '*all'`
and prints every sub-task's key + summary. Reusable form of the check
run after bulk-seeding sub-tasks.

Requires `acli` authenticated (see ../jira-acli-reference.md §0).
Reads <PROJECT-KEY> from jira-sdlc-tools.env (override with --project
or $PROJECT_KEY); the project isn't passed to acli view but is printed
for confirmation.

Usage:
    acli-list-subtasks.py --parent <PARENT-KEY> [--env ./jira-sdlc-tools.env] [--json]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def resolve_project(env_path: str) -> str:
    """PROJECT-KEY has a hyphen, so `source` can't read it — grep it out."""
    for p in (Path(env_path), Path("jira-sdlc-tools.env"),
              Path("../jira-sdlc-tools.env")):
        if p.is_file():
            for line in p.read_text().splitlines():
                m = re.match(r"^PROJECT[-_]KEY=(.+)$", line)
                if m:
                    return m.group(1).strip()
    return os.environ.get("PROJECT_KEY", "")


def acli_view_json(parent: str) -> dict:
    out = subprocess.run(
        ["acli", "jira", "workitem", "view", parent, "--json", "--fields", "*all"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.stderr.write(out.stderr or out.stdout)
        sys.exit(out.returncode)
    raw = out.stdout
    # acli may print leading non-JSON lines; jump to the first '{'.
    start = raw.find("{")
    if start < 0:
        sys.stderr.write("acli --json output had no JSON object\n")
        sys.exit(1)
    return json.loads(raw[start:])


def main() -> int:
    ap = argparse.ArgumentParser(description="List a Jira parent's sub-tasks via acli.")
    ap.add_argument("--parent", required=True, help="Parent work item key, e.g. PROJ-32")
    ap.add_argument("--env", default="./jira-sdlc-tools.env",
                    help="Path to jira-sdlc-tools.env (for the project label only)")
    ap.add_argument("--json", action="store_true", help="Emit JSON instead of text")
    args = ap.parse_args()

    project = resolve_project(args.env)
    proj_label = f"[{project}] " if project else ""

    data = acli_view_json(args.parent)
    fields = data.get("fields", data)  # acli nests under fields
    subtasks = fields.get("subtasks") or []
    parent_type = (fields.get("issuetype") or {}).get("name", "?")

    if args.json:
        rows = [
            {"key": s.get("key"),
             "summary": (s.get("fields") or {}).get("summary")}
            for s in subtasks
        ]
        print(json.dumps({"parent": args.parent, "parent_type": parent_type,
                          "subtasks": rows}, indent=2))
        return 0

    print(f"{proj_label}parent {args.parent} ({parent_type}) — {len(subtasks)} sub-task(s):")
    if not subtasks:
        print("  (none — not a parent, or no sub-tasks attached)")
        return 0
    for s in subtasks:
        k = s.get("key", "?")
        summ = (s.get("fields") or {}).get("summary", "")
        print(f"  {k}  {summ}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
