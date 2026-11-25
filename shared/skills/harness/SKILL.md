---
name: harness
description: "Manage the shared dotagents harness for Claude Code and Codex: inspect status, edit workflows or configuration, and synchronize installed home links."
---

# Harness

Resolve the checkout as the parent of `realpath ~/.agents/shared`; do not assume
its location or use a tool runtime directory as the Git checkout. If that link
is missing, locate the existing dotagents checkout before installing anything.
Read its `README.md`, `package.json`, and the installer/generator implementation
relevant to the request; those files own the commands and layout.

With no arguments, report status without mutations: branch and local changes,
upstream divergence, generated-file drift, installation preview, and missing or
broken managed home links. Identify unrelated live application config changes
and keep them out of the requested patch. Keep secrets out of the report.
Otherwise execute the requested maintenance and verify the resulting sources
and installed links.

## Edit and synchronize

Edit the canonical shared instructions, policies, skills or commands. Personal
facts (who the user is, their machines and paths, reply language) go in the
local instructions, `~/.agents/local.md`, never in the checkout. Personal
settings (plugins, marketplaces, notification hooks, auto mode context, project
trust, absolute paths) go in the tool's own local file, `~/.claude/settings.json`
or `~/.codex/config.toml`; only what every user of the harness needs goes in
their templates, `shared/claude-settings.example.json` and
`shared/codex-config.example.toml`. Tool
entrypoints and runtime mappings contain only their tool-specific adaptations.
For a new skill, use the available skill-creator guidance; default to a portable
shared skill, and request an adapter only when the workflow requires runtime
mappings. Never edit generated adapters. Keep third-party provenance accurate.

Regenerate discovery links/adapters, preview installation, then apply it when
synchronization is requested or necessary to activate the requested change.
Check generated-file drift and installed real paths afterwards. The installer
backs up replacements but does not prune retired home entries.

Before removing a workflow, inventory its tracked sources, references and
provenance, and snapshot each owned home link and its exact checkout target.
Remove only entries in the requested scope, then regenerate; the generator
prunes owned repository discovery links. For retired home entries, use `lstat`
and unlink only symlinks whose target still matches that snapshot exactly.
Resolve dangling targets from `readlink` and their parent directory rather
than requiring `realpath` to succeed. Preserve unrelated files and external
links.

## Configuration and publication

An application can atomically rewrite a linked file and replace its installed
link. Compare home and checkout first: reconcile the intended home changes into
the tracked source before reinstalling, while preserving unrelated edits. The
tools' settings are not linked: the installer reports what an existing local
file lacks from its template and adds only that on `--apply`. Never
import authentication, tokens, databases, caches, plugins or active session
state, and never replace a whole runtime directory.

Follow the shared `gates` skill for validation and publication authorization.
Keep existing user authorization; creating or synchronizing a skill alone does
not authorize a commit or push. Report checks, installation changes and whether
work is local or published. Global instruction changes take effect in a new
session.

Examples: `/harness`, `/harness add a code-review skill`,
`/harness remove an unused workflow and synchronize`,
`/harness add a hook to the Claude settings template`, `/harness verify and push`.
In Codex, invoke the same skill as `$harness`.
