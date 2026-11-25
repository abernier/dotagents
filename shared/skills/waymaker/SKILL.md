---
codex-adapter: true
name: waymaker
description: "Carry a charted /wayfinder map to a draft PR with no human in the loop: answers every open decision itself (traceable as waymaker:auto), then spec, tickets, implement in parallel worktrees, merge onto a feature branch, push. Use after /wayfinder has charted a map and you accept its decisions being made for you."
argument-hint: "[<map>] [--max-decisions N]"
disable-model-invocation: true
---

# waymaker

`/waymaker [<map>] [--max-decisions N]`

A charted `/wayfinder` map is the input. The output is a feature branch with
every implementation ticket merged, and a draft PR when a GitHub remote exists.
Charting stays human: the user has already run `/wayfinder <idea>`.

The original workflow needs a `/clear` between phases. A sub-agent is a fresh
context, so every phase runs in one, spawned with the Agent tool and a brief
from `briefs/`. This deliberately breaks wayfinder's human-in-the-loop rule:
wherever a skill would ask the user, the sub-agent adopts the recommended
answer the skill itself produces, and records it. Every auto-decision is
traceable: the resolution comment opens with `Auto-decided by waymaker` and the
ticket carries the label `waymaker:auto`. On the local tracker these are the
`## Answer` section, a `Labels: waymaker:auto` line, and `Status: resolved`
(`Status: done` for an implementation ticket); find auto-decisions with
`grep -l 'waymaker:auto'` there.

## The orchestrator's job

You are the orchestrator. You never resolve a ticket, write a spec, or edit
code. You read tracker state, fill a brief, spawn a sub-agent, merge branches,
and report. Anything else belongs in a brief.

Never fabricate a sub-agent's result. If it did not report, it did not happen;
say so and stop that ticket.

The directory you were invoked in is the user's checkout. You never run
`checkout`, `switch`, `merge` or `branch -b` in it. Every git write happens in
a worktree under `{{worktrees_dir}}`.

## Setup

1. **Resolve skill paths.** Glob
   `~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/*/skills/engineering/<name>/SKILL.md`
   for `wayfinder`, `to-spec`, `to-tickets`, `implement`. Several versions:
   take the highest by semver. These skills are `disable-model-invocation`, so
   a sub-agent cannot invoke them; the brief gives it the absolute path to read
   and follow as its instructions.
2. **Resolve the tracker doc.** The project's `CLAUDE.md` / `AGENTS.md` points
   at it (usually `docs/agents/issue-tracker.md`). None: use
   `setup-matt-pocock-skills/issue-tracker-local.md` from the same plugin
   folder. Read it yourself; every frontier, claim and pointer below is
   expressed the way that doc says. Pass its path to every brief as
   `{{tracker_doc}}`.
3. **Parse arguments.** `<map>` is `#N` or a bare `N`, an issue URL, or a path to `map.md`.
   Absent: find the single open issue labelled `wayfinder:map` (local tracker:
   the single `.scratch/*/map.md`). Zero or several: report which, and stop.
   `--max-decisions N` defaults to 20.
4. **Worktrees dir.** `{{worktrees_dir}}` is the repo's `.claude/worktrees/` if
   it exists, else `<repo>/.worktrees/`. It must be gitignored: when
   `git check-ignore -q <dir>` fails, append the path to `.git/info/exclude`.
5. **Feature branch worktree.** `{{feature_branch}}` is `waymaker/<map-slug>`,
   `{{feature_worktree}}` is `{{worktrees_dir}}/<map-slug>`. `git fetch origin
   main`, then `git worktree add {{feature_worktree}} {{feature_branch}}` if
   the branch exists, else `git worktree add {{feature_worktree}} -b
   {{feature_branch}} main`. Every "feature branch worktree" below is this
   path: merges, the merge brief, the push, and the creation of ticket
   worktrees all happen there. If the user's checkout already has the branch
   checked out, `git worktree add` refuses: report and stop.
6. **Note the start time.** Print one line at every phase start and end, and
   at every ticket start and end, with elapsed time. The run is never silent.

## Resume

State lives on the tracker only. Waymaker adds the two links the skills do not:
after to-spec a comment on the map `Spec: <ref>`, after to-tickets
`Tickets: <refs>`. On start, the current phase is the first gap in the chain:

- open decision tickets (children labelled `wayfinder:<type>`) on the map: Phase 1
- no `Spec:` comment: Phase 2
- no `Tickets:` comment: Phase 2, to-tickets only (tell the brief the spec ref)
- an open ticket among the refs of the `Tickets:` comment: Phase 3
- otherwise: Phase 4

The implementation tickets are the refs in the map's `Tickets:` comment. Their
blocked-by edges are read the way the tracker doc says: native dependencies on
GitHub, the `Blocked by` line locally.

**Stale claims.** A claimed ticket that no waymaker sub-agent alive in this run
is working on was left by a run that died. You know which claims this run's
sub-agents made; every other claim is stale. Release it (unassign, or
`Status:` back to open, per the tracker doc) before computing any frontier.

## Phase 1: Decide

Strictly sequential. One sub-agent per ticket, never two decision tickets in
flight at once; the map changes under every resolution.

Loop:

1. Read the map at low resolution. Release stale claims. Compute the frontier:
   open, unblocked, unclaimed children, in tracker order, minus the tickets
   given up this run. Its size is the "before" count.
2. Check the stop conditions, in order. Each ends the loop with a report:
   - (a) frontier empty, **Not yet specified** empty, nothing given up this
     run: the way is clear. Go to Phase 2. Something given up: report which
     tickets, and stop.
   - (b) the previous result said `hitl_at_head: yes`: report the ticket it
     names as needing the human, and that a rerun resumes here. Stop.
   - (c) frontier empty but **Not yet specified** non-empty: the fog did not
     graduate. Report the remaining fog. Stop.
   - (d) decisions resolved this run equals max-decisions. Stop.
   - (e) divergence alarm: three resolutions in a row whose `frontier_after`
     was strictly larger than the "before" count of the same iteration. Report
     that the map is growing instead of converging. Stop. A research ticket's
     resolution neither counts toward nor breaks the streak.
3. Spawn `briefs/decide.md` for the head ticket, filling `{{ticket_ref}}`,
   `{{map_ref}}`, `{{skill_path}}` (wayfinder), `{{tracker_doc}}`,
   `{{worktrees_dir}}`, `{{feature_branch}}`. Wait.
4. Read the result. `closed: no` ends that ticket for this run: report the
   reason it gives, and treat the ticket as given up. Record the "before"
   count from step 1 and `frontier_after` from the result for (e). Loop.

`grilling`, `research`, `prototype` and AFK `task` tickets are all
auto-resolved; the HITL criterion is written once, in `briefs/decide.md`.
Research tickets too run one sub-agent per ticket, for simplicity.

## Phase 2: Spec and tickets

One sub-agent, `briefs/spec-and-tickets.md`, with `{{map_ref}}`,
`{{to_spec_path}}`, `{{to_tickets_path}}`, `{{tracker_doc}}`, `{{spec_ref}}`.
It runs to-spec then to-tickets in the same context, as the skills require.
On a first run `{{spec_ref}}` is the empty string; on resume with a spec
already published, its ref, and the brief skips to to-tickets.

When it reports, post `Spec: <ref>` and `Tickets: <refs>` as comments on the
map. Keep the blocked-by edges it reports; Phase 3 needs them.

## Phase 3: Implement, by waves

**Feature branch.** The worktree from Setup step 5. Only the orchestrator and
the merge sub-agent it spawns write to it, one at a time.

**Startable.** An implementation ticket is startable when it is open, every
blocker is closed on the tracker, it has not been given up on this run, and
none of its blockers (transitively) has been given up on.

**Wave.** Every startable ticket. All in parallel, no cap.

For each ticket in the wave:

1. Branch: `waymaker/<ticket-slug>` on the first attempt,
   `waymaker/<ticket-slug>-2` on the retry. A pre-existing
   `waymaker/<ticket-slug>*` branch that has a worktree was left by a run that
   died mid-ticket: `git worktree remove --force <path>`, `git branch -D
   <branch>`, then start the ticket again. State it in the report.
2. Worktree, from the feature branch worktree:
   `git worktree add {{worktrees_dir}}/<ticket-slug> -b <branch>
   {{feature_branch}}`. The brief handles the install step; you do not.
3. Spawn `briefs/implement.md` with `{{ticket_ref}}`, `{{spec_ref}}`,
   `{{worktree_path}}`, `{{branch}}`, `{{feature_branch}}`, `{{skill_path}}`
   (implement), `{{tracker_doc}}`, `{{failure_report}}` (the empty string on a
   first attempt).

**Failure.** A sub-agent reporting failure (red tests, blocking code-review
findings, could not complete) gets exactly one retry: a fresh worktree off the
feature branch, the `-2` branch, a fresh sub-agent, `{{failure_report}}`
filled with its report. One retry total per ticket, across implement and merge
failures. A second failure leaves that branch as is and marks the ticket
failed; its dependants are not startable this run. The run continues.

When every sub-agent of the wave has reported, run Phase 3b, then compute the
next wave. No startable ticket left: go to Phase 4.

## Phase 3b: Merge

In the feature branch worktree, merge each successful ticket branch in tracker
order; a wave holds no blocker pairs by construction. Before each merge record
the feature branch SHA (`git rev-parse HEAD`), then `git merge --no-ff
<branch>`.

**Clean merge.** Close the ticket on the tracker now, with a comment pointing
at the merge commit (local tracker: `Status: done`). This closure is what makes
the next wave startable; it never waits for Phase 4. Then `git worktree remove
<path>` and `git branch -d <branch>`. Note the merge commit per ticket.

**Conflict.** Spawn `briefs/merge.md` with `{{branch}}`, `{{feature_branch}}`,
`{{feature_worktree}}`, `{{ticket_ref}}`, `{{tracker_doc}}`, and wait.
`resolved: yes`: close and clean up as for a clean merge. `resolved: no`:
restore the feature branch yourself — `git merge --abort` if a merge is in
progress (`git rev-parse -q --verify MERGE_HEAD`), else `git reset --hard
<sha>`. Then treat it as that ticket's failure under the Phase 3 rule:
`{{failure_report}}` is the merge brief's result plus the conflicted files
list, and the retry worktree is based on the now-updated feature branch. The
retry lands with the next wave's merge.

## Phase 4: Finish

1. GitHub remote present: push the feature branch from its worktree and
   `gh pr create --draft` there. Write the body to a file in the scratchpad
   and pass `--body-file`; never an inline heredoc. The body references the
   spec and the map, lists tickets done, failed and blocked, and says in one
   line that no final gate was run (the user's decision). No remote: report
   only.
2. Final report to the user: phases run, decisions taken (find them by the
   `waymaker:auto` label), tickets implemented, failed and skipped with the
   reason, branches removed on resume, feature branch, PR URL.
