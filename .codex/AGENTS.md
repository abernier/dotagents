# Personal harness for Codex

Read `~/.agents/shared/instructions.md` at the start of each session, then
`~/.agents/local.md`, the local instructions it points to.
Read `~/.codex/bridge/runtime.md` before applying a shared workflow; its runtime
mappings take precedence over tool-specific mechanisms in the original source.

Portable skills in `~/.agents/skills` link directly to their shared source.
Workflows that require Claude-specific mechanisms use generated Codex adapters.
Edit the shared source, then regenerate adapters; never edit generated files.

In a repository, also discover project skills in `.claude/skills` when present:
read their name and description, then load only the matching instructions.
Native `.agents/skills` remain discoverable through Codex itself. Prefer one
canonical definition if the same skill appears in both locations.
