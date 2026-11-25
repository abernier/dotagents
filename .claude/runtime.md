# Claude Code runtime

The personal instructions and workflow bodies live in the shared harness.
Skills and commands in this directory link to those canonical sources.

Use Chrome through `claude-in-chrome` when that integration is available.
The shared instructions own preferences for separate scripted test browsers.

For visual debugging, use the project's `.claude/launch.json` preview
configuration: start it with `preview_start` by name and open the reproduction
URL in that pane. If preview tooling is available and the project has no launch
configuration, add an entry for its actual dev-server command. When a required
integration is unavailable, report that limitation and use the available
runtime equivalent.

The grilling hook reads the canonical policy under `shared/policies`.
It owns session markers and injects that file's contents into the conversation.
