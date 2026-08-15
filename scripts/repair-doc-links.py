#!/usr/bin/env python3
"""Repair every reference to the documentation corpus after the move to docs/ (JST-287).

Four categories of reference break when `plugins/jira-sdlc/docs/` becomes `docs/`,
and each needs a different fix. This script applies all four mechanically, because
hand-editing 350+ links is how you introduce a typo nobody notices in review.

  1. Between published docs (docs/** -> docs/**)
       The whole subtree moved as a unit, so relative paths between its files are
       already correct. The script re-derives them anyway and reports any that do
       not resolve, which is how the five pre-existing `../APPLICATIONS.md` links
       got found.

  2. Published doc -> unpublished file (.github/workflows/*, AGENTS.md, CLAUDE.md,
     the plugin's own skills and scripts)
       Must become absolute github.com blob/tree URLs. Docusaurus emits such links
       unchanged, so the site build cannot see this category at all — it is checked
       by scripts/check-doc-links.sh instead.

  3. README.md and INTEGRATIONS.md
       Rendered by GitHub against its own domain and also fed to the site, from a
       location outside the docs root. Every relative link becomes absolute.

  4. Paths the plugin itself names (plugins/jira-sdlc/**)
       A marketplace install copies only plugins/jira-sdlc/ into the plugin cache,
       so after the move an installed user has no docs/ at all. Anything they read
       without a checkout gets the published site URL; comments read while editing
       the code in a checkout keep a repo-relative path.

Idempotent: re-running makes no further changes. Keep it in the repo so the next
person who moves a doc can re-run it rather than re-deriving the rules.

    python3 scripts/repair-doc-links.py            # rewrite in place
    python3 scripts/repair-doc-links.py --check    # exit 1 if anything would change
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = json.load(open(os.path.join(REPO, "scripts", "docs-url-map.json"), encoding="utf-8"))

SITE = MAP["site_docs_base"]
BLOB = MAP["blob_base"]
TREE = MAP["tree_base"]
RAW = MAP["raw_base"]
PAGES = MAP["pages"]
UNPUBLISHED = set(MAP["unpublished"])

OLD_DOCS = "plugins/jira-sdlc/docs/"
NEW_DOCS = "docs/"

# Files read only inside a checkout: they keep repo-relative paths, so the only
# repair they need is the moved prefix.
CONTRIBUTOR_ONLY = {"AGENTS.md", "CLAUDE.md"}
# Published, but living outside the docs root — every link goes absolute.
ROOT_PUBLISHED = {"README.md", "INTEGRATIONS.md"}
# Owned by JST-289; three comment lines naming a doc path are left for that sub-task.
SKIP_PREFIXES = (".github/", "website/", "venv/", "scripts/docs-url-map.json")

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp")

# ]( target ) for markdown, href="target" / src="target" for the raw HTML the
# READMEs and TASK-LIFECYCLE.md use for their diagram tables.
MD_LINK = re.compile(r"(?P<pre>\]\()(?P<t>[^)\s]+)(?P<post>(?:\s+\"[^\"]*\")?\))")
HTML_ATTR = re.compile(r"(?P<pre>\b(?:href|src)=\")(?P<t>[^\"]+)(?P<post>\")")


def is_external(target: str) -> bool:
    return target.startswith(("http://", "https://", "mailto:", "#", "//", "<"))


def remap(path: str) -> str:
    """Old repo path -> new repo path."""
    if path == "plugins/jira-sdlc/docs":
        return "docs"
    if path.startswith(OLD_DOCS):
        return NEW_DOCS + path[len(OLD_DOCS):]
    return path


def absolute(path: str, frag: str) -> str:
    base = os.path.join(REPO, path)
    if path.lower().endswith(IMAGE_EXT):
        return f"{RAW}/{path}{frag}"
    if os.path.isdir(base):
        return f"{TREE}/{path}{frag}"
    return f"{BLOB}/{path}{frag}"


def site_url(path: str, frag: str) -> str:
    """Published site URL for a doc page — the category-4 target."""
    page = PAGES.get(path)
    if page is None:
        return absolute(path, frag)
    return f"{SITE}{page['slug']}{frag}"


def rewrite_target(src: str, target: str) -> str:
    if is_external(target):
        return target
    raw_path, _, frag = target.partition("#")
    if not raw_path:
        return target
    frag = "#" + frag if frag else ""

    # Resolve against where the link was *written*, not where the file sits now.
    # Everything under docs/ moved as a unit, so its outbound `../../../../…`
    # targets were counted from plugins/jira-sdlc/docs/; resolving those against
    # the new location walks off the top of the repo (and, worse, sometimes lands
    # on a same-named file at the root instead — `../README.md` meant the plugin
    # README, not this one). Every other file stayed put and needs no such shift.
    origin = OLD_DOCS + src[len(NEW_DOCS):] if src.startswith(NEW_DOCS) else src
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(origin), raw_path))
    resolved = remap(resolved)

    if src in CONTRIBUTOR_ONLY:
        # Repo-relative, from the repo root: these files are only ever read in a
        # checkout, and AGENTS.md's own convention is a plain repo path.
        return resolved + frag

    if src in ROOT_PUBLISHED:
        return absolute(resolved, frag)

    if src.startswith("plugins/jira-sdlc/"):
        if resolved.startswith(NEW_DOCS):
            return site_url(resolved, frag)
        # Still inside the plugin: keep it relative so it resolves post-install,
        # except in the plugin README, which is also a published page.
        if src == "plugins/jira-sdlc/README.md":
            return absolute(resolved, frag)
        return target

    if src.startswith(NEW_DOCS):
        inside_docs = resolved.startswith(NEW_DOCS)
        if inside_docs and resolved not in UNPUBLISHED:
            rel = posixpath.relpath(resolved, posixpath.dirname(src))
            return rel + frag
        return absolute(resolved, frag)

    return target


# A link whose *text* is the path it points at goes stale the same way the
# target does — `[../skills/_shared/project-config.md](https://…/plugins/…)`
# names a directory hop that no longer exists from here. Re-derive the text
# from the URL so the two can't drift again.
TEXT_IS_PATH = re.compile(
    r"\[(?P<tick>`?)(?P<text>(?:\.\./)+[^\]`]+?)(?P=tick)\]"
    r"\((?P<url>" + re.escape(BLOB) + r"/(?P<path>[^)#\s]+)[^)\s]*)\)"
)


def retitle_path_links(text: str) -> str:
    def sub(m):
        tick = m["tick"]
        body = m["path"] if tick else m["path"].replace("_", r"\_")
        return f"[{tick}{body}{tick}]({m['url']})"
    return TEXT_IS_PATH.sub(sub, text)


def front_matter(path: str, text: str) -> str:
    """Prepend slug/sidebar_position. No `id:` — doc IDs are path-derived and a
    front-matter id: is a *suffix* on that path, which fails the build."""
    page = PAGES.get(path)
    if page is None or text.startswith("---\n"):
        return text
    # `title:` only for the handful of docs with no `# ` heading to derive one
    # from — adding it where an h1 exists renders the heading twice.
    title = f"title: {page['title']}\n" if "title" in page else ""
    return (
        "---\n"
        f"{title}"
        f"slug: {page['slug']}\n"
        f"sidebar_position: {page['sidebar_position']}\n"
        "---\n\n"
    ) + text


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-files", "*.md", "*.sh", "*.ps1", "*.example"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return [f for f in out if f and not f.startswith(SKIP_PREFIXES)]


def process(path: str) -> tuple[str, str]:
    full = os.path.join(REPO, path)
    original = open(full, encoding="utf-8").read()
    text = original

    if path.endswith(".md"):
        def sub(m):
            return m["pre"] + rewrite_target(path, m["t"]) + m["post"]
        text = MD_LINK.sub(sub, text)
        text = HTML_ATTR.sub(sub, text)
        text = retitle_path_links(text)
        text = front_matter(path, text)

    # Bare (unlinked) mentions of the old location, in prose and in script
    # comments alike. `docs/…` is the correct repo-relative form everywhere the
    # reader has a checkout; the plugin-side exceptions are handled by hand and
    # no longer contain the old prefix by the time this runs.
    text = text.replace(OLD_DOCS, NEW_DOCS)

    return original, text


def main() -> int:
    check = "--check" in sys.argv
    changed = []
    for path in tracked_files():
        original, text = process(path)
        if text != original:
            changed.append(path)
            if not check:
                open(os.path.join(REPO, path), "w", encoding="utf-8").write(text)

    verb = "would change" if check else "rewrote"
    for path in changed:
        print(f"  {verb}: {path}")
    print(f"{len(changed)} file(s) {verb}.")
    return 1 if (check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
