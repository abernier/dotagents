---
name: pre-compact
description: Make the session safe to /compact — write a resume note to disk for everything in flight that only the context holds (running sub-agents and what to do with their result, the plan, the next step), then hand back the exact /compact line that points the summary at it. Use when the user asks whether it is safe to compact now, says they want to /compact, or asks to prepare for compaction.
---

# pre-compact

The session continues after `/compact`, but only through a summary the agent
does not control. Anything that matters must survive on disk, and the summary
only needs to say where.

This is not `sweep`: there the session ends and a stranger picks the work up.
Here the same session carries on, so the note is about what is **in flight**,
not about what was done.

## 1. The verdict

First line of the reply answers the question the user asked: safe now, or not
yet and why. The usual reasons it is not safe yet:

- **A sub-agent or background task is running** whose result the agent must act
  on. It survives compaction and still notifies, but the instructions for what
  to do with its result live only in the context. Safe once the note says it.
- **An edit is half-applied** — a file changed on one side of a pair and not
  the other. Finish it, or record exactly where it stopped.
- **The user is mid-answer** on a question the agent asked. Wait for it.

If nothing is in flight and the work is committed, say it is safe and skip the
note: a note for nothing is noise the summary will dutifully carry.

## 2. The note

One Markdown file, outside the repository — the session scratchpad when there
is one, otherwise a temporary directory. Never in the working tree: it is
session state, not project content, and must not reach a commit.

Name it after the work (`<topic>-resume.md`), and write only what the summary
might lose:

- **The goal** in one line, and the plan with each step's status
- **Running work**: each sub-agent or background task — what it was asked, how
  it will report, and precisely what to do when it does (merge where, push
  what, verify how)
- **The next action**, concrete enough to start without rereading anything
- **Where things are**: branch, PR, worktree, files changed but not committed,
  servers or previews left running
- **Decisions taken in conversation** that are not yet recorded elsewhere, and
  the traps already paid for

Leave out what the repository, the tracker or the first file opened already
says. The note is a pointer into durable state, not a copy of it.

## 3. The /compact line

The agent cannot run `/compact` itself — it is a client command. Hand back the
exact line for the user to send, in its own code block:

```
/compact Resume from <absolute path to the note>: read it first; <the one thing in flight>.
```

The focus text steers the summary, so it names the note's absolute path and the
single most important pending action. The note carries the rest.

## 4. After the compaction

When the conversation resumes from a summary that names a resume note, read the
note before anything else, act on it, and delete it once nothing in it is
pending.

## Style

The verdict and the line to send are for the user: their language, a few lines.
The note is for the agent: plain English, terse, no narration.
