---
description: Where every running task stands — a real ETA when it emits progress, an honest update when it does not
argument-hint: "[focus]"
disable-model-invocation: true
---

Report the state of everything **still in flight**, right now. A snapshot, not a
wait: probe what is cheap to probe, answer, stop.

Unlike a summary read off the transcript, `/eta` is allowed — required — to go
and look: the transcript is stale the moment a background task keeps running.

## Reading `$ARGUMENTS`

Anything given is a **focus**: one task, one shell, one agent, one CI run. Report
that one and drop the rest. Absent → everything in flight.

## What counts as in flight

- Background shells started from this session (`run_in_background`).
- Sub-agents and workflows still running — `ListAgents` names them; the ids came
  back from the `Agent` / `Workflow` calls in the transcript.
- Monitors armed with `Monitor`.
- Work **outside** the session that this session started and can still observe:
  a CI run, a deploy, a remote agent, a queued bench (the `bench` skill).
  Reachable with the same command that launched it.
- A command running in the user's own Terminal panel when it belongs to this
  work — `mcp__terminal__read_terminal` shows it.

## How to look, cheaply

- `TaskOutput` with **`block: false`**, always. Never `block: true` — that turns
  a status read into a wait.
- **Never `Read` a local agent's `.output` file**: it is a symlink to the full
  subagent transcript (JSONL) and will flood the window. Use `ListAgents`, the
  agent's own result, or `SendMessage` to ask it.
- Tail, do not cat: `tail -n 20 <output file>`.
- Freshness is a `stat` away — `stat -f %m <file>` against `date +%s` gives
  seconds since the last write. That number is what separates "working" from
  "hung", and it costs nothing.
- One probe per task. No re-running the work, no fresh build, no second gate run
  to find out how the first is doing.

## The estimate, in three tiers

1. **Measured** — the stream carries countable progress (step k of n, tests run,
   files done, a percentage). `ETA = elapsed x (n - k) / k`. Give the basis.
2. **Baseline** — nothing countable, but a comparable run has a known duration:
   an earlier run this session, a recorded number, a documented budget.
   `ETA = baseline - elapsed`, and say it is a baseline, not a measurement.
3. **Neither** — no number at all. Say elapsed, the last signal, and whether it
   is alive. That is the "or failing that, an update" case, and it is a complete
   answer.

**Never dress a tier-3 guess as a tier-1 figure.** A fabricated ETA is worse than
none: it gets planned against. If an ETA already given has passed, say it passed
and that the first estimate was wrong — do not silently re-extrapolate a new one
as if it were the original.

## Alive, silent, or done

- Last write inside the task's own cadence → running, say so.
- Silent for many multiples of that cadence → **"silent for X"**, never "still
  running". Silence and a hang look identical; report the silence, not a guess
  about which it is.
- Already exited → it is not in flight. Report the verdict — exit code, what it
  said — and say plainly that it finished while unreported.

## Output

The lines below are the whole reply. No preamble, no closing summary: this
*is* the status read.

```
<label> — <elapsed> — ETA <estimate> (<basis>)
  last: <the last meaningful line, trimmed>
```

- Nothing in flight → one line saying so, plus how the last thing ended. Stop.
- Answer in the language of the conversation, in the user's compressed style.
- Append an `Actions` section only if a probe surfaced something that genuinely
  needs the user's person — a Touch ID prompt, an approval, a password.

## Rules

- **Never block.** A snapshot every time, however tempting the wait.
- **No new work** to answer the question. Probing is not running.
- **Fix the silence rather than report it twice.** If a task has nothing to
  watch and it matters, arm the ticker here — a `Monitor`, or a background
  `until` loop that exits on the condition — and say it is armed. Do not hand
  the user a command to run.
- No emoji.
