import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));

test("grilling hook reads the canonical policy through installed symlinks", () => {
  const fixture = mkdtempSync(join(tmpdir(), "dotagents-grilling-"));
  try {
    const source = join(fixture, "repo/.claude/hooks/grill-one-at-a-time.sh");
    const policy = join(fixture, "repo/shared/policies/grilling.md");
    const installed = join(
      fixture,
      "home/.claude/hooks/grill-one-at-a-time.sh",
    );
    const state = join(fixture, "state");
    for (const dir of [
      dirname(source),
      dirname(policy),
      dirname(installed),
      state,
    ]) {
      mkdirSync(dir, { recursive: true });
    }
    copyFileSync(join(repo, ".claude/hooks/grill-one-at-a-time.sh"), source);
    copyFileSync(join(repo, "shared/policies/grilling.md"), policy);
    // Relative and absolute links exercise both macOS readlink cases.
    const intermediate = join(fixture, "hook-link");
    symlinkSync(source, intermediate);
    symlinkSync("../../../hook-link", installed);

    const invoke = (hook: string, prompt: string, session = "interview") => {
      const result = spawnSync("bash", [hook], {
        input: JSON.stringify({ session_id: session, prompt }),
        encoding: "utf8",
        env: { ...process.env, TMPDIR: state },
      });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim()
        ? (JSON.parse(result.stdout).hookSpecificOutput
            .additionalContext as string)
        : undefined;
    };

    assert.equal(invoke(installed, "ordinary prompt"), undefined);
    assert.equal(
      invoke(installed, "grill me on this plan"),
      readFileSync(policy, "utf8"),
    );
    assert.equal(invoke(source, "next answer"), readFileSync(policy, "utf8"));
    const changed =
      'A changed policy with quotes: "yes".\n\nAnd a final newline.\n';
    writeFileSync(policy, changed);
    assert.equal(invoke(installed, "another answer"), changed);
    assert.equal(invoke(source, "another answer"), changed);
    assert.equal(invoke(installed, "answer", "unrelated"), undefined);
    assert.equal(invoke(installed, "end grilling"), undefined);
    assert.equal(existsSync(join(state, "claude-grill/interview")), false);
    assert.equal(invoke(installed, "next answer"), undefined);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test("grilling hook trigger and session regression checks", () => {
  const result = spawnSync(
    "bash",
    [join(repo, ".claude/hooks/grill-one-at-a-time.test.sh")],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stdout + result.stderr);
});
