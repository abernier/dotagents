import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");

// Every case bounds its own waits; the timeout only keeps a hang from blocking
// the gate. bench-lock's is twice the others': it took 200 s at load 43.
const suites = [
  [
    "bench-lock.test.sh",
    "bench-lock serializes benches and passes the wrapped command through",
    600_000,
  ],
  [
    "bench-remote.test.sh",
    "bench-remote runs a pushed commit on a worker, detached, and lists and re-attaches its runs",
    300_000,
  ],
  [
    "bench-device.test.sh",
    "bench-device takes the bench lock first, refuses a device that cannot be measured on, waits for a cool phone, hands the command a fresh, wired Chrome and says in which state it measures",
    300_000,
  ],
  [
    "bench-ab.test.sh",
    "bench-ab runs control and experiment interleaved after a discarded warmup, under one bench lock, saves the samples and hands them to bench-compare",
    300_000,
  ],
] as const;

for (const [suite, title, timeout] of suites) {
  test(title, () => {
    const result = spawnSync(
      "bash",
      [join(repo, "shared/skills/bench", suite)],
      { encoding: "utf8", timeout },
    );
    assert.equal(
      result.status,
      0,
      `${result.stdout}${result.stderr}${result.error ?? ""}`,
    );
  });
}
