import assert from "node:assert/strict";
import { test } from "node:test";
import { claudeSettingsDrift, codexConfigDrift } from "./template-drift.mts";

test("a hook under another matcher is not the template's hook", () => {
  const template = JSON.stringify({
    hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ command: "x" }] }] },
  });
  const local = JSON.stringify({
    hooks: { PreToolUse: [{ matcher: "Edit", hooks: [{ command: "x" }] }] },
  });
  const drift = claudeSettingsDrift(template, local, "/home/me");
  assert.deepEqual(drift.missing, ["hook PreToolUse matcher Bash: x"]);
});

test("invalid local JSON is reported, never rewritten", () => {
  const drift = claudeSettingsDrift("{}", "{ not json", "/home/me");
  assert.equal(drift.updated, undefined);
  assert.equal(drift.missing.length, 1);
});

test("TOML keys inside tables or multi-line values are not top-level", () => {
  const local = 'list = [\n  "a",\n]\n\n[table]\nnotify = ["x"]\n';
  const drift = codexConfigDrift('notify = ["y"]\nlist = []\n', local);
  assert.deepEqual(drift.missing, ["key notify"]);
  assert.equal(
    drift.updated,
    'list = [\n  "a",\n]\n\nnotify = ["y"]\n\n[table]\nnotify = ["x"]\n',
  );
});

test("a multi-line template value is reported only", () => {
  const drift = codexConfigDrift('list = [\n  "a",\n]\n', "");
  assert.deepEqual(drift.missing, ["key list"]);
  assert.equal(drift.updated, undefined);
  assert.match(drift.reportOnly ?? "", /spans several lines/);
});

test("a TOML file with no table gets the key appended", () => {
  assert.equal(codexConfigDrift("a = 1\n", "b = 2").updated, "b = 2\na = 1\n");
});
