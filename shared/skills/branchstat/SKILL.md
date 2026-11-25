---
codex-adapter: true
name: branchstat
description: Net diff of the current branch vs its base, bucketed and rolled up by module — how much the branch grew and which module took the charge. Use mid-branch or before a merge, when the user types /branchstat, or asks how big a branch is or where its weight sits.
argument-hint: "[base] [--md] [--of <branch>] [--depth <n>]"
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/branchstat.sh)
  - Bash(bash ${CLAUDE_SKILL_DIR}/branchstat.sh *)
---

!`bash ${CLAUDE_SKILL_DIR}/branchstat.sh $ARGUMENTS`

The report above is the answer: a headline total counted the way GitHub counts a
PR, then a breakdown of hand-written code only — source, tests and config apart —
rolled up by module so the branch names where its weight sits.

Hand it back as it stands. It is laid out on a column grid and its bars are a
share of their bucket; turning that into prose loses the comparison it exists to
make. Add a sentence only where the user asked something the numbers answer.

Run from another skill or a sub-agent, call the script the same way, from inside
the repo to measure: `bash ${CLAUDE_SKILL_DIR}/branchstat.sh [base]`.

`--md` renders it as a PR comment instead, footer included. The breakdown wants
`cloc` (`brew install cloc`); without it only the total prints, and it says so.
A repo excludes more than the defaults in `branchstat.json` at its root — see
the header of `${CLAUDE_SKILL_DIR}/branchstat.sh`.
