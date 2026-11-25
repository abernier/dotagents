---
description: Undo what this session created — the inventory first, an explicit go, then destroy in order of reversibility
argument-hint: "[scope]"
disable-model-invocation: true
---

Undo what **this session** produced. Not the branch, not the worktree, not the
repository — what this session added on top of what it found.

`$ARGUMENTS` narrows the scope when present (`scratchpad`, `pr`, `branch`,
`memory`, `worktree`). Absent, it means everything below, still one item at a
time.

## Never destroy on the word alone

"Supprime tout" is a scope, not a target list. **Build the inventory first,
show it, and wait for an explicit go** — even when the ask is emphatic, even
when it is repeated. An emphatic ask settles *whether*, never *what*: the two
are different questions and only the first one was answered.

Repeating the inventory after a second insistence is not obstruction. Deleting
the wrong item is not recoverable by insisting harder.

## Stop the writers first

A background agent, a monitor, a detached bash still running will write back
into what you just cleaned, and a bench mid-flight holds the bench lock (the
`bench` skill) and may hold a spool. **Enumerate and stop them before deleting
anything** — otherwise the abort is a race it loses silently.

Do not kill another *session*. A peer writing in the same tree is a separate
problem with a separate decision; report it and leave it alone.

## Write down the exit before you take it

Before anything is destroyed, print what makes a restore possible and keep it
in the reply, not in a file you are about to delete:

- the tip SHA and the base SHA, in full
- the branch name, and whether it was pushed
- the PR number

It costs nothing and it is the only door left afterwards.

## What is this session's, and what only looks like it

The branch is not the unit. **A commit on it may belong to someone else** — a
peer session working in the same tree, a `Co-Authored-By` or session trailer
that is not this session's, an author time before this session started. Read
the trailers rather than assuming the branch is yours end to end.

If any commit is not this session's, say so by SHA and subject, and treat the
branch as shared: deleting it takes that work too, which is a different
decision and needs its own go.

Also outside the scope, whatever the ask sounds like:

- anything that existed before the session opened
- anything already merged — a merged change is not abortable, say so plainly
- other worktrees, other branches, other sessions' output
- the repository's own history

## The order is reversibility, least destructive first

1. **Scratchpad and working files** — probes, logs, generated artifacts. Free.
2. **The PR** — close it. A closed PR reopens; say so.
3. **The remote branch** — deletable, and restorable from the closed PR's page
   for a while. `gh pr close --delete-branch` does both 2 and 3, and also drops
   the local branch: say which of the three you actually intend.
4. **The local branch and its commits** — the reflog holds them for now.
5. **Memory written this session** — the files added under the agent memory
   directory, the paragraphs appended to existing ones, the index lines. An
   edit to a pre-existing memory is reverted, never the whole file deleted.
6. **The worktree itself** — last, and only when asked for by name. You are
   standing in it: removing it ends the session's ability to do anything else,
   so say that before doing it rather than after.

Stop at the last item the go actually covered.

## Report what happened, not what was attempted

A table of what is gone and what remains, and the restore handles repeated at
the end. If something refused — a locked worktree, a protected branch, a PR
already merged — name it and leave it; do not force it, and do not reach for a
harder tool to get past it.
