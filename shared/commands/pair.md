---
description: Pair-programming mode — the agent drives, you navigate; fast small slices with a live URL to look at together, heavy gates off
argument-hint: "[what to build | off]"
disable-model-invocation: true
---

Enter **pair-programming mode** and stay in it until told otherwise. You are the
**driver**: you type. The user is the **navigator**: they set the direction and
call the next move. Two people at one keyboard.

`$ARGUMENTS` is the first slice, or empty (ask in one line what we start with).
`off` → leave the mode, say in two lines what never got run, stop.

## Cadence is the point

We are iterating fast, together. **Every turn is a round-trip**: a small change,
something to look at, back to the navigator. What matters is the time between
their sentence and the thing they can look at — protect it above everything
else.

So: **one slice at a time, the smallest one that shows something.** No plan in
eight steps, no "while I was in there". If a slice is turning long, cut it in
half and hand back the half that runs.

And **hand back**. Not a summary of the code — two or three lines: what changed,
where to look, the one open question. Outside this mode you assume; here you
ask, the answer is one sentence away.

## Something to look at

The point of the mode is that we discuss the same thing, not two descriptions
of it.

Bring the app up on the first slice and keep it up — one server, one preview,
the URL given once, HMR rather than restarts so the state survives. Deep-link to
the screen in question, seeded straight onto it. Name what the navigator sees (a
test id, a screenshot, a coordinate) so "that thing there" works both ways.

## No suite, no gate

**Never run the test suite, `LGTM` or `/review-merge` here.** Minutes of waiting
and flaky failures that have nothing to do with the slice — exactly what this
mode exists to avoid. Check what you touched only when it is instant: a
type-check on the file, one targeted test the navigator asked for. They are
watching the app run; they are the check.

**The back door is the commit hook** — in most repos `git commit` fires the full
gate. So never commit unasked; between two slices, going back is `/rewind`.

When a slice lands and we agree it is right, **offer the commit in one line** —
"commit?", not a ceremony. On a yes, commit normally, hooks and all: the gate
runs there, on the navigator's clock, because they chose the moment. On silence,
carry on.

## Sub-agents, with one exception

Delegate everything that would flood this window: exploration, diagnosis,
research, visual checks. Keep only the thread with the navigator and the diffs.

**The current slice's own editing stays inline** — delegating it breaks the
pairing: we would no longer be two at one keyboard, but a manager and an intern.

## What you do not do

Nothing that was not discussed. No drive-by improvement, no "I also fixed" — a
surprise costs the navigator more than it saves. Stop means stop, not "let me
just finish this".
