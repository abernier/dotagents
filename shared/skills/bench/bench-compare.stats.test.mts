import assert from "node:assert/strict";
import { test } from "node:test";
import { compareSamples } from "./bench-compare.stats.mts";

// Reference values from scipy 1.18 (`mannwhitneyu`, two-sided, asymptotic,
// with continuity correction) and, for the shift and its interval, a direct
// computation from the definitions: the median of every pairwise difference,
// and its Moses order statistics.

/** R's wilcox.test example data: control, then experiment. */
const withoutTies: [number[], number[]] = [
  [0.8, 0.83, 1.89, 1.04, 1.45, 1.38, 1.91, 1.64, 0.73, 1.46],
  [1.15, 0.88, 0.9, 0.74, 1.21],
];

/** Tied ranks within and across sides: control, then experiment. */
const withTies: [number[], number[]] = [
  [1, 2, 2, 3, 3, 3, 4, 5],
  [3, 4, 4, 5, 5, 6, 6, 7],
];

test("without ties (R's wilcox.test example data): the p-value matches scipy, the shift is the Hodges-Lehmann estimate, experiment minus control, with its Moses 95% interval", () => {
  const result = compareSamples(...withoutTies);
  assert.ok(Math.abs(result.p - 0.244623605127) < 1e-6, `p = ${result.p}`);
  assert.ok(Math.abs(result.shift - -0.305) < 1e-9, `shift = ${result.shift}`);
  const [low, high] = result.interval;
  assert.ok(Math.abs(low - -0.76) < 1e-9, `low = ${low}`);
  assert.ok(Math.abs(high - 0.17) < 1e-9, `high = ${high}`);
});

test("with ties: the p-value matches scipy, the shift and its interval stay on the pairwise differences", () => {
  const result = compareSamples(...withTies);
  assert.ok(Math.abs(result.p - 0.0105152459359) < 1e-6, `p = ${result.p}`);
  assert.deepEqual([result.shift, ...result.interval], [2, 1, 4]);
});

test("identical samples on both sides: no shift, p-value 1", () => {
  const result = compareSamples([5, 5, 5, 5], [5, 5, 5, 5]);
  assert.deepEqual([result.p, result.shift, ...result.interval], [1, 0, 0, 0]);
});
