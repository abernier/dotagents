import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  unlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { syncSkills } from "./sync-skills.mts";

function fixture() {
  const repo = mkdtempSync(join(tmpdir(), "dotagents-sync-"));
  mkdirSync(join(repo, "shared/skills/report"), { recursive: true });
  mkdirSync(join(repo, "shared/commands"), { recursive: true });
  writeFileSync(
    join(repo, "shared/skills/report/SKILL.md"),
    "---\nname: report\ndescription: >-\n  Show a report:\n  with counts.\n---\nBody\n",
  );
  writeFileSync(
    join(repo, "shared/commands/pair.md"),
    '---\ndescription: "Pair: Claude drives"\ndisable-model-invocation: true\n---\nBody\n',
  );
  return realpathSync(repo);
}
function inFixture(run: (repo: string) => void) {
  const repo = fixture();
  try {
    run(repo);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
}

test("portable skills share their original file; commands use generated runtime adapters", () =>
  inFixture((repo) => {
    assert.equal(syncSkills(repo), 2);
    assert.equal(
      realpathSync(join(repo, ".agents/skills/report/SKILL.md")),
      join(repo, "shared/skills/report/SKILL.md"),
    );
    assert.ok(!existsSync(join(repo, ".codex/bridge/skills/report")));
    const adapter = readFileSync(
      join(repo, ".agents/skills/pair/SKILL.md"),
      "utf8",
    );
    assert.ok(adapter.includes('"Pair: Claude drives"'));
    assert.ok(adapter.includes("~/.agents/shared/commands/pair.md"));
    assert.ok(adapter.includes("disable-model-invocation: true"));
    assert.equal(
      readFileSync(
        join(repo, ".agents/skills/pair/agents/openai.yaml"),
        "utf8",
      ),
      "policy:\n  allow_implicit_invocation: false\n",
    );
    assert.equal(syncSkills(repo, { check: true }), 2);
    writeFileSync(
      join(repo, ".agents/skills/report/SKILL.md"),
      "---\ndescription: Updated\n---\nUpdated body\n",
    );
    assert.ok(
      readFileSync(
        join(repo, "shared/skills/report/SKILL.md"),
        "utf8",
      ).includes("Updated body"),
    );
    syncSkills(repo, { check: true });
  }));

test("runtime markers generate adapters and propagate explicit invocation from source", () =>
  inFixture((repo) => {
    writeFileSync(
      join(repo, "shared/skills/report/SKILL.md"),
      "---\ndescription: Runtime report\ncodex-adapter: true\ndisable-model-invocation: true\n---\nAuthoritative body\n",
    );
    syncSkills(repo);
    const adapter = readFileSync(
      join(repo, ".agents/skills/report/SKILL.md"),
      "utf8",
    );
    assert.ok(adapter.includes("~/.agents/shared/skills/report/SKILL.md"));
    assert.ok(adapter.includes("disable-model-invocation: true"));
    assert.ok(!adapter.includes("Authoritative body"));
    assert.equal(
      readFileSync(
        join(repo, ".agents/skills/report/agents/openai.yaml"),
        "utf8",
      ),
      "policy:\n  allow_implicit_invocation: false\n",
    );
  }));

test("check detects generated body, policy and link drift without changing bytes", () =>
  inFixture((repo) => {
    syncSkills(repo);
    const skill = join(repo, ".codex/bridge/skills/pair/SKILL.md");
    const policy = join(repo, ".codex/bridge/skills/pair/agents/openai.yaml");
    for (const file of [skill, policy]) {
      const changed = readFileSync(file, "utf8") + "Drift\n";
      writeFileSync(file, changed);
      assert.throws(
        () => syncSkills(repo, { check: true }),
        /synchronization drift/,
      );
      assert.equal(readFileSync(file, "utf8"), changed);
      syncSkills(repo);
    }
    unlinkSync(join(repo, ".agents/skills/report"));
    assert.throws(
      () => syncSkills(repo, { check: true }),
      /Discovery link: .agents\/skills\/report/,
    );
    assert.ok(!existsSync(join(repo, ".agents/skills/report")));
  }));

test("stale generated adapters are detected and safely removed; unrelated directories are refused", () =>
  inFixture((repo) => {
    syncSkills(repo);
    rmSync(join(repo, "shared/commands/pair.md"));
    assert.throws(
      () => syncSkills(repo, { check: true }),
      /Stale adapter: pair/,
    );
    assert.ok(existsSync(join(repo, ".codex/bridge/skills/pair")));
    syncSkills(repo);
    assert.ok(!existsSync(join(repo, ".codex/bridge/skills/pair")));
    assert.ok(!existsSync(join(repo, ".agents/skills/pair")));
    mkdirSync(join(repo, ".codex/bridge/skills/unrelated"));
    writeFileSync(join(repo, ".codex/bridge/skills/unrelated/keep"), "Keep");
    assert.throws(() => syncSkills(repo), /unrelated adapter/);
    assert.throws(() => syncSkills(repo, { check: true }), /unrelated adapter/);
    assert.equal(
      readFileSync(join(repo, ".codex/bridge/skills/unrelated/keep"), "utf8"),
      "Keep",
    );
  }));

test("all collisions are preflighted before any adapters are written", () =>
  inFixture((repo) => {
    mkdirSync(join(repo, ".agents/skills"), { recursive: true });
    symlinkSync("../../shared/commands", join(repo, ".agents/skills/report"));
    assert.throws(() => syncSkills(repo), /unrelated skill/);
    assert.ok(!existsSync(join(repo, ".codex/bridge")));
    unlinkSync(join(repo, ".agents/skills/report"));
    mkdirSync(join(repo, ".codex/bridge/skills"), { recursive: true });
    symlinkSync(
      "../../../shared/commands",
      join(repo, ".codex/bridge/skills/pair"),
    );
    assert.throws(() => syncSkills(repo), /unrelated adapter/);
  }));

test("duplicates and invalid metadata fail before writing", () =>
  inFixture((repo) => {
    writeFileSync(
      join(repo, "shared/commands/report.md"),
      "---\ndescription: Duplicate\n---\nBody\n",
    );
    assert.throws(() => syncSkills(repo), /Duplicate skill names/);
    rmSync(join(repo, "shared/commands/report.md"));
    for (const fields of [
      "description: [invalid]",
      "description: Report\ncodex-adapter: yes",
      'description: Report\ndisable-model-invocation: "true"',
    ]) {
      writeFileSync(
        join(repo, "shared/commands/pair.md"),
        `---\n${fields}\n---\nBody\n`,
      );
      assert.throws(() => syncSkills(repo));
      assert.ok(!existsSync(join(repo, ".codex/bridge")));
    }
  }));

test("legacy generated wrappers migrate to direct links without copying source bodies", () =>
  inFixture((repo) => {
    const target = join(repo, ".codex/bridge/skills/report");
    mkdirSync(join(target, "agents"), { recursive: true });
    writeFileSync(
      join(target, "SKILL.md"),
      '---\nname: report\ndescription: "Legacy report"\n---\n\nRead `~/.codex/bridge/runtime.md` for Codex runtime mappings.\nThen read `~/.claude/skills/report/SKILL.md` and follow its workflow with those mappings.\nThe original file is the source of truth; resolve its references from its own directory.\n',
    );
    writeFileSync(
      join(target, "agents/openai.yaml"),
      "policy:\n  allow_implicit_invocation: true\n",
    );
    mkdirSync(join(repo, ".agents/skills"), { recursive: true });
    symlinkSync(
      "../../.codex/bridge/skills/report",
      join(repo, ".agents/skills/report"),
    );
    syncSkills(repo);
    assert.ok(!existsSync(target));
    assert.equal(
      realpathSync(join(repo, ".agents/skills/report")),
      join(repo, "shared/skills/report"),
    );
    syncSkills(repo, { check: true });
  }));

test("new sources become discoverable by both tools and source removals clean managed links only", () =>
  inFixture((repo) => {
    syncSkills(repo);
    mkdirSync(join(repo, "shared/skills/new-skill"));
    writeFileSync(
      join(repo, "shared/skills/new-skill/SKILL.md"),
      "---\ndescription: New shared workflow\n---\nSingle source\n",
    );
    writeFileSync(
      join(repo, "shared/commands/new-command.md"),
      "---\ndescription: New command\n---\nCommand source\n",
    );
    assert.throws(() => syncSkills(repo, { check: true }), /Discovery link/);
    assert.ok(!existsSync(join(repo, ".claude/skills/new-skill")));
    assert.equal(syncSkills(repo), 4);
    for (const root of [".claude/skills", ".agents/skills"]) {
      assert.equal(
        realpathSync(join(repo, root, "new-skill/SKILL.md")),
        join(repo, "shared/skills/new-skill/SKILL.md"),
      );
    }
    assert.equal(
      realpathSync(join(repo, ".claude/commands/new-command.md")),
      join(repo, "shared/commands/new-command.md"),
    );
    const external = join(repo, "external-command.md");
    writeFileSync(external, "External");
    symlinkSync(
      "../../external-command.md",
      join(repo, ".claude/commands/external.md"),
    );
    mkdirSync(join(repo, ".agents/skills/thirdparty"));
    writeFileSync(join(repo, ".agents/skills/thirdparty/keep"), "Third-party");
    rmSync(join(repo, "shared/skills/new-skill"), { recursive: true });
    rmSync(join(repo, "shared/commands/new-command.md"));
    assert.throws(
      () => syncSkills(repo, { check: true }),
      /Stale discovery link/,
    );
    assert.ok(
      readFileSync(join(repo, ".claude/commands/external.md"), "utf8") ===
        "External",
    );
    syncSkills(repo);
    syncSkills(repo, { check: true });
    assert.ok(!existsSync(join(repo, ".claude/skills/new-skill")));
    assert.ok(!existsSync(join(repo, ".agents/skills/new-skill")));
    assert.ok(!existsSync(join(repo, ".claude/commands/new-command.md")));
    assert.ok(!existsSync(join(repo, ".agents/skills/new-command")));
    assert.equal(
      readFileSync(join(repo, ".agents/skills/thirdparty/keep"), "utf8"),
      "Third-party",
    );
    assert.equal(
      readFileSync(join(repo, ".claude/commands/external.md"), "utf8"),
      "External",
    );
  }));

test("Claude discovery collisions prevent all generated writes", () =>
  inFixture((repo) => {
    mkdirSync(join(repo, ".claude/commands"), { recursive: true });
    writeFileSync(
      join(repo, ".claude/commands/pair.md"),
      "Unrelated authored command",
    );
    assert.throws(() => syncSkills(repo), /unrelated skill/);
    assert.throws(() => syncSkills(repo, { check: true }), /unrelated skill/);
    assert.ok(!existsSync(join(repo, ".codex/bridge")));
    assert.ok(!existsSync(join(repo, ".agents")));
    assert.equal(
      readFileSync(join(repo, ".claude/commands/pair.md"), "utf8"),
      "Unrelated authored command",
    );
  }));
