# dotagents

A Claude Code and Codex harness. Shared preferences and workflow
bodies have one authored source. Tool directories contain configuration,
runtime instructions, discovery links and the adapters their runtimes require.

| Directory | Contents |
| --- | --- |
| `shared/instructions.md` | Shared instructions read by both tools |
| `shared/local.example.md` | Template of the local instructions, `~/.agents/local.md` |
| `shared/claude-settings.example.json` | Template of the Claude settings, `~/.claude/settings.json` |
| `shared/codex-config.example.toml` | Template of the Codex configuration, `~/.codex/config.toml` |
| `shared/skills` | Canonical authored skills and their scripts/resources |
| `shared/commands` | Canonical command workflows |
| `shared/policies` | Policies consumed by hooks and agent instructions |
| `.claude` | Claude hooks, statuslines, entrypoint and links to shared sources |
| `.codex` | Codex runtime instructions and generated adapters |
| `.agents` | Skill discovery links, third-party skills and provenance lock |
| `bin` | Installer, adapter generator and tests |

## Install

Clone anywhere, using Node.js 22.18+ and pnpm:

```sh
pnpm install
pnpm sync-skills
pnpm install-harness
pnpm install-harness --apply
```

The installer previews changes unless given `--apply`. It backs up existing
files and installs individual file/skill links. Files directly in a shared
skill's `bin` directory are its executables: each is linked by name into
`~/.local/bin`, which is expected to be on PATH. A skill's other scripts,
helpers and tests included, stay off PATH. Authentication, databases, caches,
installed plugins and active sessions stay in place. Repeated installation
changes nothing. Previous files are stored privately under
`~/.local/state/dotagents/backups/`; failed installation restores replacements.
Start a new tool session after changing its global instructions.

Who the user is and what is true of their machine (name, handle, machines,
checkout paths, reply language, stack) live in the local instructions,
`~/.agents/local.md`, never versioned: both tools load it beside the shared
instructions. The installer creates it from `shared/local.example.md` only when
it is missing, and never overwrites it; fill in its placeholders once.

Each tool's settings are local files too, `~/.claude/settings.json` and
`~/.codex/config.toml`, never linked into the checkout: each tool writes into
its own (preferences, project trust, plugins), and neither loads a second
user-level file that could layer personal values over a shared one. The
installer creates them from `shared/claude-settings.example.json` and
`shared/codex-config.example.toml` under the same rule: only when missing,
never overwritten. The Claude template registers the harness's grilling hook
and statuslines by `~` paths, which its shell-run commands expand. Personal
plugins, marketplaces, notification hooks, auto mode context and project trust
go in those local files. Every run, dry run included, compares each existing
settings file with its template: the Claude template's hooks (event, matcher
and command, `~` read as home) and top-level keys, and the Codex template's
top-level keys, found by a line check rather than a TOML parse. It lists what
the file lacks; `--apply` adds only that, never changing, removing or
reordering an existing entry. A Codex value spanning several lines is reported
only, to add by hand.

A settings link left by an earlier installation is detached: the installer
replaces it with a copy of what it points at, or, when the checkout no longer
holds it, with the template; the last versioned content stays in git history.

`~/.agents/shared` links to `shared`, giving both tools a stable path regardless
of where the checkout lives. Claude's `CLAUDE.md` imports the shared
instructions, the local ones and its own runtime instructions; Codex's
`AGENTS.md` reads the same sources and its own runtime instructions.

An application that atomically rewrites a linked file may replace its symlink.
Review and import that change before reinstalling the link. Do not replace
entire runtime directories with repository directories.

## Authoring and generated files

Edit `shared/skills/<name>/SKILL.md` or `shared/commands/<name>.md`.
Portable skills link directly into both tools. Mark a skill's frontmatter
`codex-adapter: true` only when its workflow needs the Codex runtime mapping.
Commands always get Codex adapters. The original bodies remain shared.

Run `pnpm sync-skills` after changing metadata, adding/removing a workflow or
changing its adapter marker, then reinstall for any new home links.
Generated adapters carry a warning and derive their metadata and invocation
policy from the source. `pnpm sync-skills --check` performs a read-only check
for drift in generated files and discovery links, including stale adapters.
It is part of `pnpm lgtm`. Never edit a generated adapter by hand.

The grilling hook and Codex read `shared/policies/grilling.md`. Policy changes
are made there once; the hook only manages session state and injects that file.

The third-party find-skills and shadcn skills retain their provenance in
`.agents/.skill-lock.json` and canonical copies under `.agents/skills`.
Skills from other checkouts or plugins are not vendored here; link or install
them from your local files. `.claude/codex` is a legacy link to `.codex/bridge`.

Nothing in the checkout is specific to one user or machine: it installs as is
on any machine, and everything personal lives in the local files above.

## Verification and rollback

`pnpm lgtm` checks formatting, types, tests and generated-file drift.
Tests exercise source/link resolution, drift detection, hook policy loading,
installation backups, idempotence, restoration on failure, which skill
executables reach PATH, and that local files are seeded once and never
overwritten or linked.

Each backup retains previous files at their relative paths, plus a manifest.
Remove only the corresponding installed links before restoring them. Do not
restore old application databases over live state. The old `~/.claude/.git`
repository is preserved; use this checkout for harness Git operations.
