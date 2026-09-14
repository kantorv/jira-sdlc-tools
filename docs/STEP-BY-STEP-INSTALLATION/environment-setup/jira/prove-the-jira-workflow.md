---
slug: /step-by-step-installation/prove-the-jira-workflow
sidebar_position: 7
sidebar_label: Prove the Jira workflow
---

# Prove the Jira workflow

Knowing that the four names exist is not enough: the workflow must also permit
the transitions the skills will attempt. Ask before creating a live scratch issue
because it appears briefly on the board and can trigger notifications.

When approved, use an issue type that exists in the project (replace `Task` if
that type is unavailable):

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"
KEY=$(bash "$S/jira.sh" --role assigner issue create --project <PROJECT-KEY> \
        --type Task --summary 'jst-install smoke test — safe to delete')
for s in "<STATUS_TODO>" "<STATUS_IN_PROGRESS>" "<STATUS_IN_REVIEW>" "<STATUS_DONE>"; do
  if bash "$S/jira.sh" --role executor issue transition "$KEY" --to "$s"
    then echo "allowed: $s"; else echo "not offered from the current status: $s"; fi
done
bash "$S/jira.sh" --role assigner issue delete "$KEY" --with-subtasks
bash "$S/jira.sh" --role executor issue view "$KEY" --fields summary
echo "deleted if that exited 4 (HTTP 404): $?"
```

A refused transition is a fact about the board's workflow, not automatically a
configuration error; the point is to discover the real transitions. Verify the
delete by confirming the follow-up `view` returns HTTP 404 / exit 4.

If this smoke test is skipped, the status names and workflow remain unverified.
