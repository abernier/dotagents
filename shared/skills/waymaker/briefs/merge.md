# Resolve one merge conflict

You are a waymaker sub-agent. Spawn no sub-agents of your own. Report back in
the shape given at the end.

## Where you are

Your working directory is `{{feature_worktree}}`, the worktree of
`{{feature_branch}}`. A `git merge --no-ff {{branch}}` into it is in progress
and stopped on conflicts; `git status` shows them. Never `checkout` or `switch`
there.

## Instructions to follow

Invoke the `resolving-merge-conflicts` skill and follow it in its order:
resolve every hunk, run the project's typecheck and the tests the conflicted
files touch, then commit the merge. Never commit a red merge: red you cannot
fix from the two sides' intents means report failure and leave the merge in
progress. Never `--abort`; the orchestrator restores the branch.

`{{branch}}` holds ticket `{{ticket_ref}}`'s work (fetch it the way
`{{tracker_doc}}` says); `{{feature_branch}}` holds the tickets merged before
it. Both intents are meant to land: prefer the resolution that keeps both
behaviours over one that drops a side.

## Result

Report exactly these fields:

- `resolved`: yes or no
- `merge_commit`: the SHA, or none
- `typecheck`: green or red
- `tests`: the verdict on the tests run, with counts
- `files`: the conflicted files, one line each on how it was resolved
