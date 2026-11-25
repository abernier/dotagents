#!/usr/bin/env bash
# bench-ab.test.sh: behavioural tests for bin/bench-ab.
#
# The control and the experiment are fake commands that log their side and
# print a fixed number, plus their own run count, so that every sample names
# the run it came from. The lock is the real `bench-lock`, against a throwaway
# state directory, and the comparison the real `bench-compare`. Every case
# launches the real executable as a process and asserts only on what a caller
# can observe: exit codes, stdout, stderr, the run log and the samples files.
set -u

# The suite's own stdin is never a terminal, wherever it is launched from.
exec </dev/null

# A run of this suite under a held lock must still exercise the lock. The load
# reading is imposed, so that `bench-lock`'s calm verdict line, which shows an
# acquisition of the lock, says the same on every machine.
unset BENCH_LOCK_HELD BENCH_LOCK_NOTICE_SECONDS BENCH_LOCK_NOISY_ABOVE
export BENCH_LOCK_CPU_PER_CORE=0.10
export BENCH_LOCK_POLL_SECONDS=0.2

here="$(cd "$(dirname "$0")" && pwd -P)"
tool="$here/bin/bench-ab"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  fails=$((fails + 1))
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# Two PATHs, both without the harness's other tools: one with `bench-lock`
# only, one with `bench-lock` and `bench-compare`. That `bench-lock` is the
# real one, except that each `bench-lock reading` takes its CPU reading from
# the next line of $RUN_DIR/readings when the case wrote one: a reading
# imposed per run.
mkdir -p "$tmp/lock-only" "$tmp/lock-and-compare"
cat >"$tmp/lock-only/bench-lock" <<EOF
#!/bin/sh
if [ "\$1" = reading ] && [ -f "\$RUN_DIR/readings" ]; then
  count=\$((\$(cat "\$RUN_DIR/readings.count" 2>/dev/null || echo 0) + 1))
  echo "\$count" >"\$RUN_DIR/readings.count"
  BENCH_LOCK_CPU_PER_CORE="\$(sed -n "\${count}p" "\$RUN_DIR/readings")"
  export BENCH_LOCK_CPU_PER_CORE
fi
exec "$here/bin/bench-lock" "\$@"
EOF
chmod +x "$tmp/lock-only/bench-lock"
cp "$tmp/lock-only/bench-lock" "$tmp/lock-and-compare/bench-lock"
ln -s "$here/bin/bench-compare" "$tmp/lock-and-compare/bench-compare"
system_path="/usr/bin:/bin:/usr/sbin:/sbin"
# Node, for the real `bench-compare`, wherever this machine keeps it.
node_dir="$(dirname "$(command -v node)")"

# The fake command: `fake <side> <base>` logs its side and whether it ran
# under the lock, then prints <base> plus its own run count on that side.
cat >"$tmp/fake" <<'EOF'
#!/bin/sh
count_file="$RUN_DIR/count.$1"
count=$(($(cat "$count_file" 2>/dev/null || echo 0) + 1))
echo "$count" >"$count_file"
echo "$1 ${BENCH_LOCK_HELD:+locked}" >>"$RUN_DIR/log"
echo $(($2 + count))
EOF
chmod +x "$tmp/fake"

# fresh_run: a new run directory, state directory and samples directory.
runs=0
fresh_run() {
  runs=$((runs + 1))
  export RUN_DIR="$tmp/run.$runs"
  export XDG_STATE_HOME="$tmp/state.$runs"
  mkdir -p "$RUN_DIR"
  out="$RUN_DIR/samples"
}

# ab <path> <args...>: runs bench-ab with that PATH, its stdout in $stdout,
# its stderr in $stderr, its exit code in $code.
ab() {
  local path="$1"
  shift
  PATH="$path" "$tool" "$@" >"$RUN_DIR/stdout" 2>"$RUN_DIR/stderr"
  code=$?
  stdout="$(cat "$RUN_DIR/stdout")"
  stderr="$(cat "$RUN_DIR/stderr")"
}

log() { tr '\n' ' ' <"$RUN_DIR/log"; }

echo "bench-ab:"

# ── An interleaved session ───────────────────────────────────────────────────
fresh_run
ab "$tmp/lock-only:$system_path" -n 3 --warmup 2 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 0 ] &&
  pass "a session without bench-compare exits 0" ||
  fail "the session exited $code: [$stderr]"
[ "$(log)" = "control locked experiment locked experiment locked control locked control locked experiment locked experiment locked control locked control locked experiment locked " ] &&
  pass "warmup then measured iterations alternate AB then BA, all under the lock" ||
  fail "the runs were [$(log)]"
[ "$(tr '\n' ' ' <"$out/control")" = "13 14 15 " ] &&
  [ "$(tr '\n' ' ' <"$out/experiment")" = "23 24 25 " ] &&
  pass "each side's samples file holds its measured runs only, warmup discarded" ||
  fail "samples: control [$(cat "$out/control" 2>&1)], experiment [$(cat "$out/experiment" 2>&1)]"
[ "$(printf '%s\n' "$stderr" | grep -c '^bench-lock: on ')" = 1 ] &&
  pass "the whole session takes the bench lock once" ||
  fail "the session's stderr shows $(printf '%s\n' "$stderr" | grep -c '^bench-lock: on ') lock acquisitions: [$stderr]"
printf '%s\n' "$stderr" | grep -q "bench-compare $out/control $out/experiment" &&
  pass "without bench-compare, it says how to compare the samples on the caller" ||
  fail "without bench-compare, stderr was [$stderr]"
# What a caller with no access to the samples directory, a remote run's,
# extracts from the session's output.
[ "$(printf '%s\n' "$stdout" | sed -n 's/^bench: sample control //p' | tr '\n' ' ')" = "13 14 15 " ] &&
  [ "$(printf '%s\n' "$stdout" | sed -n 's/^bench: sample experiment //p' | tr '\n' ' ')" = "23 24 25 " ] &&
  pass "without bench-compare, stdout carries every sample, one line each, named by its side" ||
  fail "without bench-compare, stdout was [$stdout]"

# Without --out: a fresh temporary directory, named on stderr.
fresh_run
mkdir -p "$RUN_DIR/tmpdir"
TMPDIR="$RUN_DIR/tmpdir" ab "$tmp/lock-only:$system_path" -n 1 --warmup 0 \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
default_out="$(printf '%s\n' "$stderr" | sed -n 's/^bench-ab: samples in \(.*\)\/control and .*/\1/p')"
[ "$code" -eq 0 ] && [ "${default_out#"$RUN_DIR/tmpdir/"}" != "$default_out" ] &&
  [ "$(cat "$default_out/control")" = 11 ] && [ "$(cat "$default_out/experiment")" = 21 ] &&
  pass "without --out, the samples go to a fresh temporary directory named on stderr" ||
  fail "without --out: exit $code, directory [$default_out]: [$stderr]"

# A relative --out is the caller's: resolved before the session re-launches
# itself under the lock.
fresh_run
mkdir -p "$RUN_DIR/caller"
cd "$RUN_DIR/caller" || exit 1
ab "$tmp/lock-only:$system_path" -n 1 --warmup 0 --out relative/samples \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
cd "$here" || exit 1
[ "$code" -eq 0 ] && [ "$(cat "$RUN_DIR/caller/relative/samples/control" 2>/dev/null)" = 11 ] &&
  pass "a relative --out lands under the caller's working directory" ||
  fail "a relative --out: exit $code: [$stderr]"

# ── Handed to bench-compare ──────────────────────────────────────────────────
fresh_run
ab "$tmp/lock-and-compare:$system_path:$node_dir" -n 4 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 1 ] && printf '%s\n' "$stdout" | grep -q '^value: regression' &&
  pass "bench-compare runs on the samples, and its verdict and exit code are the session's" ||
  fail "with bench-compare, the session exited $code: [$stdout] [$stderr]"

fresh_run
ab "$tmp/lock-and-compare:$system_path:$node_dir" -n 4 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20" -- --better higher
[ "$code" -eq 0 ] && printf '%s\n' "$stdout" | grep -q '^value: improvement' &&
  pass "options after -- go to bench-compare" ||
  fail "with --better higher, the session exited $code: [$stdout] [$stderr]"
# The log of a run on a worker, whether it has bench-compare or not, carries
# what the caller needs to compare: the options, one per line, then the samples.
[ "$(printf '%s\n' "$stdout" | grep '^bench: ' | tr '\n' '|')" = "bench: compare option --better|bench: compare option higher|bench: sample control 11|bench: sample control 12|bench: sample control 13|bench: sample control 14|bench: sample experiment 21|bench: sample experiment 22|bench: sample experiment 23|bench: sample experiment 24|" ] &&
  pass "with bench-compare too, stdout carries the compare options, one per line, then every sample" ||
  fail "with bench-compare, stdout was [$stdout]"

fresh_run
ab "$tmp/lock-only:$system_path" -n 1 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20" -- --min-effect "5 %"
[ "$code" -eq 0 ] && printf '%s\n' "$stdout" | grep -qx 'bench: compare option 5 %' &&
  printf '%s\n' "$stderr" | grep -q "compare on the caller: bench-compare --min-effect 5\\\\ % $out/control $out/experiment" &&
  pass "without bench-compare, the hint to compare on the caller carries the options" ||
  fail "without bench-compare, with options: exit $code, [$stdout] [$stderr]"

# Under bench-remote, whose job names its run, the caller compares on its own:
# no hint with paths that only exist on the worker.
fresh_run
BENCH_REMOTE_RUN_ID=20000101-000000-widget-0000000 ab "$tmp/lock-only:$system_path" -n 1 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 0 ] && ! printf '%s\n' "$stderr" | grep -q "compare on the caller: bench-compare" &&
  printf '%s\n' "$stderr" | grep -qx "bench-ab: bench-compare is not on PATH; bench-remote compares these samples on the caller" &&
  pass "under bench-remote, without bench-compare, it says bench-remote compares on the caller" ||
  fail "under bench-remote: exit $code, [$stderr]"

# ── Without bench-lock ───────────────────────────────────────────────────────
fresh_run
ab "$system_path" -n 1 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 0 ] && [ "$(log)" = "control  experiment  " ] &&
  printf '%s\n' "$stderr" | grep -q 'NOT isolated' &&
  pass "without bench-lock, the session runs and says it is not isolated" ||
  fail "without bench-lock, the session exited $code, ran [$(log)]: [$stderr]"
grep -q ': no verdict$' "$out/control.reading" && grep -q ': no verdict$' "$out/experiment.reading" &&
  pass "without bench-lock, every run is tagged with no verdict" ||
  fail "without bench-lock, tags [$(cat "$out/control.reading" "$out/experiment.reading" 2>&1)]"

# ── The samples ──────────────────────────────────────────────────────────────
fresh_run
ab "$tmp/lock-only:$system_path" -n 2 --warmup 0 --out "$out" \
  --control "printf '{\n  \"ms\": 1.5,\n  \"fps\": 60\n}\n'" --experiment "echo 2.5e-1"
[ "$code" -eq 0 ] &&
  [ "$(cat "$out/control")" = '{   "ms": 1.5,   "fps": 60 }
{   "ms": 1.5,   "fps": 60 }' ] &&
  [ "$(tr '\n' ' ' <"$out/experiment")" = "2.5e-1 2.5e-1 " ] &&
  pass "a sample is a number or a JSON object, one line each, a multi-line object joined" ||
  fail "samples: control [$(cat "$out/control" 2>&1)], experiment [$(cat "$out/experiment" 2>&1)]: [$stderr]"

fresh_run
ab "$tmp/lock-only:$system_path" -n 3 --warmup 0 --out "$out" \
  --control "$tmp/fake control 10" --experiment "echo ready; echo 3"
[ "$code" -eq 125 ] && [ "$(log)" = "control locked " ] &&
  printf '%s\n' "$stderr" | grep -q 'not a number or a JSON object' &&
  pass "a run that prints anything but one sample stops the session, exit 125" ||
  fail "a run printing two lines: exit $code, ran [$(log)]: [$stderr]"

fresh_run
ab "$tmp/lock-only:$system_path" -n 3 --warmup 1 --out "$out" \
  --control "$tmp/fake control 10; exit 4" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 125 ] && [ "$(log)" = "control locked " ] &&
  printf '%s\n' "$stderr" | grep -q 'exit code 4' &&
  pass "a run that fails stops the session, exit 125, naming its exit code" ||
  fail "a failing run: exit $code, ran [$(log)]: [$stderr]"

# ── Calm tags ────────────────────────────────────────────────────────────────
# Runs in order: control 1, experiment 1, experiment 2, control 2, ... One
# reading before the first, then one after each: the readings around a run
# are the one before it and the one after it, shared with its neighbours.
fresh_run
printf '%s\n' 0.10 0.90 0.20 0.10 0.70 0.30 0.20 >"$RUN_DIR/readings"
ab "$tmp/lock-only:$system_path" -n 3 --warmup 1 --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 0 ] &&
  [ "$(cat "$out/control.reading")" = "cpu 0.90 per core: noisy (noisy above 0.50)
cpu 0.70 per core: noisy (noisy above 0.50)
cpu 0.70 per core: noisy (noisy above 0.50)" ] &&
  [ "$(cat "$out/experiment.reading")" = "cpu 0.90 per core: noisy (noisy above 0.50)
cpu 0.20 per core: calm (noisy above 0.50)
cpu 0.30 per core: calm (noisy above 0.50)" ] &&
  pass "each measured run's tag is the worse of the readings just before and just after it, on its sample's line in a parallel file" ||
  fail "tags: control [$(cat "$out/control.reading" 2>&1)], experiment [$(cat "$out/experiment.reading" 2>&1)]: [$stderr]"
[ "$(cat "$RUN_DIR/readings.count")" = 7 ] &&
  pass "a session reads the machine once per measured run, plus once" ||
  fail "a session of 6 measured runs read the machine $(cat "$RUN_DIR/readings.count") times"
[ "$(tr '\n' ' ' <"$out/control")" = "12 13 14 " ] && [ "$(tr '\n' ' ' <"$out/experiment")" = "22 23 24 " ] &&
  pass "the samples files stay bare samples, ready for bench-compare" ||
  fail "samples: control [$(cat "$out/control" 2>&1)], experiment [$(cat "$out/experiment" 2>&1)]"

# ── Dropping noisy runs ──────────────────────────────────────────────────────
# Runs in order: C1 E1 E2 C2 C3 E3 E4 C4 C5 E5 E6 C6. A noisy reading between
# experiment 1 and experiment 2 marks both; the last reading, after control 6,
# marks it alone.
fresh_run
printf '%s\n' 0.10 0.10 0.90 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.90 >"$RUN_DIR/readings"
ab "$tmp/lock-and-compare:$system_path:$node_dir" -n 6 --warmup 0 --drop-noisy --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 1 ] && printf '%s\n' "$stdout" | grep -q '^value: regression.*n 5 / 4$' &&
  pass "--drop-noisy compares the calm samples only" ||
  fail "--drop-noisy: exit $code, [$stdout] [$stderr]"
printf '%s\n' "$stderr" | grep -q '^bench-ab: dropped 1 of 6 control and 2 of 6 experiment samples as noisy or unread$' &&
  pass "--drop-noisy says how many samples it dropped on each side" ||
  fail "--drop-noisy said [$stderr]"
[ "$(tr '\n' ' ' <"$out/control")" = "11 12 13 14 15 16 " ] &&
  pass "--drop-noisy leaves the samples files whole" ||
  fail "after --drop-noisy, control was [$(cat "$out/control")]"

# bench-compare needs 4 samples a side when both sides have as many: 3 calm
# ones each are too few, refused by bench-ab itself, naming the drop, with
# bench-compare or without it.
for path in "$tmp/lock-and-compare:$system_path:$node_dir" "$tmp/lock-only:$system_path"; do
  fresh_run
  printf '%s\n' 0.10 0.10 0.10 0.90 0.10 0.10 0.10 0.10 0.10 >"$RUN_DIR/readings"
  ab "$path" -n 4 --warmup 0 --drop-noisy --out "$out" \
    --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
  [ "$code" -eq 125 ] && [ -z "$stdout" ] &&
    printf '%s\n' "$stderr" | grep -q '^bench-ab: after dropping the noisy or unread samples, 3 control and 3 experiment samples are too few for bench-compare' &&
    pass "too few calm samples left to compare is an error, exit 125, naming the drop (PATH ${path%%:*})" ||
    fail "too few calm samples (PATH ${path%%:*}): exit $code, [$stdout] [$stderr]"
done

# bench-compare's own rule, applied by bench-ab without it: 4 calm samples a
# side are enough, 3 against 4 are not. Runs in order: C1 E1 E2 C2 C3 E3 E4
# C4, then C5 E5: the first reading marks control 1 alone, the last the last
# run alone.
fresh_run
printf '%s\n' 0.90 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.10 >"$RUN_DIR/readings"
ab "$tmp/lock-only:$system_path" -n 4 --warmup 0 --drop-noisy --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 125 ] && printf '%s\n' "$stderr" | grep -q '3 control and 4 experiment samples are too few' &&
  pass "3 calm control samples against 4 are too few" ||
  fail "3 against 4: exit $code, [$stderr]"

fresh_run
printf '%s\n' 0.90 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.10 0.90 >"$RUN_DIR/readings"
ab "$tmp/lock-only:$system_path" -n 5 --warmup 0 --drop-noisy --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
[ "$code" -eq 0 ] &&
  [ "$(printf '%s\n' "$stdout" | sed -n 's/^bench: sample control //p' | tr '\n' ' ')" = "12 13 14 15 " ] &&
  [ "$(printf '%s\n' "$stdout" | sed -n 's/^bench: sample experiment //p' | tr '\n' ' ')" = "21 22 23 24 " ] &&
  pass "4 calm samples a side are enough; without bench-compare, stdout carries the calm samples only" ||
  fail "4 against 4: exit $code, [$stdout] [$stderr]"

# bench-ab reads bench-lock's own wording: the real \`bench-lock reading\`,
# calm and noisy above, and here one it cannot make, dropped as unread.
fresh_run
for _ in 1 2 3 4 5 6 7 8 9; do echo none; done >"$RUN_DIR/readings"
BENCH_LOCK_LOAD_PER_CORE=none ab "$tmp/lock-only:$system_path" -n 4 --warmup 0 --drop-noisy --out "$out" \
  --control "$tmp/fake control 10" --experiment "$tmp/fake experiment 20"
printf '%s\n' "$stderr" | grep -q "^bench-ab: dropped 4 of 4 control and 4 of 4 experiment samples" &&
  pass "bench-lock's reading it cannot make: every sample dropped as unread" ||
  fail "an unread reading: [$(cat "$out/control.reading" 2>&1)] [$stderr]"

# ── Usage ────────────────────────────────────────────────────────────────────
# Refused before the lock: nothing runs, nothing queues.
fresh_run
for args in "" "--control true" "--experiment true" "-n --control true --experiment true" \
  "-n 0 --control true --experiment true" "-n x --control true --experiment true" \
  "--warmup -1 --control true --experiment true" "--nope --control true --experiment true"; do
  # shellcheck disable=SC2086  # the point is to split $args into arguments
  ab "$tmp/lock-only:$system_path" $args
  [ "$code" -eq 125 ] && [ "${stderr#*bench-lock: on }" = "$stderr" ] &&
    pass "\`bench-ab $args\` exits 125 before the lock" ||
    fail "\`bench-ab $args\` exited $code: [$stderr]"
done

if [ "$fails" -eq 0 ]; then
  echo "bench-ab: all pass"
else
  echo "bench-ab: $fails failure(s)"
fi
exit "$((fails > 0))"
