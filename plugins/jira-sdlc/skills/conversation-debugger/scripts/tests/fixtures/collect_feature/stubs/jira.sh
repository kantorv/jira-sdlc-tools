#!/usr/bin/env bash
# Harness stub for the shared jira.sh client — replays the one Jira call
# collect_feature makes (`--role <role> issue view <KEY> --fields summary,subtasks`)
# from $CF_FIXTURE_WORK/jira.json. Staged next to the stub siblings, which is
# where collect_feature looks for a jira client before falling back to _shared/.
cat "$CF_FIXTURE_WORK/jira.json"
