// bench-compare: compare two sample sets of one or several metrics, the
// TracerBench way, and say whether the experiment regressed. Input and
// options: "Compare two builds"; output, verdict and exit codes: "The
// bench-compare verdict". Both in this skill's SKILL.md.
// The statistics live in bench-compare.stats.mts; this file reads the
// samples, applies the direction and minimal effect, and reports.
import { readFileSync } from "node:fs";
import { Command, CommanderError, Option } from "commander";
import { z } from "zod";
import { compareSamples } from "./bench-compare.stats.mts";

/** A failure of bench-compare itself: exit 125. */
class UsageError extends Error {}

/** The significance level matching the 95% interval. */
const ALPHA = 0.05;

/** The metric name of samples given as bare numbers. */
const SINGLE_METRIC = "value";

const numbersSchema = z.array(z.number()).describe("Samples of one metric");
const sampleSchema = z
  .record(z.string(), z.number())
  .describe("One sample: each metric's name and its reading");
const fileSchema = z
  .union([
    numbersSchema,
    z.array(sampleSchema),
    z.record(z.string(), numbersSchema),
  ])
  .describe(
    "One side's samples: bare numbers, one object per sample, or each metric's array",
  );

type Metrics = Map<string, number[]>;

/**
 * Gathers per-sample objects into each metric's list of readings.
 *
 * @param samples One object per sample.
 */
function fromSamples(samples: z.infer<typeof sampleSchema>[]) {
  const metrics: Metrics = new Map();
  for (const sample of samples) {
    for (const [name, reading] of Object.entries(sample)) {
      metrics.set(name, [...(metrics.get(name) ?? []), reading]);
    }
  }
  return metrics;
}

/**
 * Reads one side's samples, in any of the accepted shapes.
 *
 * @param path The sample file.
 */
function readSamples(path: string) {
  let content: string;
  try {
    content = readFileSync(path, "utf8");
  } catch (error) {
    throw new UsageError(`cannot read ${path}: ${(error as Error).message}`);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    // Not one JSON document: one sample per line.
    const lines = content
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line !== "");
    parsed = lines.map((line, index) => {
      if (line.startsWith("{")) {
        try {
          return JSON.parse(line);
        } catch {
          throw new UsageError(`${path}:${index + 1}: not a JSON object`);
        }
      }
      const reading = Number(line);
      if (!Number.isFinite(reading)) {
        throw new UsageError(`${path}:${index + 1}: not a number: ${line}`);
      }
      return reading;
    });
  }
  // A file of one line, a bare number or one sample object, is a whole JSON
  // document too: it is that one sample, never a file of another shape.
  if (typeof parsed === "number" || sampleSchema.safeParse(parsed).success) {
    parsed = [parsed];
  }

  const file = fileSchema.safeParse(parsed);
  if (!file.success) {
    throw new UsageError(
      `${path}: expected numbers, objects of named numbers, or arrays of numbers by metric`,
    );
  }
  const data = file.data;
  if (Array.isArray(data)) {
    if (data.every((sample) => typeof sample === "number")) {
      return new Map([[SINGLE_METRIC, data]]);
    }
    return fromSamples(data as z.infer<typeof sampleSchema>[]);
  }
  return new Map(Object.entries(data));
}

const betterSchema = z
  .enum(["lower", "higher"])
  .describe("Which way a metric is better");

/** One occurrence of a per-metric option: its metric, or none for the bare default. */
type Scoped<T> = { metric: string | undefined; value: T };

/**
 * Parses every occurrence of a per-metric option, `<metric>=<value>` or a
 * bare default, checking each value and each metric name once.
 *
 * @param raws Every occurrence of the option, as typed.
 * @param metrics The metrics compared.
 * @param parseValue Parses one value, throwing a UsageError when malformed.
 */
function parseScoped<T>(
  raws: string[],
  metrics: Metrics,
  parseValue: (value: string) => T,
) {
  return raws.map((raw) => {
    const at = raw.lastIndexOf("=");
    const metric = at === -1 ? undefined : raw.slice(0, at);
    if (metric !== undefined && !metrics.has(metric)) {
      throw new UsageError(`no metric named ${metric}`);
    }
    return { metric, value: parseValue(at === -1 ? raw : raw.slice(at + 1)) };
  });
}

/**
 * Commander collector for a repeatable option.
 *
 * @param value This occurrence.
 * @param previous The earlier ones.
 */
function collect(value: string, previous: string[]) {
  return [...previous, value];
}

/**
 * Resolves a per-metric option for one metric: its own value, else the bare
 * default, else the fallback.
 *
 * @param options Every parsed occurrence of the option.
 * @param metric The metric to resolve it for.
 * @param fallback The value when the option names neither.
 */
function optionFor<T>(options: Scoped<T>[], metric: string, fallback: T) {
  // The last occurrence wins, as for any repeated option.
  const latestFirst = [...options].reverse();
  return (
    latestFirst.find((option) => option.metric === metric)?.value ??
    latestFirst.find((option) => option.metric === undefined)?.value ??
    fallback
  );
}

function parseBetter(raw: string) {
  const better = betterSchema.safeParse(raw);
  if (!better.success) {
    throw new UsageError(`--better: expected lower or higher, got ${raw}`);
  }
  return better.data;
}

/**
 * Parses a --min-effect value: a size in the metric's unit, or a percentage
 * of the control's median.
 *
 * @param raw The value as typed.
 */
function parseMinEffect(raw: string) {
  const percent = raw.endsWith("%");
  const size = Number(percent ? raw.slice(0, -1) : raw);
  if (raw.trim() === "" || !Number.isFinite(size) || size < 0) {
    throw new UsageError(`--min-effect: not a size: ${raw}`);
  }
  return { size, percent };
}

/**
 * The minimal effect for one metric, in the metric's own unit.
 *
 * @param effect The parsed --min-effect value.
 * @param controlMedian The control's median for that metric.
 */
function minimalEffect(
  effect: ReturnType<typeof parseMinEffect>,
  controlMedian: number,
) {
  return effect.percent
    ? (Math.abs(controlMedian) * effect.size) / 100
    : effect.size;
}

type Verdict = "regression" | "improvement" | "no difference";

/**
 * Compares both sides metric by metric.
 *
 * @param controlPath The control's sample file.
 * @param experimentPath The experiment's sample file.
 * @param options The parsed command-line options.
 */
function compare(
  controlPath: string,
  experimentPath: string,
  options: { better: string[]; minEffect: string[] },
) {
  const control = readSamples(controlPath);
  const experiment = readSamples(experimentPath);
  const names = [...control.keys()];
  const missing = [
    ...names.filter((name) => !experiment.has(name)),
    ...[...experiment.keys()].filter((name) => !control.has(name)),
  ];
  if (missing.length > 0) {
    throw new UsageError(`metrics missing on one side: ${missing.join(", ")}`);
  }
  const betters = parseScoped(options.better, control, parseBetter);
  const minEffects = parseScoped(options.minEffect, control, parseMinEffect);

  const metrics = names.map((metric) => {
    let comparison;
    try {
      comparison = compareSamples(
        control.get(metric)!,
        experiment.get(metric)!,
      );
    } catch (error) {
      if (error instanceof RangeError) {
        throw new UsageError(`${metric}: ${error.message}`);
      }
      throw error;
    }
    const better = optionFor(betters, metric, "lower");
    const minEffect = minimalEffect(
      optionFor(minEffects, metric, { size: 0, percent: false }),
      comparison.control.median,
    );
    const significant =
      comparison.p < ALPHA &&
      comparison.shift !== 0 &&
      Math.abs(comparison.shift) >= minEffect;
    const worse =
      better === "lower" ? comparison.shift > 0 : comparison.shift < 0;
    const verdict: Verdict = !significant
      ? "no difference"
      : worse
        ? "regression"
        : "improvement";
    return {
      metric,
      ...comparison,
      better,
      minEffect,
      verdict,
    };
  });

  const verdicts = metrics.map(({ verdict }) => verdict);
  const verdict: Verdict = verdicts.includes("regression")
    ? "regression"
    : verdicts.includes("improvement")
      ? "improvement"
      : "no difference";
  return { verdict, metrics };
}

/**
 * Formats a reading for a human: four significant digits, sign on a shift.
 *
 * @param value The reading.
 * @param signed Whether to print a plus sign on a positive value.
 */
function format(value: number, signed = false) {
  const text = String(Number(value.toPrecision(4)));
  return signed && value > 0 ? `+${text}` : text;
}

const program = new Command()
  .name("bench-compare")
  .description(
    "Compare two sample sets: Wilcoxon rank-sum test, Hodges-Lehmann shift (experiment minus control) with its 95% interval, and a verdict per metric.",
  )
  .argument("<control>", "the control's sample file")
  .argument("<experiment>", "the experiment's sample file")
  .addOption(
    new Option(
      "--better <direction>",
      "which way is better: lower or higher, for every metric, or <metric>=lower|higher; repeatable",
    )
      .argParser(collect)
      .default([], "lower"),
  )
  .addOption(
    new Option(
      "--min-effect <size>",
      "smallest shift that counts, in the metric's unit or as a % of the control's median (5, 2%), or <metric>=<size>; repeatable",
    )
      .argParser(collect)
      .default([], "0"),
  )
  .option("--json", "print one JSON document instead of one line per metric")
  .exitOverride()
  .action((controlPath: string, experimentPath: string, options) => {
    const report = compare(controlPath, experimentPath, options);
    if (options.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      for (const m of report.metrics) {
        console.log(
          `${m.metric}: ${m.verdict}, shift ${format(m.shift, true)} (95% CI ${format(m.interval[0], true)} to ${format(m.interval[1], true)}), p ${format(m.p)}; median ${format(m.control.median)} -> ${format(m.experiment.median)}, n ${m.control.n} / ${m.experiment.n}`,
        );
      }
    }
    process.exitCode = report.verdict === "regression" ? 1 : 0;
  });

try {
  program.parse();
} catch (error) {
  if (error instanceof CommanderError) {
    // Commander has printed its own message; only help is not a failure.
    process.exitCode = error.code === "commander.helpDisplayed" ? 0 : 125;
  } else {
    const message = error instanceof UsageError ? error.message : error;
    console.error(`bench-compare: ${message}`);
    process.exitCode = 125;
  }
}
