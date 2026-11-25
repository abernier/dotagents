---
name: bench
description: Run, compare and trust benches with `bench-lock`, `bench-remote`, `bench-device`, `bench-ab` and `bench-compare`. Use when about to run, wire, wait on or diagnose a bench; when comparing two builds or checking a change for a regression; when calibrating a minimal effect or a noise threshold; when a result looks noisy or a bench comes back red; or when a bench should measure on a phone.
---

# Bench

A bench is a measurement that needs the machine to itself. A machine runs one
bench at a time, every repo included, through its single bench lock. Five
commands share the work:

| Command         | Does                                                           |
| --------------- | -------------------------------------------------------------- |
| `bench-lock`    | queues a bench for the machine's lock, judges the machine calm |
| `bench-remote`  | runs a bench on the quiet machine, from the current commit     |
| `bench-device`  | runs a bench on a phone plugged into this machine              |
| `bench-ab`      | runs two builds interleaved in one session, under one lock     |
| `bench-compare` | says whether the experiment's samples shifted from the control |

How each one works (waits, retries, what it copies, what it checks) is in its
header comment, in this skill's `bin/`: the reference, read it when a detail
matters. This skill says which to reach for, how to read what they print, and
what to do with it. Each repo keeps its own bench recipe (entry point, control
build, thresholds, counters) in its own docs.

## Install

`bench-lock`, `bench-remote`, `bench-device`, `bench-ab` and `bench-compare`
live in this skill's `bin/` and reach PATH (`~/.local/bin`) through the
harness installer, like the skill itself. One missing from PATH means this
machine's harness install is behind: the `harness` skill says how to bring it
up to date. Never copy them by hand on a machine that has the harness.

A worker needs none of them installed: `bench-remote` copies `bench-lock`,
`bench-device` and `bench-ab` there on every run. `bench-compare` runs on the
caller only, from the harness checkout and its `pnpm install`.

## Choose the run

Answer in order; each answer names the section to follow.

1. **One build or two?** A question about one build (does it pass the repo's
   thresholds?) is one bench: "Run a bench". A question about a change (did
   it regress, is it faster?) is an A/B session: "Compare two builds". One
   reading per side never tells a change from noise.
2. **Is the minimal effect calibrated?** An A/B session needs the repo's
   `--min-effect`, measured on the machine that benches. None yet, or the
   machine, run count or bench changed: "Calibrate the minimal effect" first.
3. **Here or on the quiet machine?** Local measures the working tree,
   uncommitted changes included, and is the default for work not yet
   committed. Go remote, through `bench-remote`, when the local machine is
   loaded (other sessions, builds, browsers), when a local result came back
   noisy, or when the result will be reported as evidence. Remote is always a
   choice: "Run on the quiet machine".
4. **On a phone too?** When the change touches what only a phone reveals
   (gestures, the mobile GPU, thermal limits), add a device run beside the
   desktop one: "Measure on a phone".

Then read every line as "Read the results" says, and act as "Act on the
outcome" says.

## Run a bench

Run a bench through the repo's own bench entry point: once wired, it takes the
lock by itself. Use `bench-lock run -- <command...>` directly only for a
command no repo wires. `bench-lock status` shows who holds the lock and who
waits.

A bench that waits is queued, never failed: let it wait. Its waiting line on
stderr names the holder when there is one.

### Wire a repo's bench

The repo's bench entry point carries a shim, and the repo knows nothing else
of the harness: the only contract is the command name `bench-lock` on PATH.

1. Pre-flight checks first: whatever decides that this bench will not measure
   (a skip switch, a refused cache, a missing build) runs before the shim, so
   a bench that will not measure never queues.
2. `BENCH_LOCK_HELD` set: the run is already under the lock. Carry on.
3. `bench-lock` on PATH: re-launch the same entry point, same arguments,
   through `bench-lock run --`, and return its exit code unchanged.
4. `bench-lock` absent: print on stderr that this run is not isolated, then
   carry on. The exit code stays the bench's own.

Steps 2 to 4 in a bash entry point:

```sh
if [ -z "${BENCH_LOCK_HELD:-}" ]; then
  if command -v bench-lock >/dev/null 2>&1; then
    exec bench-lock run -- bash "$0" "$@"
  fi
  echo "bench: bench-lock is not on PATH; this run is NOT isolated, another bench may share the machine" >&2
fi
```

Where there is no `exec` (a Node driver), step 3 runs `bench-lock run --`
with the same entry point and arguments as a child, with inherited stdio, and
exits with its code. The shim carries no other logic.

A repo's bench never calls `bench-compare` itself: a worker has none, so the
check would be skipped there. It prints its samples, and `bench-ab`, or the
caller, compares them.

To have a remote run judged, a repo's own bench prints on stdout the lines
`bench-ab` prints: `bench: compare option <arg>`, one option argument per
line, then `bench: sample <control|experiment> <sample>`, one per run per
side, the sample a number or a JSON object of named metrics. `bench-remote`
compares them on the caller; when the command exited 0, the verdict decides
the exit code.

A bench that starts processes outside its own process tree (a browser
launched through `open` on macOS, which launchd owns) appends their pids, one
per line, to the file `BENCH_LOCK_OWN_PIDS` names. The end-of-run reading then
counts them as the bench's, not as outside load, and never names them culprits,
from the run's first reading on: a pid declared late still covers the
startup it missed, when a browser is at its busiest.

What the bench makes a system process do stays outside load: macOS's
WindowServer, compositing a headed browser's windows, about a quarter of one
core (0.03 per core on an 8-core Mac). It cannot be declared, since it
composites for every app on the display; a bench whose share there matters
runs its browser headless.

### Run on the quiet machine

Your instructions name the quiet machine; the host is always given
explicitly. Run from inside the repo's checkout, on the commit to measure:

```sh
bench-remote <host> -- <command...>   # run it there, from the current commit
bench-remote <host> status            # the runs kept there: id, state, command
bench-remote <host> attach <id>       # follow one to its end, return its exit code
```

The command is the repo's own bench entry point, as you would run it locally
(`bench-remote <host> -- pnpm bench`), or a whole `bench-ab` session.

- It measures the commit you are on, and never pushes: pushing stays a
  decision of its own. When `HEAD` is already on origin, the worker fetches
  from origin; when `HEAD` is unpushed, `bench-remote` transfers the unpushed
  delta over ssh as a `git bundle` so remote runs work without pushing first
  (note that an unpushed SHA may disappear if later amended or rebased).
  Uncommitted changes are left out: changes to tracked files with a warning,
  untracked files silently.
- The worker keeps one checkout per repository at `~/bench/<name>`, named
  after the repository's base name only: two repositories with the same name
  share it.
- The repository's `.nvmrc` decides the node on the worker, through nvm,
  installed first when missing; without one, or without nvm, the login
  shell's.
- The worker's bench lock is held from the fetch to the end of the command,
  so a remote run queues behind any bench already on that machine.
- The exit code is the bench's own, 255 included, except two: 125 when
  `bench-remote` itself failed, a step before the command (fetch, checkout,
  node, install) did (the log says which), or the connection stayed lost
  beyond its retries; 130 after Ctrl-C. A `bench-ab` session that exits 0
  takes the caller's `bench-compare` verdict instead: "Run an A/B session".

The run goes on whatever happens to the connection. Its id is on the
`bench-remote: run <id> on <host>` line it prints first; a lost connection
and Ctrl-C both print the `attach` line that picks it up, and `attach` gives
the real exit code. `status` says `starting` only while the launched process
lives; `not started` is a launch that died before its job got going.

### Diagnose a wait

`bench-lock status` is the whole diagnosis: the holder and every waiter, with
pid, age, working directory and command. The state directory is the tool's
alone: leave the lock to `bench-lock`. Deleting it by hand lets a second bench
run beside the first.

A long-held lock is a long measurement until you judge otherwise. A holder you
judge hung, from its age and command, you kill by hand: the pid `status`
prints is the bench command itself, so `kill <pid>` ends the bench, and the
lock passes to the next waiter. Children it spawned outlive it unless the
signal reaches them too: list them first (`pgrep -P <pid>`), since a leftover
child still loads the machine.

## Compare two builds

Run both builds in one A/B session with `bench-ab`, or give `bench-compare`
samples your runner already saved.

### Run an A/B session

```sh
bench-ab [-n <runs>] [--warmup <runs>] [--out <dir>] [--drop-noisy] \
         --control <command> --experiment <command> [-- <bench-compare option>...]
```

Each command is one shell command line that runs the bench once and prints
one sample on stdout: a number, or a JSON object of named numbers. That is the
whole contract with the repo; its stderr passes through. A command that prints
no number of its own is timed in milliseconds through node (macOS and Linux
alike), its own output sent to stderr:

```sh
time_ms='node -e '\''const t = performance.now(); const r = require("child_process").spawnSync(process.argv[1], process.argv.slice(2), { stdio: [0, 2, 2] }); if (r.status !== 0) process.exit(1); console.log((performance.now() - t).toFixed(1))'\'
bench-ab --control "$time_ms pnpm build" --experiment "$time_ms pnpm build:next"
```

The runs are interleaved and counterbalanced (AB BA AB ...), so drift,
background load and the position in a pair fall on both sides alike:
`--warmup` runs per side first (default 1), discarded, then `-n` measured
runs per side (default 10).

The whole session is one bench: it takes the bench lock once, through the shim
of "Wire a repo's bench", so the commands run under the lock and need no shim
of their own. It writes into `--out` (default: a fresh temporary directory,
named on stderr):

| File                                    | Holds, one line per measured run, in run order                     |
| --------------------------------------- | ------------------------------------------------------------------ |
| `control`, `experiment`                 | the samples, `bench-compare`'s input                               |
| `control.reading`, `experiment.reading` | the worse of the calm verdicts taken just before and just after it |
| `control.calm`, `experiment.calm`       | with `--drop-noisy` only: the samples whose reading is calm        |

The machine is read between runs, never during one, about a second each: a
session takes that much longer per measured run.

With `--drop-noisy`, only the `.calm` files are compared (`no verdict` counts
as noisy), and stderr says how many samples were dropped per side, as noisy or
unread.

Stdout always carries what is compared, as `bench: compare option` and
`bench: sample` lines (format in `bin/bench-ab`'s header). With
`bench-compare` on PATH, it then runs on the samples, with the options after
`--`, and its output and exit code are the session's. Without it, the session
exits 0 and stderr gives the `bench-compare` line to run elsewhere, or, under
`bench-remote`, says that `bench-remote` compares on the caller.

A run that fails or prints anything but one sample stops the session, exit
125, as does a usage error, refused before the lock. Too few calm samples
under `--drop-noisy`: "Too few samples left", in "Act on the outcome".

On the quiet machine, run the session through `bench-remote`: it gives the
verdict and the exit code directly.

```sh
bench-remote <host> -- bench-ab --control '<command>' --experiment '<command>' [-- <bench-compare option>...]
```

`bench-remote` compares the samples from the run log with the caller's
`bench-compare`, after a `bench-remote: comparing on <caller>` line: its
output and exit code are the run's. Without `bench-compare` on the caller, the
run exits 125, unjudged. A session that failed on the worker keeps its own
code, uncompared. `attach` compares a finished session the same way.

The readings files stay on the worker, in the directory the log's
`bench-ab: samples in <dir>/control ...` line names: read them there
(`ssh <host> cat <dir>/control.reading <dir>/experiment.reading`).

### Compare samples

```sh
bench-compare [--better ...] [--min-effect ...] [--json] <control> <experiment>
```

Each file holds one side's samples, in whatever your runner already prints:

- one number per line, or a JSON array of numbers: one metric, named `value`
- one JSON object of named numbers per line, or a JSON array of such
  objects: one object per sample
- a JSON object mapping each metric's name to its array of numbers

Both sides carry the same metrics.

- `--better lower` (the default) or `higher` says which way is worse, for
  every metric or one (`--better fps=higher`).
- `--min-effect` is the smallest shift that counts, in the metric's unit or
  as a percentage of the control's median (`5`, `2%`, `ms=5`). At its
  default, 0, every significant shift counts: set it from "Calibrate the
  minimal effect".
- `--json` prints the result as one document, with an overall `verdict`, for
  a script.

### Calibrate the minimal effect

A repo's `--min-effect` sits above its real noise, measured on the machine
that benches, never guessed. Calibrate it with an A/A session: the same build
on both sides, so every shift it reports is noise.

1. Run `bench-ab` with the control command as both `--control` and
   `--experiment`, at the `-n` and `--warmup` the repo's A/B sessions use, on
   the machine that benches.
2. Read `bench-compare`'s line per metric. The medians should match and the
   verdict should be no difference; a regression or improvement here means a
   side is not the same build or the machine is not calm, so fix that first.
3. The spread is the widest the noise reaches: the larger of the 95%
   interval's two bounds, in absolute value. Repeat the session two or three
   times and keep the widest spread per metric.
4. Set `--min-effect` per metric at 2 to 3 times that spread (3 for the
   noisier metrics), in the metric's unit, or as a percentage of the median
   when the repo benches several sizes.

The calibrated values live in the repo's own A/B recipe, beside its control
build. A repo without a recipe: report the value with the A/B verdict it
judged.

## Read the results

Every bench under the lock, local or remote, prints its calm verdict lines on
stderr, `bench-lock:` first. Keep them beside any result you report: they
name the machine the numbers come from and say how far to trust them. A bench
without them ran outside the lock: weigh it as noisy.

### The start verdict

Printed by the `bench-lock` that takes the lock, just before the command:

```text
bench-lock: on <machine>, cpu 0.42 per core: calm (noisy above 0.50)
```

- `cpu` is how busy the CPU is, sampled over the second before the run.
- `load` in its place is the fallback when that sampling failed: the
  one-minute load average, which lags, so a calm `load` is weaker evidence.
- `load unknown: no verdict`: neither could be read. Weigh the run as noisy.

The threshold in parentheses is `BENCH_LOCK_NOISY_ABOVE`, set per machine in
that machine's own environment: on a worker, its bash login profile
(`~/.bash_profile`, else `~/.profile`), whatever the login shell, since a
remote run starts through `bash -l` and reads nothing of the caller's. A
dedicated worker takes `0.2`: with nothing else running there, any load above
it is a background job.

### The settle wait

A noisy machine is waited on first, under the lock, until it reads calm:
`waiting for the machine to settle` lines, queueing like a lock wait, so let
it wait. The wait is capped at 120 s (`BENCH_LOCK_SETTLE` sets the cap in
seconds, 0 turns it off). A wait that runs out starts the bench anyway, its
start verdict ending `the settle wait ran out after <n>s`: noisy.

### The end-of-run verdict

After everything the command printed, one line gives the load besides the
bench, read every 2 s while it ran (each reading covers about a second),
judged on its 90th percentile, the busiest reading and the mean given for
information:

```text
bench-lock: on <machine>, during the run, cpu besides the bench p90 0.55, max 0.62, mean 0.31 per core: noisy (noisy above 0.50)
```

The bench's own share is subtracted (how: `bin/bench-lock`'s header), so a
bench that keeps every core busy reads calm on an otherwise quiet machine. The
percentile forgives one noisy second in ten, a background daemon waking up;
load that lasts is not forgiven. It is the nearest rank, so a run of fewer
than ten readings (under about 20 s) is judged on its busiest. A max well
above the p90 is a burst that the verdict let pass; a mean near the p90 is
load that stayed.

The line covers the whole run, unless the bench's own process calls
`bench-lock settle` once it is ready to measure: the reading starts over
there. A remote run does so after its install, so its line covers the command
alone, and its start verdict comes twice: before the fetch, and again after
the install with its own settle wait, the one that judges the bench; a device run does so once the phone is prepared and cooled, so its
line covers the measurement alone.

### Thermal and power, on macOS

The end-of-run samples also read what slows a CPU without loading it, the
worst of the run kept:

- `; CPU speed limit down to <n>%: noisy`: the system throttled the CPU at
  some sample. Intel Macs only.
- `; thermal pressure <level>: noisy`: the system reported thermal pressure
  at some sample. On Apple Silicon it is the only throttling signal.
- `; on battery power: noisy`: the run drew from the battery at some sample.
- `<reading> unknown`: that reading gave no value, flagged neither way.

Any flag makes the run noisy whatever the CPU reads; no segment means no
flag. Where each reading comes from: `bin/bench-lock`'s header.

### The culprits

A noisy verdict, at the start or at the end, is followed by one line: the
three busiest processes besides the bench, with their CPU percent of one
core; at the end, those of the readings above the threshold, their CPU
percent averaged over those readings.

```text
bench-lock: busiest besides the bench: node (pid 4242, 85% cpu), WindowServer (pid 586, 40% cpu), mds (pid 12, 12% cpu)
```

`none` means no other process was busy. Linux gives each process's average
over its whole life, so a long-lived process ranks higher there than its
current load.

### The A/B session's readings

Each line of `<side>.reading` is the worse of the two readings around that
one run, without the machine's name. A noisy line marks a sample measured
while something else loaded the machine, just before or just after it.

### The bench-compare verdict

One line per metric:

```text
value: regression, shift +2.5 (95% CI +1 to +3), p 0.001119; median 11 -> 13, n 8 / 8
```

- The verdict: `regression` or `improvement` when p < 0.05 and the shift
  reaches the minimal effect, in the direction `--better` names; else
  `no difference`.
- `shift`: the Hodges-Lehmann estimate of experiment minus control, in the
  metric's unit, with its 95% interval (Moses).
- `p`: the Wilcoxon rank-sum test (normal approximation, tie-corrected).
- `median control -> experiment`, and each side's sample count.

Exit codes: 0 no regression, 1 at least one metric regressed, 125
`bench-compare` itself failed: usage, an unreadable file, metrics differing
between sides, or too few samples ("Too few samples left", in "Act on the
outcome").

### The device verdict

A device run's last stderr line before the command:

```text
bench-device: on Pixel 8 (1A2B3C4D5E6F7G): thermal status none, battery temperature 25.6 C, battery health good, Chrome 156.0.8078.79
```

- Thermal status other than `none`, or a note that the wait ran out: the
  phone may have throttled during the run. Weigh it as noisy.
- Battery health flagged `not good`: the permanent charge is wearing the
  battery, and the measurements are next. Tell the owner.
- A Chrome version other than the one the repo's device thresholds were
  calibrated on: Chrome updated. Recalibrate them (A/A runs on the phone, the
  repo's docs say how) before trusting a verdict.
- `unknown`: that reading failed. The information is missing; the run stands.

## Act on the outcome

A run is **calm** when its start verdict (on a remote run, the post-install
one) and its end-of-run verdict read calm, with no thermal or power flag, and,
for an A/B session, every compared sample's reading is calm. Anything else is
**noisy**.

- **A calm regression stands.** A red bench, or a `regression` from
  `bench-compare`, measured calm: report it with the shift, its interval, and
  the calm lines, machine included.
- **A noisy regression is a suspect: rerun it** before believing it, on the
  quiet machine through `bench-remote` when you can, else locally once the
  verdict reads calm. Before rerunning, close what you own among the culprits
  (another session's build, a stray watcher, a browser) and leave the
  system's own; one you cannot place, name to the owner. In an A/B session
  where only a few readings are noisy, rerun with `--drop-noisy`; when many
  are, rerun the whole session on a calm machine, since what is left after
  dropping is a smaller and less interleaved sample.
- **An improvement** follows the same two rules: calm stands, noisy is rerun.
- **No difference within the minimal effect**: read the interval. Inside the
  minimal effect, the change does not move this metric by an amount that
  counts: report that, with the interval. Straddling the minimal effect, the
  session cannot tell: rerun with a larger `-n`.
- **Too few samples left**: a 95% interval needs, with equal sides, 4
  samples each. Fewer is exit 125, from `bench-compare`, or from `bench-ab`
  itself under `--drop-noisy` (worker included): never a verdict. Rerun with
  a larger `-n`, on a calm machine.
- **Any other exit 125** is a tool's own failure: fix what its stderr names
  and rerun. On a device run, only a device run stands in for a device run.

## Measure on a phone

A phone run adds to the desktop bench, never replaces it. The phone is
plugged into the quiet machine, so the run goes through `bench-remote`, with
the repo's device option on its own bench command
(`bench-remote <host> -- pnpm bench --device [serial]`).

A repo wires its device option by re-launching its entry point through
`bench-device`, in place of the `bench-lock` shim, since `bench-device` takes
the lock itself:

```sh
bench-device run [--serial <serial>] [--reverse <port>]... -- <command...>
```

- A device that cannot be measured on is refused, exit 125, with a line
  saying what to fix.
- A device run waits twice, and both waits are queueing: for the machine's
  bench lock, then, under it, for the phone to cool. Let it wait.
- Device numbers compare only with numbers from the same device on the same
  Chrome version: never with desktop numbers, never across a Chrome update.

## Prepare a worker

What a worker must have, checked in its bash login shell (`ssh <host> bash -lc
'command -v git pnpm'`), since every remote run starts there:

- ssh access from the caller, by host name.
- git, and GitHub reachable over HTTPS: the worker clones and fetches origin
  itself (an unpushed commit's delta arrives over ssh as a bundle).
- pnpm; nvm when a repository has an `.nvmrc`, else the node it needs.
- For a phone run, `adb` (`brew install android-platform-tools` on macOS),
  and the phone plugged in over USB.
- A dedicated worker's calm threshold, as "The start verdict" says.

Install what is missing yourself when you can reach the worker; a password
prompt (sudo) is the owner's.

Owner steps, once per worker, before it takes benches:

1. Wired Ethernet when possible: a Wi-Fi leg drops connections, and a launch
   caught by a drop is retried, not free.
2. Never sleeps: `sudo pmset -a sleep 0` on macOS. A run also holds
   `caffeinate -i` where it exists, but a worker asleep between runs is
   unreachable.
3. No background job that can start mid-run. On macOS:
   - Spotlight skips the bench checkouts. Every fetch and install rewrites
     them, and indexing follows. Spotlight never indexes a folder whose name
     ends in `.noindex`, so keep them there behind the path the tools use, no
     sudo needed: `mv ~/bench ~/bench.noindex && ln -s bench.noindex ~/bench`,
     while no bench holds the lock.
   - Time Machine automatic backups off: `sudo tmutil disable`.
   - Automatic macOS updates off, download and install included
     (System Settings, General, Software Update, Automatic Updates).

## Prepare the phone

Owner steps, once per phone, before it takes benches. A drifted setting
whose effect `bench-device` checks is a refusal naming it; a trusted one
shows only as noise.

| Setting                                              | Each run, `bench-device` |
| ---------------------------------------------------- | ------------------------ |
| Developer options: Stay awake (while charging) on    | checks the screen awake  |
| Screen lock: None                                    | checks no keyguard       |
| USB debugging on, the host allowed with Always allow | checks it is authorized  |
| Wi-Fi off                                            | trusts it                |
| Notifications and background sync off                | trusts it                |
| Play Store auto-update off for Chrome                | trusts it                |

A Chrome updated anyway shows as a new version in the device verdict.

- Battery: on charge for good, held at 100% where the phone offers no charge
  limit (Android 14 on a Pixel 5 offers none). Its health is read every run
  instead.
- Chrome: the phone's own, its version recorded by every run; no pinned
  Chromium. Every run cold-restarts it and closes its tabs: the phone is
  dedicated to benching, and nothing else lives in its Chrome.
