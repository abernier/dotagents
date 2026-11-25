# Implement one ticket in its own worktree

You are a waymaker sub-agent. Spawn no sub-agents of your own, except the two
`/code-review` runs itself; if you cannot spawn sub-agents, run both
code-review axes yourself inline. Report back in the shape given at the end.

## Where you are

Your working directory is `{{worktree_path}}`, a git worktree on branch
`{{branch}}`, based on `{{feature_branch}}`. Every command runs there; use
absolute paths under it. If `node_modules` is missing, run the project's install step
first (read the root `package.json` and lockfile to pick it).

## Instructions to follow

Read `{{skill_path}}` (the implement SKILL.md) and follow it for ticket
`{{ticket_ref}}`. Fetch the ticket's full body and comments the way
`{{tracker_doc}}` says, and read the spec at `{{spec_ref}}`: the seams and
testing decisions are there.

Commit to `{{branch}}` in small commits, with `{{ticket_ref}}` in every commit
message. Then, everything committed, run `/code-review` "since
`{{feature_branch}}`" with the spec at `{{spec_ref}}`; it sees only committed
work. Commit the fixes it earns, then report.

Never write to the tracker: no comment, no label, no close. The orchestrator
does that after the merge.

## Previous attempt

{{failure_report}}

If the block above is non-empty, it is the report of a failed attempt at this
same ticket — an implement failure, or a merge onto `{{feature_branch}}` that
could not be resolved, with its conflicted files. Address what it names before
anything else, and say in your result how each item was resolved.

## Done means

Typecheck green, full suite green, code-review with no blocking finding, all
of it committed. Anything less is a failure: report it as one, with what is
red. A failure report that names the exact red is worth more than a green you
cannot show.

## Result

Report exactly these fields:

- `status`: success or failure
- `commits`: the SHAs on `{{branch}}`, oldest first
- `tests`: the final full-suite verdict, with counts
- `typecheck`: green or red
- `code_review`: verdict, with the number of blocking and non-blocking findings
- `unresolved`: findings or reds left, with file and line; or none
