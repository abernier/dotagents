/**
 * Two-sided p-value of the Wilcoxon rank-sum (Mann-Whitney) test, by the
 * normal approximation with tie correction and continuity correction.
 * Two samples whose every value is equal give 1: nothing tells them apart.
 *
 * @param control The samples measured on the reference side.
 * @param experiment The samples measured on the side under test.
 */
function rankSumP(control: number[], experiment: number[]) {
  const n = control.length;
  const m = experiment.length;
  const total = n + m;
  const pooled = [
    ...control.map((value) => ({ value, control: true })),
    ...experiment.map((value) => ({ value, control: false })),
  ].sort((a, b) => a.value - b.value);

  // Tied values share the average of the ranks they span.
  let controlRankSum = 0;
  let tieTerm = 0;
  for (let start = 0; start < total;) {
    let end = start;
    while (end + 1 < total && pooled[end + 1].value === pooled[start].value) {
      end++;
    }
    const tied = end - start + 1;
    const rank = (start + end) / 2 + 1;
    for (let i = start; i <= end; i++) {
      if (pooled[i].control) controlRankSum += rank;
    }
    tieTerm += tied ** 3 - tied;
    start = end + 1;
  }

  const u = controlRankSum - (n * (n + 1)) / 2;
  const mean = (n * m) / 2;
  const variance =
    ((n * m) / 12) * (total + 1 - tieTerm / (total * (total - 1)));
  if (variance <= 0) return 1;
  const z = Math.max(0, Math.abs(u - mean) - 0.5) / Math.sqrt(variance);
  return Math.min(1, erfc(z / Math.SQRT2));
}

/**
 * Complementary error function, Chebyshev fit with a fractional error below
 * 1.2e-7 everywhere (Numerical Recipes, `erfcc`).
 *
 * @param x Any real number.
 */
function erfc(x: number) {
  const t = 1 / (1 + 0.5 * Math.abs(x));
  const y =
    t *
    Math.exp(
      -x * x -
        1.26551223 +
        t *
          (1.00002368 +
            t *
              (0.37409196 +
                t *
                  (0.09678418 +
                    t *
                      (-0.18628806 +
                        t *
                          (0.27886807 +
                            t *
                              (-1.13520398 +
                                t *
                                  (1.48851587 +
                                    t * (-0.82215223 + t * 0.17087277)))))))),
    );
  return x >= 0 ? y : 2 - y;
}

/**
 * Compares two sample sets of one metric: is the experiment shifted from the
 * control, and by how much.
 *
 * @param control The samples measured on the reference side.
 * @param experiment The samples measured on the side under test.
 */
export function compareSamples(control: number[], experiment: number[]) {
  const n = control.length;
  const m = experiment.length;
  const differences = experiment
    .flatMap((y) => control.map((x) => y - x))
    .sort((a, b) => a - b);

  // Moses: the interval runs from the k-th smallest pairwise difference to the
  // k-th largest, k the lower critical value of the rank-sum statistic under
  // the normal approximation, rounded down so the interval never narrows.
  const k = Math.floor(
    (n * m) / 2 - Z_975 * Math.sqrt((n * m * (n + m + 1)) / 12),
  );
  if (k < 1) {
    throw new RangeError(
      `${n} control and ${m} experiment samples are too few for a 95% interval`,
    );
  }

  return {
    control: { n, median: median([...control].sort((a, b) => a - b)) },
    experiment: { n: m, median: median([...experiment].sort((a, b) => a - b)) },
    p: rankSumP(control, experiment),
    shift: median(differences),
    interval: [differences[k - 1], differences[n * m - k]],
  };
}

/** The standard normal quantile for a two-sided 95% interval. */
const Z_975 = 1.959963984540054;

/**
 * Median of an ascending list.
 *
 * @param sorted Numbers in ascending order, at least one.
 */
function median(sorted: number[]) {
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}
