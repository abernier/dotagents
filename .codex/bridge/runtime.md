# Codex runtime adaptations

These are runtime mappings, not copies of the shared conventions. They apply
when reading the shared instructions, skill, command, or phase brief.

## Tools and arguments

There is no Claude `Skill` tool: read the selected `SKILL.md` and follow it.
`$ARGUMENTS` means the arguments supplied in the user's invocation. Never pass
that name as a literal environment variable. Explicit Codex invocation uses
`$name`; `/name` in a source describes its Claude spelling.

Use the available Codex sub-agent tools for `Agent` and `SendMessage`. Agent
types, `run_in_background`, and `isolation: worktree` are intent, not Codex tool
arguments. State the role in the prompt, obey the available concurrency limit,
and create separate worktrees when isolation is required. Wait using the
available agent wait tool. If delegation is unavailable, report that fact;
never claim to have spawned an agent. Model effort requested in a document is
not an instruction to silently change the user's configured model or settings.

`ReportFindings` and Claude's built-in review skill are optional capabilities.
Use the available Codex review tools where appropriate; otherwise perform the
same review axes with sub-agents and use the source's Markdown report fallback.
Never treat findings as verified merely because a tool returned them.

`Monitor` means an available progress source, not a tool Codex necessarily has.
Use process/session status for ongoing work and the native automation capability
for an explicitly requested future check. An ETA request alone does not
implicitly request a recurring automation.

## Browser and preview

`claude-in-chrome`, `preview_start`, and `.claude/launch.json` are Claude
mechanisms. In Codex, use the enabled browser/computer-use tools. Inspect the
repository's actual dev-server command, run it through the available terminal,
and open its URL in the Codex browser. A Claude launch configuration may be read
as a command reference; do not create one just to satisfy a runtime Codex lacks.
Keep the shared Chrome for Testing, headed/background, and keychain preferences
when a separate scripted browser is supported by the active tool's rules.

## Scripts and dependencies

Claude's inline `!` shell substitution and `allowed-tools` metadata do not
execute or grant permissions in Codex. For `branchstat`, run
`bash ~/.claude/skills/branchstat/branchstat.sh` from the repository, followed by
the actual arguments. This is the source script; its adjacent resources stay
in their original directory. Return the report as the original skill requires.

Resolve references relative to the original source, not the adapter directory.
`${CLAUDE_SKILL_DIR}` denotes that original skill directory; substitute its
actual path before invoking any script.

Claude plugins do not become Codex integrations through these adapters. Prefer
an equivalent installed Codex skill. When a workflow depends on instructions
from a local Claude plugin, locate its installed `SKILL.md`, read the matching
instructions and referenced resources, and apply these runtime adaptations.
Do not assume its MCP servers or Claude-only tools are available. If a required
capability has no equivalent, identify the missing capability and stop that
phase. Existing fallbacks in shared skills still apply.

## State and hooks

Codex does not inherit Claude auto-memory. In `sweep`, use an available Codex
memory facility; otherwise save durable project knowledge in its canonical
repository document and a session handoff in the workspace. Do not claim that
writing to Claude's project memory makes Codex load it automatically.

The Claude statusline, subagent statusline, notification hooks and settings.json
permissions are not installed by this bridge. Existing Codex settings retain
authority. No permissions or authentication tokens are copied.

For a grilling interview, read `~/.agents/shared/policies/grilling.md` and
apply its policy throughout the interview. This is a conversational equivalent
of the Claude hook, not a registered Codex hook or enforcement guarantee.
