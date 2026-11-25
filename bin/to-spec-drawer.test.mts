import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  SPEC_HEADINGS,
  assemble,
  check,
  closeSelection,
  initialSelection,
  uncheck,
} from "../shared/skills/to-spec-drawer/toSpecDrawer.mts";
import { specModelSchema } from "../shared/skills/to-spec-drawer/toSpecDrawer.schema.mts";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const skill = join(repo, "shared/skills/to-spec-drawer");
const examplePath = join(skill, "toSpecDrawer.example.json");
const example = specModelSchema.parse(
  JSON.parse(readFileSync(examplePath, "utf8")),
);
const sorted = (ids: Iterable<string>) => [...ids].sort();

test("ticking an option ticks its parent chain and its requirements", () => {
  assert.deepEqual(sorted(check(example, [], "A3a")), ["A1", "A2", "A3a"]);
  assert.deepEqual(sorted(check(example, [], "B1")), ["A1", "B1"]);
});

test("ticking a parent ticks the default of its alternatives", () => {
  assert.deepEqual(sorted(check(example, [], "C1")), ["C1", "C1v"]);
});

test("ticking an alternative unticks the other one", () => {
  const selected = check(example, ["C1", "C1v"], "C1t");
  assert.deepEqual(sorted(selected), ["C1", "C1t"]);
});

test("unticking an option unticks everything that needs it", () => {
  const all = ["A1", "A2", "A3a", "B1", "C1", "C1v"];
  assert.deepEqual(sorted(uncheck(example, all, "A1")), ["C1", "C1v"]);
  assert.deepEqual(sorted(uncheck(example, all, "C1")), [
    "A1",
    "A2",
    "A3a",
    "B1",
  ]);
});

test("the picker opens on the recommended scope, closed", () => {
  assert.deepEqual(sorted(initialSelection(example)), [
    "A1",
    "A2",
    "A3a",
    "C1",
    "C1v",
  ]);
});

test("a selection sent back is closed over its requirements, and two alternatives are refused", () => {
  assert.deepEqual(sorted(closeSelection(example, ["A3a"])), [
    "A1",
    "A2",
    "A3a",
  ]);
  assert.throws(() => closeSelection(example, ["C1v", "C1t"]), /alternatives/);
  assert.throws(() => closeSelection(example, ["Z9"]), /Unknown option Z9/);
});

test("the spec gathers what is ticked and puts every unticked option out of scope", () => {
  const body = assemble(example, closeSelection(example, ["A1", "C1", "C1t"]));
  const section = (heading: string) =>
    body.split(`## ${heading}\n\n`)[1]!.split("\n\n## ")[0]!;
  assert.match(section("User Stories"), /^1\. .*refuse a loaded machine/);
  assert.match(section("User Stories"), /\n2\. .*compare two runs/);
  assert.doesNotMatch(body, /wait for a calm machine/);
  assert.match(section("Implementation Decisions"), /Welch/);
  assert.doesNotMatch(section("Implementation Decisions"), /Mann-Whitney/);
  for (const label of [
    "Wait until calm",
    "Calm verdict in the report",
    "In-run sampling",
    "Mann-Whitney test",
    "Benchmarking on Windows.",
  ])
    assert.match(section("Out of Scope"), new RegExp(`- ${label}`));
  assert.deepEqual(
    [...body.matchAll(/^## (.+)$/gm)].map((match) => match[1]),
    SPEC_HEADINGS,
  );
});

test("an inconsistent model is rejected with the offending option named", () => {
  const broken = (patch: (model: any) => void) => {
    const model = structuredClone(example);
    patch(model);
    return specModelSchema.safeParse(model);
  };
  const messages = (result: ReturnType<typeof broken>) =>
    result.success ? "" : result.error.issues.map((i) => i.message).join("\n");
  assert.match(
    messages(broken((model) => (model.options[0].requires = ["A3a"]))),
    /cycle/,
  );
  assert.match(
    messages(broken((model) => (model.options[1].parent = "Nope"))),
    /A2: unknown option Nope/,
  );
  assert.match(
    messages(broken((model) => (model.options[6].default = true))),
    /at most one default/,
  );
});

test("the CLI renders a picker carrying the model and the shared core", () => {
  const result = spawnSync(
    join(skill, "bin/to-spec-drawer"),
    ["render", examplePath],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /function check\(/);
  assert.match(result.stdout, /"id":"C1v"/);
  assert.match(result.stdout, /sendPrompt\(message\)/);
  assert.doesNotMatch(result.stdout, /^export /m);
  assert.doesNotMatch(result.stdout, /import type/);
});

test("the CLI assembles the spec, title on stderr, and fails on a bad selection", () => {
  const cli = (...args: string[]) =>
    spawnSync(join(skill, "bin/to-spec-drawer"), args, { encoding: "utf8" });
  const ok = cli("assemble", examplePath, "--select", "A3a");
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stderr.trim(), example.title);
  assert.equal(ok.stdout, assemble(example, closeSelection(example, ["A3a"])));
  const bad = cli("assemble", examplePath, "--select", "C1v,C1t");
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /alternatives/);
});

test("the headings still match to-spec's template", (t) => {
  const root = join(homedir(), ".claude/plugins/cache");
  const candidates = existsSync(root)
    ? readdirSync(root).flatMap((marketplace) => {
        const plugin = join(root, marketplace, "mattpocock-skills");
        return existsSync(plugin)
          ? readdirSync(plugin).map((version) => ({
              version,
              path: join(
                plugin,
                version,
                "skills/engineering/to-spec/SKILL.md",
              ),
            }))
          : [];
      })
    : [];
  const latest = candidates
    .filter((candidate) => existsSync(candidate.path))
    .sort((a, b) =>
      a.version.localeCompare(b.version, undefined, { numeric: true }),
    )
    .at(-1);
  if (!latest) return t.skip("to-spec is not installed here");
  const template = readFileSync(latest.path, "utf8").split(
    "<spec-template>",
  )[1]!;
  assert.deepEqual(
    [...template.matchAll(/^## (.+)$/gm)].map((match) => match[1]),
    SPEC_HEADINGS,
  );
});
