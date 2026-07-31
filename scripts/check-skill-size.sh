#!/usr/bin/env bash
# check-skill-size.sh — is each SKILL.md still within the size budget?
#
# Usage:
#   bash scripts/check-skill-size.sh [file ...]   # default: every SKILL.md
#
# WHY WORDS AND NOT LINES. The budget used to be "~500 lines". That number is
# not stable under reformatting: a file written in 400-character paragraphs and
# the same file wrapped at 76 columns differ by ~1.7x in line count while being
# the same text and costing the model the same context. jira-task-reviewer
# proved it — JST-230's rewrap commit alone took it 415 -> 714 lines while the
# word count moved by 5 (5,962 -> 5,967). Reviewing against the line count
# therefore flagged a "regression" that was a line-break change, and had hidden
# a real overage for as long as the file was written in 758-character lines.
#
# Words are what wrapping does not change, so words are what we bound. The line
# count is still printed, as context only — it is never what fails the check.
#
# THE TWO NUMBERS (kept in sync with AGENTS.md's "Stay under ~5,000 words"):
#   TARGET  5000  what a skill should sit under. Roughly the old ~500 lines at
#                 this repo's wrap width (~8.5-9 words/line). Over it you get a
#                 WARN: not wrong, but the next thing you add should go to
#                 skills/_shared/*.md instead.
#   CEILING 6500  hard limit; over it the script exits non-zero. Set from the
#                 largest thing the repo has actually shipped and found
#                 workable (jira-task-reviewer, ~6,100) plus headroom — not
#                 from a round number.
#
# Over the ceiling, the fix is progressive disclosure, not deletion: detail
# that is not needed on every run moves to skills/_shared/*.md and is loaded
# only when the skill says to. That is what the budget is for.

set -u

TARGET=5000
CEILING=6500

if [ $# -gt 0 ]; then
  FILES="$*"
else
  FILES=$(git ls-files '*/SKILL.md' 'SKILL.md' 2>/dev/null)
  [ -n "$FILES" ] || FILES=$(find . -name SKILL.md -not -path './.git/*' | sort)
fi

[ -n "$FILES" ] || { echo "check-skill-size: no SKILL.md found." >&2; exit 2; }

printf '%-52s %7s %7s   %s\n' "skill" "words" "lines" "status"
printf '%-52s %7s %7s   %s\n' "$(printf '%.52s' "----------------------------------------------------")" "-------" "-------" "------"

rc=0
warned=0
for f in $FILES; do
  [ -f "$f" ] || { echo "check-skill-size: no such file: $f" >&2; rc=2; continue; }
  w=$(wc -w < "$f" | tr -d ' ')
  l=$(wc -l < "$f" | tr -d ' ')
  if   [ "$w" -gt "$CEILING" ]; then status="FAIL  over the $CEILING-word ceiling by $((w - CEILING))"; rc=1
  elif [ "$w" -gt "$TARGET" ];  then status="WARN  over the $TARGET-word target by $((w - TARGET))"; warned=1
  else status="ok"
  fi
  printf '%-52s %7s %7s   %s\n' "$f" "$w" "$l" "$status"
done

echo
if [ "$rc" -eq 1 ]; then
  cat <<'EOF'
Over the ceiling. Do NOT fix this by cutting the "why" behind a rule — that is
the part that generalizes (AGENTS.md, "Explain why over stacking MUSTs"). Move
detail that is not needed on every run into skills/_shared/*.md and load it from
the skill at the point it is needed. Re-wrapping will not help: it does not
change the word count, which is the whole reason the budget is counted this way.
EOF
elif [ "$warned" -eq 1 ]; then
  echo "Over target but under the ceiling — fine to ship. Put the next addition in"
  echo "skills/_shared/*.md rather than inline, and see AGENTS.md for what belongs there."
else
  echo "All skills within budget."
fi

exit $rc
