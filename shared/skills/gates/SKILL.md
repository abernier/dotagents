---
name: gates
description: Run the right gate before committing, pushing or merging, and read its result honestly. Use when about to commit, push, open a PR, after a git rebase or a stack restack, or when declaring a branch ready to merge.
---

# Gates

The gate is the `lgtm` script in the repo's `package.json`: `pnpm run lgtm`.

**It is the fast suite** — typically lint, format, types, build, unit tests, plus whatever else the repo gates on. Run it before every commit, and it must be green before a push or a merge. Fix what it reports.

**If the repo defines a heavier `LGTM` script** — the same suite extended with the slow checks: performance, e2e, regression — run it only when you genuinely believe a branch is ready to merge; earlier runs slow the loop without catching more. Where a repo defines no `LGTM`, `lgtm` is the whole verdict.

**A repo's bench is a leg of `LGTM`**, never a step a skill or a review runs beside the gate: a check that runs only from `/review-merge` is missing from every other run of the gate. It takes the machine's lock as the `bench` skill says. What a script cannot decide (a phone run, an A/B on a hot path, reading a red) stays with the reviewer.

**`BENCH_SKIP=1` is the standard opt-out for the bench leg of `LGTM`.** When set (`BENCH_SKIP=1 pnpm run LGTM`), `LGTM` runs every other leg (typecheck, tests, e2e, regression, etc.) and skips only the bench leg. Use it when splitting the heavy gate onto a quiet machine (`BENCH_SKIP=1 pnpm run LGTM` locally plus `bench-remote <host> -- <bench leg>`) so the bench runs once on the calm host instead of twice.

Read the repo's `package.json` to learn what each one runs; the script owns its own legs and thresholds, this skill never restates them.

## The same gate everywhere

Same commands, same versions, same configuration in development and in CI. A check that exists only in CI, or a behaviour that appears only in production, is a bug found at the worst possible moment.

So CI reruns the same gate the laptop ran, and nothing more on the code. The gate you ran before pushing is the verdict; **a dead or budget-starved CI is never a blocker** — run the gate locally, say what it said, and carry on.

## Never pipe a gate into `tail`, `head` or `grep`

The shell returns the **last** command's status, so a failing gate piped for brevity exits 0 and reads as green. Never truncate its output either: the line you dropped is the one that said why.

```sh
pnpm run lgtm > /tmp/lgtm.log 2>&1
echo "status: $?"
```

Redirect to a file, echo the status, then read the file — the whole of it.

## Read the result honestly

**Red is a real red.** Say so and stop — including when the cause predates the branch, which is a finding of its own and belongs in its own issue rather than in the PR that happened to trip over it. A gate that failed never reaches the report as green work.

A red that goes green on the same code with nothing changed is a flake, not a pass: capture the failure first, say it flaked, and name it in the PR body. Never re-run a gate until it goes green and report only the green.

## After a rebase, the tip's typecheck decides

A clean rebase is not a correct rebase. `git rebase` — the engine behind a stack restack — replays commits **without** firing `pre-commit`, so a replay with no git conflict can still leave a broken tip: reordering a stack across a schema change leaves data in the old shape. Git reports success; only `tsc` disagrees.

So re-run the typecheck — or the whole gate — on the tip after every rebase, and **the absence of a conflict is not evidence**. Never `--no-verify` a push to skip a hook that runs it.

## Pre-merge

Before declaring a branch ready: an exhaustive review of `git diff <base>...HEAD` against the repo's own conventions, its fixes applied, then the gate — the heaviest the repo defines — on the tree that will be merged. `/review-merge` is that sequence.

## Merge the way the repo merges

Read the merge method off the main branch's history (`git log --merges -5` or `gh pr view --json mergedBy,mergeCommit`) and keep to it: a repo that squashes gets one commit per PR, a repo that merge-commits keeps its merge commits. Never switch a repo's method on your own.

A changesets "Version Packages" PR merges the same way, provided `.changeset/config.json` keeps `"commit": false` — the default, and the setting to keep: changesets/action then writes the version commit, as a plain "Version Packages". With `"commit": true` the changesets CLI writes it instead, and its default message carries `[skip ci]`; squashed or rebased, that message lands on main and the release run never starts. Fix the config; until then, merge that PR with a merge commit (`gh pr merge --merge`), whose own message tops the push, and CI runs.

## A PR opens as a draft

`gh pr create --draft`, always. A PR is not a request for review the moment it exists.

Mark it ready — `gh pr ready` — when the branch is one you would merge. That is the same explicit go the commit and the push need, not a step to fold into the opening. Nothing in CI reads the flag, so this is etiquette rather than economy: the reader is what a draft protects.

## Commits are the developer's call

Propose the commit, the push, the PR with its full details, and wait for an explicit go. Never run them silently.
