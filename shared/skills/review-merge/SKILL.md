---
codex-adapter: true
name: review-merge
description: Pre-merge exhaustive review of the current branch against its base, fixes applied, then the heavy gate. Use only when the user types /review-merge or asks for the pre-merge review by that name.
---

# Review merge

ultrathink. Effort level: `$ARGUMENTS`, one of `low | medium | high | xhigh`;
empty means `high`. It is passed verbatim to the built-in `code-review` skill
(axis A).

## 0. Base, target, and what the repo reviews against

```sh
git fetch origin --quiet
BASE=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)
[ -n "$BASE" ] || BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
BASE="origin/${BASE:-main}"
PR=$(gh pr view --json number -q .number 2>/dev/null)
```

The scope of every axis is `git diff "$BASE"...HEAD`, one diff shared by all
five. A dirty tree is in scope for some axes and not others, so it splits the
review: say it exists and have it committed first, as `gates` says, before
going on. Every sub-agent prompt carries the resolved values (`origin/main`,
`42`), never the variable names.

**The standards sources** are the repo's to say, never assumed: list which of
`CLAUDE.md`, `AGENTS.md`, `CODING_STANDARDS.md`, `CONTEXT.md` and `docs/adr/`
actually exist. Where there is an ADR directory, each filename states its rule,
so the listing is the index.

**The heavy gate** is `gates`' heaviest. A repo with none gets step 4 reported
as "there is none": a line in the closing report, not a finding.

State what you found in one line before going on.

## 1. Five axes, nothing changed yet

Every axis returns findings as data, never fixes: severity (`blocker`,
`important`, `suggestion`), `path:line`, observation, proposed fix, and a tag,
_inside the diff_ or _outside it_. Fixes land in step 3, in one pass, once every
axis has had its say.

Launch axes C, D and E as background sub-agents in a single message, then run A
and B inline through the Skill tool while they work; each of those fans out its
own sub-agents.

### A. Correctness and cleanup: the built-in `code-review`

Invoke the built-in `code-review` skill through the Skill tool with:

```
<level> --max-findings all <$PR when set, else $BASE>
```

No `--fix`: step 3 owns the fixes, after every axis. Its findings arrive
verified, through `ReportFindings`: take them as they come. From its first
phase, check that the scope it took is `$BASE...HEAD`. If not, re-invoke it
with the other form of target (PR number against branch name) and only then
carry on; the five axes must share one diff.

### B. Spec and Standards: `mattpocock-skills:code-review`

The two-axis one. Fixed point `$BASE`, standards sources from step 0. It reads
the diff against the repo's documented standards (plus the Fowler smell
baseline) and against the issue or PR body the branch came from, as two
parallel sub-agents. Let the skill own that review. If the plugin is not
enabled, add two sub-agents to the C, D and E message, spec and standards, on the
same diff, and say which path you took.

### C. Seam: `mattpocock-skills:codebase-design`

Neither A nor B asks whether the branch put its behaviour in the **right
place**. Scope the branch by module with the `branchstat` skill, base `$BASE`:
it rolls the diff up by dot-scoped module and names the one that took the
charge. Its rollup does not sum by directory, so add
`git diff --dirstat "$BASE"...HEAD` for the per-directory share. The sub-agent
reads those modules in
the `codebase-design` vocabulary: is the interface small for the behaviour
behind it, is the seam where a caller would look for it, is a new abstraction
earning its keep or passing through. Without the skill, it asks those three
questions in plain words.

Cap its report: what it would have fixed, plus at most the one or two seams
load-bearing enough that a human might say "redraw this before it lands".
Never an inventory, no follow-up ticket.

### D. Merge polish

One sub-agent on the same diff for what the review axes do not target:
well-judged tests or stories for introduced features not yet covered, proposed
without forcing them; documentation and comments the change makes stale or
leaves missing, the README first.

### E. Simplification: the built-in `simplify`

`simplify` hunts reuse, simplification, efficiency and altitude cleanups; A
catches only part of them. It also applies its fixes as it goes, which this
step forbids, so it runs where its edits cannot land: one background sub-agent
on a throwaway git worktree of `HEAD` (the Agent tool's worktree isolation, or
`git worktree add` by hand). There it:

1. Runs `git reset --soft <merge-base of $BASE and HEAD>`, resolved in the
   prompt: the whole branch becomes staged, uncommitted work, so `simplify`
   sees exactly `$BASE...HEAD` whatever scope it defaults to.
2. Invokes `simplify` through the Skill tool.
3. Reads `git diff`, worktree against index: since the index holds the branch,
   that is `simplify`'s edits and nothing else.
4. Returns each hunk as a finding, category `simplification`, the hunk as its
   proposed fix, then leaves the worktree to be discarded.

Where `simplify` is not available, skip the axis and say so in the closing
report; A's cleanups stand in for it, never a hand-written copy of its recipe.

## 2. Consolidate, verify, report

Pool the five lists. Dedup against A's findings: same defect, same location,
keep A's, its verdict stands.

Findings from B, C, D and E are unverified. An E finding's verifier also checks
that the hunk preserves behaviour; one that does not is REFUTED. For each, one verifier through the
Agent tool, given the diff, the relevant files and the candidate, returning
exactly one of:

- **CONFIRMED**: can name the inputs or state that trigger it and the wrong
  outcome. Quotes the line.
- **PLAUSIBLE**: the mechanism is real, the trigger is uncertain. States what
  would confirm it.
- **REFUTED**: factually wrong, or guarded elsewhere, or pure preference with no
  observable effect. Quotes the line that proves it.

Keep CONFIRMED and PLAUSIBLE.

Report once through `ReportFindings` with `{level, findings}`, most-severe
first, A's findings verbatim plus the survivors of B, C, D and E. Each entry has
`file`, `line`, `summary`, `short_summary` (the claim alone, 60 characters at
most), `failure_scenario` (for a non-bug: the concrete cost, what drifts from
the spec, what a caller cannot find, what goes untested or undocumented, what
duplicate or wasted work stays), `category` (`spec`, `standards`, `seam`,
`test-coverage`, `docs`, `simplification`, or A's own
slug) and `verdict`. The tool takes 32 entries at most: correctness outranks
the rest when the cap forces a cut. This call is the report the UI keeps, so it
must contain A's findings and not only the new ones. Where the tool is absent,
the same list as a markdown table, in the user's language.

Then ask, in one line, which `suggestion`s and PLAUSIBLE findings the user
takes. The CONFIRMED `blocker`s and `important`s are applied without asking.

## 3. Apply the fixes, fanned out, never as one batch

Apply every CONFIRMED `blocker` and `important`, plus the `suggestion`s and
PLAUSIBLE findings the user accepted; silence accepts none of them. Do it
**before** the heavy gate; running it against code about to change is wasted.

Delegate the applying. The list is short, the files it reaches are not: one
agent handed the whole batch reads every file the batch touches and ends up
stopped and re-split by hand. Split first, then dispatch:

- **Partition by file.** Group accepted findings by the files they touch, then
  cut into sets whose files do not overlap. A finding that ripples across many
  files, a type change or a rename, is a set on its own and owns every file it
  touches; any other finding landing in one of those files joins that set. No
  file has two owners.
- **One sub-agent per set, all in a single message.** Each is told the exact
  files it owns and that any other file is another agent's. It runs only its
  own test files and `prettier --write` on its own files, and reports in under
  150 words. A type error crossing into another set is expected mid-flight:
  the agent ignores it, the orchestrator checks it afterwards.
- **Test before fix, inside the set.** A blocker that wants a failing test
  first (`test-conventions`) keeps that order within its own set.
- **The orchestrator integrates, it does not edit.** Once every agent has
  reported, run the fast gate (`gates`). Whatever it leaves, a type error
  between two sets, a stale import, a test nobody owned, goes to a fresh small
  agent with its own file list; re-run until green.

Then call `ReportFindings` again with the same findings, each carrying an
`outcome`: `fixed`, `no_change_needed` (the finding was wrong or already
handled) or `skipped` (real, not applied). Make that call before any prose; the
UI's per-finding status updates only from it. After it, one line per skipped
finding saying why.

## 4. The heavy gate, once the fixes are in

**Step 3's fixes are committed first**, proposed and waited for as `gates`
says. The verdict worth having is the one on the tree that will be merged, and
a gate that publishes a commit status publishes nothing on a dirty tree. If the
developer declines the commit, run against the dirty tree, say so in the
report, and that an absent status is not red.

Run the gate as `gates` spells it, no flags of your own.

**Performance is part of the verdict.** A repo's bench is a leg of its heavy
gate, as `gates` says, so it runs here with it, never as a step of this review
beside it. A bench the heavy gate leaves out is the repo's gap to report, not
one to fill here. What stays here is judgement: the bench's result is read, and
a red rerun, as the `bench` skill says; when the diff touches what only a phone
reveals (gestures, the mobile GPU, thermal limits), add a phone run, as `bench`
says too.

**Splitting the bench onto a quiet machine.** When local instructions configure
a quiet machine and request offloading `review-merge` benchmarks to it, split
this step instead of running the bench twice: run the non-bench legs locally
with `BENCH_SKIP=1` (`BENCH_SKIP=1 pnpm run LGTM`, or the repo's heavy gate
with `BENCH_SKIP=1`), and run the repo's bench leg on the quiet machine via
`bench-remote <host> -- <bench leg>` (no push required: `bench-remote` bundles
unpushed commits).
- If the quiet machine is unreachable, fall back to the full heavy gate locally
  (`pnpm run LGTM` without `BENCH_SKIP=1`) and note the local fallback
  explicitly in the verdict.
- If the repo's heavy gate does not honor `BENCH_SKIP=1`, run it locally as
  before and note the gap.
- Without a quiet-machine preference in local instructions, run the full heavy
  gate locally as before.

**If it fails, investigate before fixing**:

1. **Identify the culprit**: the precise test, component, metric or rule, from
   the gate's own output and the artefacts it leaves behind.
2. **Compare to before**: `git log "$BASE"..HEAD -- <file>` and
   `git diff "$BASE" -- <file>` on that culprit trace what the branch changed.
   Red on the base too is `gates`' pre-existing case: its own issue, not this
   branch's.
3. **Trade-off**: where the gate measures rather than asserts (perf, size,
   coverage), propose several solutions and pick the one that minimises the
   observed delta, not just the one that clears the threshold. An avoidable
   delta is debt about to be merged.

Fix, re-run. A red that goes green with nothing changed is `gates`' flake case,
handled there. Close with the gate's verdict and the findings' outcomes, in the
user's language.
