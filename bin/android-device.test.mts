import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");

test("adb-tailnet resolves a Tailscale host, finds the wireless debugging port and says when this computer is not paired", () => {
  const result = spawnSync(
    "bash",
    [join(repo, "shared/skills/android-device/adb-tailnet.test.sh")],
    { encoding: "utf8", timeout: 60_000 },
  );
  assert.equal(
    result.status,
    0,
    `${result.stdout}${result.stderr}${result.error ?? ""}`,
  );
});
