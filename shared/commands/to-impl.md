---
description: Run to-spec, to-tickets and implement-spec back to back on the current conversation, with no confirmation stop — every question the skills would ask is answered by you and recorded. --drawer adds one stop, the scope picker of to-spec-drawer
argument-hint: "[--drawer] [focus or extra context]"
disable-model-invocation: true
---

Chain three mattpocock-skills in one run, from this conversation to an
integration branch: **to-spec**, then **to-tickets** on that spec, then
**implement-spec** on that spec and its tickets. The user does not confirm
anything in between, unless they asked for the one stop `--drawer` adds.

## Reading `$ARGUMENTS`

- `--drawer`, anywhere in the arguments: Phase 1 runs through to-spec-drawer,
  and the run pauses once, on its scope picker. Absent: no pause at all.
- Everything else is extra context or a focus for the spec; read it as part of
  the conversation.

## Why the skills are read, not invoked

The three skills are `disable-model-invocation`: the Skill tool refuses them.
So you follow each one by reading its `SKILL.md` as your instructions.

(to-spec-drawer, used by `--drawer`, is model-invocation-disabled too; same
treatment, its path is given in Phase 1.)

Resolve each path by globbing
`~/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/<name>/SKILL.md`
for `to-spec`, `to-tickets` and `implement-spec`. When several versions match,
take the highest by semver; on a tie between cache folders, any one. When one
is missing, report which and stop.

Each skill tells you where the issue tracker is configured. When none is, stop
and tell the user to run `/setup-matt-pocock-skills`. That stop is the one this
command keeps: guessing a tracker publishes to the wrong place.

## Where it runs

Phases 1 and 2 run in this context, not in a sub-agent: to-spec synthesises
the current conversation, and a fresh sub-agent would not have it; with
`--drawer`, the picker also needs this session to receive the user's answer. Phase 3
runs here too: implement-spec is itself an orchestrator and spawns its own
implementer sub-agents.

Print one line at the start and at the end of each phase, so the run is never
silent.

## Phase 1: the spec

Follow to-spec on this conversation. Do not interview the user; the skill
already says so.

At "check with the user that these seams match their expectations": there is no
check. Pick the seams the skill's own rules point to (existing over new, highest
possible, as few as possible), write them into the spec's **Further Notes**
under a line `Seams accepted by /to-impl`, and continue. Publish the spec as the
skill says.

### With `--drawer`

Follow to-spec-drawer instead (`~/.claude/skills/to-spec-drawer/SKILL.md`, a
harness skill, not a plugin one). It runs to-spec with its publish step swapped
for a scope picker. The seams rule above still applies; the picker is the only
stop. The assembled body is published verbatim, so write the
`Seams accepted by /to-impl` line into the model's further notes before
validating it.

Show the picker and end the turn there, as to-spec-drawer says. Before ending
it, say in one line that `/to-impl` resumes on the answer. When the answer comes
back (`Publish the /to-spec-drawer spec … with: <ids>`, or typed ids), assemble
and publish the ticked scope as to-spec-drawer says, then go straight on to
Phase 2 without asking anything else. What the user left unticked is out of
scope for the tickets too.

## Phase 2: the tickets

Follow to-tickets on the spec you just published, with the spec as the parent.

At "quiz the user" and "iterate until the user approves": there is no quiz.
Review the breakdown yourself against the skill's three questions (granularity,
blocking edges, merge or split), revise it once if the review finds a problem,
and publish, blockers first so edges reference real identifiers. Then record
the outcome as a comment on the spec opening with
`Breakdown accepted by /to-impl` and listing the ticket refs.

## Phase 3: the implementation

Follow implement-spec with the spec and the tickets you just published. It
runs as written; it has no confirmation stop of its own. Two readings it leaves
open:

- Its step 7, the code review and its fixes, is replaced by the `review-merge`
  skill on the integration branch, before step 8: it runs the same
  Spec and Standards review as its axis B, plus correctness, seams, polish and
  the heavy gate. Give axis B the spec and the tickets you just published, so
  it does not search for them. Its one question, which `suggestion`s and
  PLAUSIBLE findings to take, is answered "none", and the findings left out are
  listed in a comment on the spec. Its commits land on the integration branch
  without asking; never push (`bench-remote` bundles unpushed commits, so a
  remote bench needs no push).
- On a local markdown tracker, which defines no close operation, a ticket is
  resolved by ticking its acceptance criteria and setting `Status: resolved`;
  once every ticket is, set the spec's status to resolved too.

Tell each implementer to install the project's dependencies in its own
worktree (for example `pnpm install --offline`) before it starts on tdd: a
fresh worktree has none, and the tests cannot run without them.

A decision you take while orchestrating (how to split files so parallel
branches do not conflict, a name two tickets share) goes in a comment on the
spec, not only in an implementer's prompt.

## Any other question

Wherever a skill would ask the user anything else, take the answer the skill
itself recommends, or the most conservative one when it recommends none, and
record it where the skill writes its output (the spec, a ticket, a comment).
Nothing is decided silently.

This command lifts the skills' confirmation stops, not the user's standing
rules: never push to `main`, never merge a PR, never force-push.

## Report

At the end, in a handful of lines: the spec ref, the ticket refs, the
integration branch, the PR if one was opened, and every auto-decision made
(seams, breakdown, any other answer taken) with where it is recorded. On a
local tracker, say that the spec and tickets live on the integration branch,
not on `main`, until it is merged.
