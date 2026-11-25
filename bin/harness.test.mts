import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { install } from "./install.mts";

const repo = realpathSync(join(dirname(fileURLToPath(import.meta.url)), ".."));

test("installed entrypoints and portable skills use the same shared sources", (context) => {
  const home = mkdtempSync(join(tmpdir(), "dotagents-harness-"));
  context.after(() => rmSync(home, { recursive: true, force: true }));
  install({ repo, home, apply: true });
  assert.equal(
    realpathSync(join(home, ".agents/shared/instructions.md")),
    join(repo, "shared/instructions.md"),
  );
  assert.ok(
    readFileSync(join(home, ".claude/CLAUDE.md"), "utf8").includes(
      "@../.agents/shared/instructions.md",
    ),
  );
  assert.ok(
    readFileSync(join(home, ".codex/AGENTS.md"), "utf8").includes(
      "~/.agents/shared/instructions.md",
    ),
  );
  assert.equal(
    realpathSync(join(home, ".claude/skills/typescript-conventions/SKILL.md")),
    realpathSync(join(home, ".agents/skills/typescript-conventions/SKILL.md")),
  );
  assert.equal(
    realpathSync(join(home, ".claude/commands/sub-agent.md")),
    join(repo, "shared/commands/sub-agent.md"),
  );
  assert.equal(
    realpathSync(join(home, ".agents/shared/policies/grilling.md")),
    join(repo, "shared/policies/grilling.md"),
  );
});
