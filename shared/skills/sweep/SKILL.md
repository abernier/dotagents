---
name: sweep
description: Close a session cleanly before /clear — sweep everything durable out of the conversation into memory, the repo or the tracker, then hand back one paste-ready prompt that restarts the work in a fresh session. Use when the user says they are about to clear, asks "did you save everything?", asks what their next prompt should be, or wants a sweep or a handoff.
---

# sweep

The session is about to end. Everything worth keeping has to leave the
conversation before it does, and the next session has to be able to start from a
single paste.

Two outputs, in this order: **the sweep**, then **the prompt**.

## 1. The sweep

A fact that exists only in this conversation is a fact that is about to be lost.
Go looking for them rather than recalling the ones that come to mind — the ones
that come to mind are already the safe ones.

Check each, and say plainly which ones you checked and what you found:

- **Uncommitted or unpushed work.** `git status --short`, and whether the branch
  is behind its remote. Untracked files that matter are the usual casualty.
- **Decisions the user made in conversation.** They live in the tracker, not in
  memory: a decision nobody outside the session can read is not recorded.
  Comment on the issue or the PR.
- **Things learned that will still be true next month.** Memory, one file per
  fact. Corrections to how you should work go in the user memory; project facts
  in the project memory. Update the file that already covers it rather than
  adding a second.
- **Stale memory.** A memory file written earlier in this session, or in an
  earlier one, that this session has since outdated. This is the one most often
  missed: the sweep adds, and forgets to correct.
- **Background tasks still running.** Either wait, or say explicitly that you are
  abandoning them and what will be lost.

Report the sweep in a few lines. If nothing needed saving, say that — do not
manufacture a save to look thorough.

## 2. The prompt

One fenced block, ready to paste into a cleared session, written **as the user**
— their voice, their language, first person. Not a summary of this session
addressed to them.

It has to stand alone. A cleared session knows nothing: no branch, no PR number,
no decision taken here, no file you were in the middle of. Assume the reader is
a competent stranger with the repo checked out and nothing else.

What earns its place:

- **The one task**, stated as work to do, not as background
- **Where to start** — the issue or PR number, the branch, the base
- **The traps this session paid for**: the command that does not work the
  obvious way, the check that silently eats a push, the assumption that turned
  out wrong. This is the part that only you can write, and the part that saves
  the next session an hour.
- **What is already done**, only where it stops the next session redoing it

What does not:

- the reasoning behind settled decisions — it is in the issue, and repeating it
  invites relitigating it
- anything the next session will read anyway in the first file it opens
- politeness, framing, "as we discussed"

Length follows the work: a one-file fix is three lines, a chained-PR task with
five gotchas is a screen. Never pad to look complete.

## Style

Match how the user writes — their language, their casing, their register. The
prompt is going to be pasted **by them**, so a prompt that does not sound like
them is a prompt they have to rewrite before using.
