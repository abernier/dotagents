---
description: Run this prompt in as many sub-agents as the work splits into — /sub-agent at scale, each agent kept under the dumb-zone, the main session only orchestrates and assembles
argument-hint: "<prompt>"
disable-model-invocation: true
---

`$ARGUMENTS` is too big for one window — yours or an agent's. Split it and
dispatch it. One prompt, a plan of twenty steps, a sweep over thirty files: the
size is not a reason to do it inline, it is the reason not to.

Empty `$ARGUMENTS` → ask in one line what to delegate and stop.

## The doctrine is `/sub-agent`

Read `~/.claude/commands/sub-agent.md` and apply it to **every** agent you
spawn — agent type, self-contained prompt, foreground or background, follow-ups
by `SendMessage`, relay without re-verifying. None of it is repeated here; this
command only adds the layer above it.

The one warm-up it allows — a cheap lookup that decides *how to split* — is
wider here: reading the plan `$ARGUMENTS` points at is part of it. Still a few
commands, not an exploration.

## Splitting

- **Budget each agent under ~150k tokens.** Past that it degrades, and its output
  is what this window inherits — the split is as much about size as about
  independence. Estimate from what the part must read: the files it touches, plus
  the ones it has to understand to touch them. A part that cannot be described in
  a prompt without pasting half the repo is too big; cut it again.
- **The cut is yours, not the input's.** A plan's numbered steps, a list's
  bullets, a directory's files are a hint — two steps touching the same file are
  one agent, one step spanning three independent modules is three.
- **Order by dependency, not by the order it was written in.** A shared
  foundation the rest builds on goes first, alone, and its result goes into the
  others' prompts.

## Waves

Dispatch everything independent in a **single message**, relay the wave in two or
three lines, dispatch the next with what the first established. A part that came
back short or refused is re-dispatched with what it lacked, never quietly
finished inline. It is done when every part is; say plainly what was left out
and why.
