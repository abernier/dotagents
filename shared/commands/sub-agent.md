---
description: Run this prompt in a sub-agent instead of inline — the main session orchestrates and keeps only the distilled result, so the context window stays clean
argument-hint: "<prompt>"
disable-model-invocation: true
---

Do **not** carry out `$ARGUMENTS` yourself. Hand it to a sub-agent via the Agent
tool, stay the orchestrator, and bring back only what is worth keeping in this
window. The point of the command is the context: every file read, every grep,
every dead end belongs in the sub-agent's window, not in yours.

If `$ARGUMENTS` is empty, ask in one line what to delegate and stop.

## Before spawning

- **No warm-up work.** Do not read files, grep, or run the build "to help it
  start" — that spends here exactly what the command exists to save. The one
  exception is a cheap lookup that decides *how to split the work* (listing the
  files to fan out over, finding the target directory) — a few commands, not an
  exploration.
- **Pick the agent type.** `Explore` for read-only search and location work,
  `Plan` for design, a project agent when one matches the task, otherwise
  `general-purpose`. Never delegate to an agent that lacks a tool the task needs.
- **Split what is independent.** One agent per part that does not need another's
  output, all in a **single message** so they run concurrently. Sequential as
  soon as one consumes another's result; give each its own worktree
  (`isolation: "worktree"`) when two would write the same files.

## Writing the prompt

The sub-agent starts blank. Everything it needs must be in its prompt:

- The task, verbatim in intent — do not narrow, widen, or reinterpret it.
- The working directory (a worktree path if that is where we are), the branch,
  and any state of this session it depends on: what was already decided, what
  was already tried and failed, the file paths and names already established.
- What to hand back, explicitly: **a distilled answer** — the verdict, the file
  paths, the numbers, what it could not do. Never a file dump, never a transcript
  of its exploration, never a step-by-step of what it read.
- The gates it must respect are the repo's own; it discovers them itself. Do not
  paste conventions into the prompt.

## Foreground or background

Foreground (`run_in_background: false`) when the very next thing to do depends on
the answer and nothing else could usefully happen meanwhile. Otherwise leave it
in the background so the user can interject — and when you do, say so with an ETA
and something to watch, never a silent wait.

## Follow-ups

A second round on the same task is `SendMessage` to that agent, by name or id —
its context is still there and re-spawning pays for the same exploration twice.
A new `Agent` call is for a genuinely new task.

## Reporting back

- The agent's report is not shown to the user: relay it, in the language of the
  conversation, in the user's usual compressed style.
- **Relay, do not re-verify.** Re-reading the files it read undoes the saving. Do
  re-check a claim only when it is load-bearing and cheap to confirm — a command's
  exit code, a file's existence.
- Keep what is load-bearing: what failed, what was skipped, what it could not
  reach. A sub-agent can be wrong or over-confident; report its coverage as it
  gave it, and say plainly when it hedged.
