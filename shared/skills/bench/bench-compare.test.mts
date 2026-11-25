import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

// Every case runs bench-compare as a caller does: through a symlink, as the
// harness installer puts it on PATH, from a working directory far from the
// harness checkout.
const scratch = mkdtempSync(join(tmpdir(), "bench-compare-"));
const executable = join(scratch, "bench-compare");
symlinkSync(
  join(dirname(fileURLToPath(import.meta.url)), "bin/bench-compare"),
  executable,
);

/**
 * Writes one sample file into the scratch directory.
 *
 * @param name The file name.
 * @param content The file's whole content.
 */
function samples(name: string, content: string) {
  const path = join(scratch, name);
  writeFileSync(path, content);
  return path;
}

/**
 * Runs bench-compare from the scratch directory.
 *
 * @param args Its arguments.
 */
function benchCompare(...args: string[]) {
  return spawnSync(executable, args, {
    cwd: scratch,
    encoding: "utf8",
    timeout: 30_000,
  });
}

const fast = "10\n11\n12\n10\n11\n12\n10\n11\n12\n11\n";
const fastFile = samples("fast.txt", fast);
const slowFile = samples(
  "slow.txt",
  "20\n21\n22\n20\n21\n22\n20\n21\n22\n21\n",
);

test("a slower experiment, lower being better, is a regression: exit 1", () => {
  const result = benchCompare("--json", fastFile, slowFile);
  assert.equal(result.status, 1, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.verdict, "regression");
  assert.deepEqual(report.metrics[0].control, { n: 10, median: 11 });
  assert.deepEqual(report.metrics[0].experiment, { n: 10, median: 21 });
  assert.equal(report.metrics[0].shift, 10);
});

test("a faster experiment, lower being better, is an improvement: exit 0", () => {
  const result = benchCompare("--json", slowFile, fastFile);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).verdict, "improvement");
});

test("--better higher turns a larger experiment into an improvement", () => {
  const result = benchCompare(
    "--json",
    "--better",
    "higher",
    fastFile,
    slowFile,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).verdict, "improvement");
});

test("overlapping samples are no difference: exit 0", () => {
  const result = benchCompare(
    "--json",
    samples("a.txt", "10\n12\n11\n13\n10\n12\n11\n13\n"),
    samples("b.txt", "11\n13\n10\n12\n11\n12\n13\n10\n"),
  );
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.verdict, "no difference");
  assert.ok(report.metrics[0].p > 0.05);
});

test("a significant shift below the minimal effect is no difference, in units or in % of the control's median", () => {
  for (const [minEffect, status] of [
    ["10.5", 0],
    ["96%", 0],
    ["10", 1],
  ] as const) {
    const result = benchCompare(
      "--json",
      "--min-effect",
      minEffect,
      fastFile,
      slowFile,
    );
    assert.equal(result.status, status, `${minEffect}: ${result.stderr}`);
    const report = JSON.parse(result.stdout);
    assert.equal(
      report.verdict,
      status === 0 ? "no difference" : "regression",
      minEffect,
    );
    assert.ok(report.metrics[0].p < 0.05, minEffect);
  }
});

test("named metrics, as a JSON object of arrays or one JSON object per line, each with its own direction", () => {
  const control = samples(
    "control.json",
    JSON.stringify({
      ms: [10, 11, 12, 10, 11, 12, 10, 11],
      fps: [60, 59, 61, 60, 59, 61, 60, 59],
    }),
  );
  const experiment = samples(
    "experiment.jsonl",
    [20, 21, 22, 20, 21, 22, 20, 21]
      .map((ms, i) => JSON.stringify({ ms, fps: [30, 29, 31][i % 3] }))
      .join("\n"),
  );
  const result = benchCompare(
    "--json",
    "--better",
    "fps=higher",
    control,
    experiment,
  );
  assert.equal(result.status, 1, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(
    report.metrics.map(
      ({ metric, better, verdict }: Record<string, string>) => [
        metric,
        better,
        verdict,
      ],
    ),
    [
      ["ms", "lower", "regression"],
      ["fps", "higher", "regression"],
    ],
  );
});

test("the default output is one line per metric", () => {
  const pair = samples(
    "pair.json",
    JSON.stringify([
      { a: 1, b: 2 },
      { a: 2, b: 3 },
      { a: 3, b: 4 },
      { a: 4, b: 5 },
    ]),
  );
  const result = benchCompare(pair, pair);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim().split("\n").length, 2);
});

test("its own failures exit 125, never 1: usage, unreadable input, mismatched metrics, too few samples", () => {
  const cases: [string[], RegExp][] = [
    [[], /\S/],
    [["--better", "sideways", fastFile, fastFile], /\S/],
    [["--better", "fps=higher", fastFile, slowFile], /no metric named fps/],
    [["--min-effect", "fps=5", fastFile, slowFile], /no metric named fps/],
    [
      ["--min-effect", "fast", fastFile, slowFile],
      /--min-effect: not a size: fast/,
    ],
    // A malformed bare default fails even when every metric overrides it.
    [
      ["--min-effect", "fast", "--min-effect", "value=5", fastFile, slowFile],
      /--min-effect: not a size: fast/,
    ],
    [[join(scratch, "absent.txt"), fastFile], /\S/],
    [[samples("garbage.txt", "12\nfast\n"), fastFile], /\S/],
    [
      [
        samples("named.json", JSON.stringify({ ms: [1, 2, 3, 4, 5] })),
        fastFile,
      ],
      /\S/,
    ],
  ];
  for (const [args, stderr] of cases) {
    const result = benchCompare(...args);
    assert.equal(result.status, 125, `${args.join(" ")}: ${result.stderr}`);
    assert.match(result.stderr, stderr, args.join(" "));
  }
});

test("one metric's samples read from any shape: a whole-file JSON array, a lone number, a lone object", () => {
  const result = benchCompare(
    "--json",
    samples("fast.json", JSON.stringify(fast.trim().split("\n").map(Number))),
    slowFile,
  );
  assert.equal(result.status, 1, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(
    report.metrics.map(({ metric }: { metric: string }) => metric),
    ["value"],
  );
  assert.deepEqual(report.metrics[0].control, { n: 10, median: 11 });

  // A file of one sample is one sample, too few to compare.
  for (const [name, content] of [
    ["one-number.txt", "42\n"],
    ["one-object.jsonl", '{"value":3}\n'],
  ]) {
    const lone = benchCompare(samples(name, content), fastFile);
    assert.equal(lone.status, 125, `${name}: ${lone.stderr}`);
    assert.match(
      lone.stderr,
      /1 control and 10 experiment samples are too few/,
      name,
    );
  }
});

test("--help exits 0", () => {
  const result = benchCompare("--help");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\S/);
});
