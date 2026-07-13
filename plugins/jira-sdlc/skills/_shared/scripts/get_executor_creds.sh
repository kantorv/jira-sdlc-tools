#!/usr/bin/env bash
# get_executor_creds.sh — resolve the Jira "executor" worker identity.
#
# The jira-sdlc skills optionally run as a dedicated worker account (the
# "executor") rather than the human's default Jira account. This script is
# the ONE place that identity is resolved: it greps the project env files
# for JIRA_EXECUTOR_EMAIL / JIRA_EXECUTOR_TOKEN and falls back to
# JIRA_ACCOUNT_EMAIL / JIRA_TOKEN when those are unset or empty. Skills
# consume its output instead of reaching into the env files themselves,
# so the fallback contract lives in shell, not in LLM prose.
#
# Output (stdout) — shell-eval-able assignment lines, designed to be
# captured by `eval "$(get_executor_creds.sh)"` — capture STDOUT ONLY;
# diagnostics go to stderr and would pollute the eval blob if merged:
#   EXECUTOR_EMAIL='<resolved email>'
#   EXECUTOR_TOKEN='<resolved token, OR a path to a token file>'
#   EXECUTOR_TOKEN_IS_FILE=0|1     # 1 ⇒ EXECUTOR_TOKEN is a path to a token file
#   EXECUTOR_SITE='<JIRA_ACCOUNT_URL>'   # the Jira site for `acli jira auth login --site`
#   EXECUTOR_FALLBACK=0|1          # 1 ⇒ JIRA_EXECUTOR_EMAIL was unset/empty, so the
#                                  #   identity fell back to the default account
#
# ⚠️ The token value IS on stdout (inside the EXECUTOR_TOKEN assignment) so
# eval works — that is by design and required, since the caller evals this
# output into shell variables and then feeds EXECUTOR_TOKEN to `acli jira
# auth login --token`. The caller must NEVER echo those variables, redirect
# this script's stdout, nor merge stderr in (`2>&1`) into the eval capture —
# all of those would land the token in a Jira comment, a chat transcript,
# or a broken eval. Diagnostics (the fallback notice, the fatal
# "cannot resolve …" messages) go to STDERR only, so they never carry the
# token and never pollute the eval blob.
#
# The env-file parser (`cfg` below) is copied VERBATIM from statuscheck.sh —
# the same `NAME = value` grep and the same local-overrides-team precedence.
# Keep it in sync with that helper; do not reinvent a second parser here.
#
# Exit codes: 0 = credentials emitted on stdout; 1 = something required to
# log in as the executor could not be resolved (email, token, or site).

set -u

# Resolve the project root the same way statuscheck.sh does — the worktree
# root when inside a git repo, else the current directory — so the env files
# are found regardless of which subdirectory a skill invokes this from.
CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
CFG_DIR="${CFG_DIR:-$PWD}"

# cfg <NAME> -> value; jira-sdlc-tools.local.env overrides jira-sdlc-tools.env.
# Verbatim from statuscheck.sh — the repo's one env-file parser.
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$CFG_DIR/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$CFG_DIR/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# emit <NAME> <value> — print `NAME='value'` with single quotes escaped so
# the line is safe for `eval`. The value flows through printf (a bash
# builtin → no fork, no argv leak) into sed's stdin (sed's argv is just the
# program, never the value), so the token never appears in any external
# process's command line.
emit() {
  printf "%s='" "$1"
  printf '%s' "$2" | sed "s/'/'\\\\''/g"
  printf "'\n"
}

# --- resolve email ---------------------------------------------------------
# JIRA_EXECUTOR_EMAIL (optional) → JIRA_ACCOUNT_EMAIL (fallback). A missing
# email is fatal: the executor cannot log in and the assigner cannot assign
# on create without one.
EXECUTOR_EMAIL=$(cfg JIRA_EXECUTOR_EMAIL || true)
EXECUTOR_FALLBACK=0
if [ -z "$EXECUTOR_EMAIL" ]; then
  EXECUTOR_FALLBACK=1
  EXECUTOR_EMAIL=$(cfg JIRA_ACCOUNT_EMAIL || true)
fi
if [ -z "$EXECUTOR_EMAIL" ]; then
  echo "get_executor_creds.sh: cannot resolve an executor email — neither" \
       "JIRA_EXECUTOR_EMAIL nor JIRA_ACCOUNT_EMAIL is set in" \
       "$CFG_DIR/jira-sdlc-tools(.local).env." >&2
  exit 1
fi

# --- resolve token (raw value OR path to a file — same two forms as JIRA_TOKEN)
EXECUTOR_TOKEN=$(cfg JIRA_EXECUTOR_TOKEN || true)
[ -z "$EXECUTOR_TOKEN" ] && EXECUTOR_TOKEN=$(cfg JIRA_TOKEN || true)
if [ -z "$EXECUTOR_TOKEN" ]; then
  echo "get_executor_creds.sh: cannot resolve a token — neither JIRA_EXECUTOR_TOKEN" \
       "nor JIRA_TOKEN is set in $CFG_DIR/jira-sdlc-tools(.local).env." >&2
  exit 1
fi
# JIRA_TOKEN / JIRA_EXECUTOR_TOKEN may hold the raw token OR a path to a
# token file (project-config.md documents both forms; the acli reference §0
# notes acli can't tell them apart from stdin). Detect which by whether the
# value points at an existing file.
if [ -f "$EXECUTOR_TOKEN" ]; then
  EXECUTOR_TOKEN_IS_FILE=1
else
  EXECUTOR_TOKEN_IS_FILE=0
fi

# --- resolve site (the Jira site — shared, no executor-specific override) ---
# There is no JIRA_EXECUTOR_URL: the site is the same regardless of which
# account logs in, so it always comes from JIRA_ACCOUNT_URL.
EXECUTOR_SITE=$(cfg JIRA_ACCOUNT_URL || true)
if [ -z "$EXECUTOR_SITE" ]; then
  echo "get_executor_creds.sh: JIRA_ACCOUNT_URL is unset in" \
       "$CFG_DIR/jira-sdlc-tools(.local).env — needed for" \
       "'acli jira auth login --site'." >&2
  exit 1
fi

# --- diagnostics (stderr only) + emit (stdout, eval-able) ------------------
if [ "$EXECUTOR_FALLBACK" = 1 ]; then
  echo "get_executor_creds.sh: JIRA_EXECUTOR_EMAIL is unset/empty — falling" \
       "back to JIRA_ACCOUNT_EMAIL (the default account). The executor will" \
       "re-log acli in as THAT account; acli's credential store is" \
       "machine-global and single-active-account, so every other shell and" \
       "skill on this machine will run as it too until re-logged." >&2
fi
emit EXECUTOR_EMAIL "$EXECUTOR_EMAIL"
emit EXECUTOR_TOKEN "$EXECUTOR_TOKEN"
printf 'EXECUTOR_TOKEN_IS_FILE=%s\n' "$EXECUTOR_TOKEN_IS_FILE"
emit EXECUTOR_SITE "$EXECUTOR_SITE"
printf 'EXECUTOR_FALLBACK=%s\n' "$EXECUTOR_FALLBACK"
