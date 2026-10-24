# strategies/single.sh — the project is one repo: today's behaviour.
# Sourced by repos.sh, which provides ROOT, BASE_BRANCH, LIST_HEADER and the
# helpers (submodules, repo_row). One function per verb: s_<verb>.
# win/strategies/single.ps1 is the twin.

s_strategy() {
  # Submodules the project has but doesn't list in JST_MEMBERS stay pinned —
  # shown so a project that could opt in can see what it would be opting in.
  local pinned
  pinned=$(submodules | cut -f2 | paste -sd' ' -)
  printf 'strategy=single\nroot=%s\nmembers=\npinned=%s\n' "$ROOT" "$pinned"
}

s_list() {
  printf '%s\n' "$LIST_HEADER"
  repo_row . root "${BASE_BRANCH:--}" ""
}
