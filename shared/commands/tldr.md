---
description: Re-state my last response, compressed — level 1 (a line), 2 (a handful of bullets), 3 (a short brief); an optional focus says what to keep
argument-hint: "[1|2|3] [focus]"
disable-model-invocation: true
---

Compress **your own last substantive response**. Nothing else: not the whole
session, not the user's question, not what you are about to do next. A focus
argument is the one thing that moves that boundary — see *The focus* below.

Which message that is: walk back up the transcript and take the first assistant
message that was **not itself produced by `/tldr`**. A summary is never the source —
`/tldr 3` right after `/tldr 1` re-reads the original response at level 3, it does
not expand the one-liner. Same for two `/tldr` in a row at the same level: the
answer is the same summary, not a summary of a summary.

## Reading `$ARGUMENTS`

Two parts, both optional, in this order:

- A **level** — a leading `1`, `2` or `3`. Absent or unrecognised → **1**.
- A **focus** — everything left once the level is removed. Absent → summarise the
  response as a whole.

So `/tldr` is level 1 no focus, `/tldr 2` is level 2 no focus, `/tldr what broke?`
is level 1 focused, `/tldr 2 what broke?` is level 2 focused. A bare number is
always a level, never a focus.

## Levels

- **1** — one line. The verdict, the answer, or the thing that changed. Under ~20
  words. No preamble, no lead-in clause, no closing offer.
- **2** — 3 to 5 bullets. The verdict first, then only what a reader needs to act:
  numbers, file paths, the caveat that would change their decision.
- **3** — a short brief: a one-line verdict, then up to ~8 bullets, grouped if the
  original had parts. Still a summary — well under half the original.

## The focus

The focus decides **what to keep**, the level decides **how much**. Answer the
focus and drop the rest, however central it was to the original — a focused
`/tldr 1` is one line about the focus, not the response's headline.

If the last response does not answer the focus, **walk further back up the
transcript** until it is answered — earlier responses, the user's own messages,
the tool results already in context. Something like *where are we at* spans the
session by nature; that is expected, not a widening to apologise for. Still no
tool, still nothing new: what is not already in the transcript is not available.

If nothing in the session answers the focus, say so in one line and stop. Do not
go and find out.

## Rules at every level

- **No new work.** Do not run a tool, read a file, or re-verify anything. The
  transcript is the only source; if it was wrong, the summary repeats it wrong.
- **No new claims.** Nothing that was not already said. If the original hedged, the
  summary hedges; a hedge dropped in compression reads as certainty.
- **Keep what is load-bearing** — what failed, what was skipped, what is unproven,
  the one number that carries the conclusion. Those survive at level 1 if they are
  the point; a summary that keeps only good news is a false report. Under a focus,
  this applies to the focus: a focused summary that drops the caveat attached to
  what was asked is the same false report.
- **Drop the prose scaffolding** — the reasoning, the alternatives weighed, the
  restatement of the question, the sign-off.
- **Answer in the language of the conversation**, whatever the level.
- Output the summary alone. Do not announce it, do not label it "TL;DR", do not
  say which messages you read, do not offer to expand it back.
