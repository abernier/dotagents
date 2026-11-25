#!/usr/bin/env bash
# bench-lock.test.sh: behavioural tests for bin/bench-lock.
#
# Every case launches the real executable as a process, against a throwaway
# state directory, around trivial wrapped commands. It asserts only on what a
# caller can observe: exit codes, the order in which the wrapped commands ran,
# stderr lines, and the output of `bench-lock status`. It never reads the lock
# or the tickets: their layout is the tool's own business.
set -u

# Job control, so that every backgrounded `bench-lock` below is its own process
# group with default signal dispositions, the way a command typed at a terminal
# is. Without it bash starts background commands with SIGINT ignored, and no
# case below could interrupt one.
set -m

# The suite's own stdin is never a terminal, wherever it is launched from: the
# cases about a terminal make one of their own.
exec </dev/null

# A run of this suite under a held lock (a gate wrapped by a bench, say) must
# still exercise the lock, and no ambient tuning may change what it measures.
unset BENCH_LOCK_HELD BENCH_LOCK_NOTICE_SECONDS BENCH_LOCK_CPU_PER_CORE BENCH_LOCK_LOAD_PER_CORE BENCH_LOCK_NOISY_ABOVE BENCH_LOCK_SETTLE BENCH_LOCK_PMSET BENCH_LOCK_NOTIFYUTIL BENCH_LOCK_PROCESSES BENCH_LOCK_OWN_PIDS BENCH_LOCK_SAMPLE_SECONDS

# The CPU reading is imposed for every case but the one that reads the real
# machine: sampling it takes a second, and no case about the lock needs it.
export BENCH_LOCK_CPU_PER_CORE=0.05

# No settle wait, but in the cases about it: the cases about the verdict impose
# noisy readings, and each would sit through the whole wait.
export BENCH_LOCK_SETTLE=0

# Waiters look five times a second instead of once: every hand-over below is
# that much quicker to notice, and the suite that much shorter.
export BENCH_LOCK_POLL_SECONDS=0.2

here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/bin/bench-lock"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  fails=$((fails + 1))
}

# A signal ignored when a shell starts stays ignored in everything it launches,
# and bash starts the background jobs of a script that way. `pnpm test` is not
# concerned: Node gives its children default dispositions.
sigint_heard=""
trap 'sigint_heard=1' INT
kill -INT "$$"
trap - INT
if [ -z "$sigint_heard" ]; then
  echo "bench-lock: SIGINT is ignored in this shell, so no case could interrupt anything."
  echo "bench-lock: run the suite with \`pnpm test\`, or from a foreground shell."
  exit 1
fi

tmp="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local leader
  # Whatever a failed case left running is still a job of this shell, each in
  # its own process group: no pid recorded earlier is signalled blind.
  for leader in $(jobs -p); do kill -TERM -- "-$leader" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

# macOS's thermal and power readings come from pmset, imposed for every case
# through a stand-in that prints what $PMSET_THERM and $PMSET_BATT hold, read
# anew at every call, and fails when the file is missing. By default a machine
# unthrottled and on AC, as pmset prints it: a laptop on battery running the
# suite must not turn every end-of-run line noisy.
cat >"$tmp/pmset" <<'PMSET'
#!/bin/sh
case "$2" in
  therm) cat "$PMSET_THERM" 2>/dev/null ;;
  batt) cat "$PMSET_BATT" 2>/dev/null ;;
  *) exit 1 ;;
esac
PMSET
chmod +x "$tmp/pmset"
export BENCH_LOCK_PMSET="$tmp/pmset"
# therm.cool is what an Apple Silicon Mac at rest prints, as seen on an M1 Max
# and an M2. therm.hot is an Intel Mac throttling, not seen on real hardware.
printf '%s\n' 'Note: No thermal warning level has been recorded' \
  'Note: No performance warning level has been recorded' \
  'Note: No CPU power status has been recorded' >"$tmp/therm.cool"
printf '%s\n' 'Note: No thermal warning level has been recorded' \
  'Note: No performance warning level has been recorded' \
  'CPU Power notify' '	CPU_Scheduler_Limit 	= 100' \
  '	CPU_Available_CPUs 	= 8' '	CPU_Speed_Limit 	= 70' >"$tmp/therm.hot"
# The thermal pressure level comes from notifyutil, imposed the same way
# through a stand-in that prints what $THERMAL_PRESSURE holds: nominal, as on
# both Macs seen, by default.
cat >"$tmp/notifyutil" <<'NOTIFYUTIL'
#!/bin/sh
[ "$1" = -g ] && [ "$2" = com.apple.system.thermalpressurelevel ] || exit 1
cat "$THERMAL_PRESSURE" 2>/dev/null
NOTIFYUTIL
chmod +x "$tmp/notifyutil"
export BENCH_LOCK_NOTIFYUTIL="$tmp/notifyutil"
echo 'com.apple.system.thermalpressurelevel 0' >"$tmp/pressure.nominal"
echo 'com.apple.system.thermalpressurelevel 2' >"$tmp/pressure.heavy"
export THERMAL_PRESSURE="$tmp/pressure.nominal"
printf '%s\n' "Now drawing from 'AC Power'" \
  ' -InternalBattery-0 (id=34603107)	100%; charged; 0:00 remaining present: true' >"$tmp/batt.ac"
printf '%s\n' "Now drawing from 'Battery Power'" \
  ' -InternalBattery-0 (id=34603107)	93%; discharging; 5:12 remaining present: true' >"$tmp/batt.battery"
export PMSET_THERM="$tmp/therm.cool" PMSET_BATT="$tmp/batt.ac"

# Each section gets its own state directory, log and release files, so a
# failure in one cannot leave a holder in the way of the next.
states=0
fresh_state() {
  states=$((states + 1))
  export XDG_STATE_HOME="$tmp/state.$states"
  export JOB_DIR="$tmp/jobs.$states"
  export JOB_LOG="$JOB_DIR/log"
  mkdir -p "$JOB_DIR"
  : >"$JOB_LOG"
}

# A condition worth waiting on, a tenth of a second at a time. A lock is
# asynchronous by construction: asserting without this is asserting a race.
wait_for() {
  local tries="${WAIT_TRIES:-100}"
  while [ "$tries" -gt 0 ]; do
    tries=$((tries - 1))
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# The wrapped command of most cases: it says when it starts, holds until the
# test releases it by name, says when it ends, and exits with the given code.
# Every stand-in below also stops when its directory goes away with the suite:
# one that outlives a failed case must not outlive the run.
cat >"$tmp/job" <<'JOB'
#!/bin/sh
echo "start $1" >>"$JOB_LOG"
while [ -d "$JOB_DIR" ] && [ ! -e "$JOB_DIR/release.$1" ]; do sleep 0.1; done
echo "end $1" >>"$JOB_LOG"
exit "${2:-0}"
JOB
# The same, for a command that survives INT and TERM and says it got them.
cat >"$tmp/stubborn" <<'JOB'
#!/bin/sh
trap 'echo "$1 got INT" >>"$JOB_LOG"' INT
trap 'echo "$1 got TERM" >>"$JOB_LOG"' TERM
echo "start $1" >>"$JOB_LOG"
while [ -d "$JOB_DIR" ] && [ ! -e "$JOB_DIR/release.$1" ]; do sleep 0.1; done
echo "end $1" >>"$JOB_LOG"
exit "${2:-0}"
JOB
# A command with a child of its own, which says when it is told to terminate.
cat >"$tmp/family" <<'JOB'
#!/bin/sh
sh -c 'trap "echo \"child got TERM\" >>\"$JOB_LOG\"; exit 0" TERM
echo "start child" >>"$JOB_LOG"
while [ -d "$JOB_DIR" ]; do sleep 0.1; done' &
wait
JOB
# A `ps` that says the process $REUSED_PID started at another time, the way
# the system sees a pid handed to an unrelated process after its first owner
# died. Every other question goes to the real one.
mkdir -p "$tmp/reused"
cat >"$tmp/reused/ps" <<'PS'
#!/bin/sh
for argument in "$@"; do
  if [ "$argument" = "$REUSED_PID" ]; then
    echo "S    Thu Jan  1 00:00:00 1970"
    exit 0
  fi
done
exec /bin/ps "$@"
PS
chmod +x "$tmp/reused/ps"
chmod +x "$tmp/job" "$tmp/stubborn" "$tmp/family"
release() { : >"$JOB_DIR/release.$1"; }
logged() { grep -qx -- "$1" "$JOB_LOG"; }
count_logged() { grep -cx -- "$1" "$JOB_LOG"; }
log_is() { [ "$(tr '\n' ' ' <"$JOB_LOG")" = "$1" ]; }

# launch <name> <directory> <command...>: a backgrounded `bench-lock run` from
# that directory, its stderr kept in $tmp/err.<name> and its pid in $pid. The
# subshell execs, so $pid is the pid of `bench-lock` itself. With $through set,
# the executable is run by that bash instead of the one on PATH.
pid=""
through=""
launch() {
  local name="$1" directory="$2"
  shift 2
  if [ -n "$through" ]; then
    (cd "$directory" && exec "$through" "$tool" run -- "$@") 2>"$tmp/err.$name" &
  else
    (cd "$directory" && exec "$tool" run -- "$@") 2>"$tmp/err.$name" &
  fi
  pid=$!
}

# The exit code of a backgrounded caller, bounded: a caller that never returns
# fails the case instead of hanging the suite.
code=""
collect() {
  if wait_for gone "$1"; then
    wait "$1" 2>/dev/null
    code=$?
  else
    code="still running"
  fi
}
gone() { ! kill -0 "$1" 2>/dev/null; }

status_has() { "$tool" status 2>&1 | grep -Eq -- "$1"; }
holder_pid() { "$tool" status | sed -n 's/^holder: pid \([0-9]*\),.*/\1/p'; }
status_lacks() { ! status_has "$1"; }

echo "bench-lock:"

# ── Usage ────────────────────────────────────────────────────────────────────
# Refused before anything is queued, and with a code no wrapped command is
# likely to return: a typo must never read as a bench verdict.
fresh_state
for args in "" "nope" "run" "run --" "run sleep 1" "status extra" "reading extra" "settle extra"; do
  # shellcheck disable=SC2086  # the point is to split $args into arguments
  err="$("$tool" $args 2>&1 >/dev/null)"
  code=$?
  if [ "$code" -eq 125 ] && [ "${err#*Usage:}" != "$err" ]; then
    pass "\`bench-lock $args\` exits 125 with usage on stderr"
  else
    fail "\`bench-lock $args\` exited $code: [$err]"
  fi
done

# ── A free lock ──────────────────────────────────────────────────────────────
status_has '^free' &&
  pass "status says plainly that the lock is free" ||
  fail "status on a fresh state directory printed [$("$tool" status 2>&1)]"

# ── The wrapped command runs as if launched directly ─────────────────────────
"$tool" run -- true
code=$?
[ "$code" -eq 0 ] &&
  pass "a zero exit code is returned unchanged" ||
  fail "\`true\` came back as $code"

"$tool" run -- sh -c 'exit 3'
code=$?
[ "$code" -eq 3 ] &&
  pass "a non-zero exit code is returned unchanged" ||
  fail "\`exit 3\` came back as $code"

# In a subshell, which reports the death on a stderr nobody reads.
("$tool" run -- sh -c 'kill -KILL $$'; exit "$?") 2>/dev/null
code=$?
[ "$code" -eq 137 ] &&
  pass "a death by signal is returned as the shell reports it (137 for KILL)" ||
  fail "a command killed by KILL came back as $code"

"$tool" run -- "$tmp/no-such-command" 2>"$tmp/err.missing"
code=$?
[ "$code" -eq 127 ] && grep -q "no-such-command: No such file or directory" "$tmp/err.missing" &&
  pass "a command that does not exist exits 127 and says so, as it would unwrapped" ||
  fail "a missing command came back as $code: [$(cat "$tmp/err.missing")]"

"$tool" run -- no-such-command-on-path 2>"$tmp/err.missing"
code=$?
[ "$code" -eq 127 ] && grep -q "no-such-command-on-path: command not found" "$tmp/err.missing" &&
  pass "a command not found on PATH exits 127 and says so" ||
  fail "a command missing from PATH came back as $code: [$(cat "$tmp/err.missing")]"

: >"$tmp/not-executable"
"$tool" run -- "$tmp/not-executable" 2>"$tmp/err.missing"
code=$?
[ "$code" -eq 126 ] && grep -q "not-executable: Permission denied" "$tmp/err.missing" &&
  pass "a command that cannot be executed exits 126 and says so" ||
  fail "a command without the exec bit came back as $code: [$(cat "$tmp/err.missing")]"

"$tool" run -- true 2>"$tmp/err.after"
code=$?
[ "$code" -eq 0 ] && ! grep -q waiting "$tmp/err.after" &&
  pass "a command that could not be run leaves the machine free for the next caller" ||
  fail "after the failed runs, \`true\` exited $code and said [$(cat "$tmp/err.after")]"

out="$(cd "$tmp" && "$tool" run -- pwd)"
[ "$out" = "$tmp" ] &&
  pass "the wrapped command runs in the caller's working directory" ||
  fail "pwd printed [$out], expected [$tmp]"

out="$(CALLER_SAYS="hello there" "$tool" run -- sh -c 'echo "$CALLER_SAYS"')"
[ "$out" = "hello there" ] &&
  pass "the wrapped command sees the caller's environment" ||
  fail "the caller's variable arrived as [$out]"

out="$(printf 'from stdin\n' | "$tool" run -- cat)"
[ "$out" = "from stdin" ] &&
  pass "the wrapped command reads the caller's stdin" ||
  fail "cat printed [$out]"

out="$("$tool" run -- sh -c 'echo out; echo err >&2' 2>"$tmp/err.streams")"
if [ "$out" = "out" ] && grep -qx err "$tmp/err.streams"; then
  pass "stdout and stderr of the wrapped command reach the caller's"
else
  fail "streams arrived as [$out] and [$(cat "$tmp/err.streams")]"
fi

out="$("$tool" run -- sh -c 'echo "${BENCH_LOCK_HELD:-unset}"')"
[ "$out" != "unset" ] && [ -n "$out" ] &&
  pass "the wrapped command sees BENCH_LOCK_HELD" ||
  fail "BENCH_LOCK_HELD arrived as [$out]"

status_has '^free' &&
  pass "the lock is free again after every one of those runs" ||
  fail "status after the runs printed [$("$tool" status 2>&1)]"

# ── A held lock means the caller waits ───────────────────────────────────────
# Contention must never read as a red result: the second caller neither fails
# nor runs, it waits, says why, and runs when the first is done.
fresh_state
mkdir -p "$tmp/dir a" "$tmp/dir-b"
launch a "$tmp/dir a" "$tmp/job" a 4
pid_a=$pid
wait_for logged "start a" || fail "the first caller never started its command"

status_has "^holder: pid $pid_a, held for [0-9]+s, in $tmp/dir a: $tmp/job a 4\$" &&
  pass "status names the holder: pid, age, working directory and command" ||
  fail "status with a holder printed [$("$tool" status 2>&1)]"

launch b "$tmp/dir-b" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b, waiting for [0-9]+s, in $tmp/dir-b: $tmp/job b\$" &&
  pass "status lists the waiter: pid, age, working directory and command" ||
  fail "status with a waiter printed [$("$tool" status 2>&1)]"

wait_for grep -Eq "held for [0-9]+s by pid $pid_a " "$tmp/err.b" &&
  pass "the waiter says on stderr who holds the lock and for how long" ||
  fail "the waiter's stderr was [$(cat "$tmp/err.b")]"

# Longer than one poll of the lock, so "has not started" is not a race it won.
sleep 0.6
if ! logged "start b" && kill -0 "$pid_b" 2>/dev/null; then
  pass "the second caller waits: it neither runs nor fails"
else
  fail "the second caller did not wait: log [$(tr '\n' ' ' <"$JOB_LOG")]"
fi

release a
collect "$pid_a"
[ "$code" = 4 ] &&
  pass "the holder returns its command's exit code" ||
  fail "the holder exited [$code], expected 4"

wait_for logged "start b" &&
  pass "the waiter starts once the holder is done" ||
  fail "the waiter never started: [$(cat "$tmp/err.b")]"
status_has "^holder: pid $pid_b," && status_lacks '^waiter' &&
  pass "the waiter is now the holder, and nobody waits" ||
  fail "status after the hand-over printed [$("$tool" status 2>&1)]"

release b
collect "$pid_b"
[ "$code" = 0 ] &&
  pass "the waiter returns its command's exit code" ||
  fail "the waiter exited [$code], expected 0"
log_is "start a end a start b end b " &&
  pass "the two commands never ran at the same time" ||
  fail "the commands interleaved: [$(tr '\n' ' ' <"$JOB_LOG")]"
status_has '^free' &&
  pass "the lock is free once both are done" ||
  fail "status at the end printed [$("$tool" status 2>&1)]"

# ── Arrival order ────────────────────────────────────────────────────────────
# Three waiters behind one holder. Each is seen in `status` before the next is
# launched, so the arrival order is not left to the scheduler. All three are
# released up front: each command ends the moment it starts, and the order in
# the log is the order the lock let them through.
fresh_state
launch a "$tmp" "$tmp/job" a
wait_for logged "start a" || fail "the holder never started its command"
queued=""
expected=""
position=0
for name in b c d; do
  launch "$name" "$tmp" "$tmp/job" "$name"
  position=$((position + 1))
  queued="$queued$pid "
  expected="$expected$position:$pid "
  wait_for status_has "^waiter [0-9]+: pid $pid," ||
    fail "caller $name never showed up in status"
done
listed="$("$tool" status | sed -n 's/^waiter \([0-9]*\): pid \([0-9]*\),.*/\1:\2/p' | tr '\n' ' ')"
[ "$listed" = "$expected" ] &&
  pass "status lists three waiters in arrival order" ||
  fail "status listed [$listed], expected [$expected]"

release b
release c
release d
release a
for p in $queued; do collect "$p"; done
log_is "start a end a start b end b start c end c start d end d " &&
  pass "three waiters are served in arrival order, one at a time" ||
  fail "the waiters ran as [$(tr '\n' ' ' <"$JOB_LOG")]"

# ── An interrupted waiter leaves the queue ───────────────────────────────────
# Ctrl-C at a terminal goes to the caller's whole process group, so that is how
# the interrupt is sent here; the termination is aimed at the one process, the
# way `kill <pid>` does it.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
launch c "$tmp" "$tmp/job" c
pid_c=$pid
wait_for status_has "^waiter 2: pid $pid_c," || fail "caller c never queued"
launch d "$tmp" "$tmp/job" d
pid_d=$pid
wait_for status_has "^waiter 3: pid $pid_d," || fail "caller d never queued"

kill -INT -- "-$pid_b"
collect "$pid_b"
[ "$code" = 130 ] &&
  pass "an interrupted waiter exits 130" ||
  fail "the interrupted waiter exited [$code]"
kill -TERM "$pid_c"
collect "$pid_c"
[ "$code" = 143 ] &&
  pass "a terminated waiter exits 143" ||
  fail "the terminated waiter exited [$code]"
status_lacks "pid ($pid_b|$pid_c)," && status_has "^waiter 1: pid $pid_d," &&
  pass "status no longer lists them, and the caller behind moved up" ||
  fail "status after two waiters left printed [$("$tool" status 2>&1)]"

release d
release a
collect "$pid_a"
collect "$pid_d"
log_is "start a end a start d end d " &&
  pass "the callers behind are not delayed, and the abandoned commands never ran" ||
  fail "after two waiters left, the log is [$(tr '\n' ' ' <"$JOB_LOG")]"
status_has '^free' &&
  pass "an abandoned wait leaves nothing behind" ||
  fail "status at the end printed [$("$tool" status 2>&1)]"

# ── A signal stops the holder's command and frees the lock ───────────────────
# Whether it comes to the caller's process group, as a terminal sends Ctrl-C,
# or to the pid that was launched alone, as `kill <pid>` and a wrapper
# forwarding a signal do: it reaches the wrapped command, and the lock is free
# once the command is gone, not before.
#
# a_signal_stops_the_holder <signal> <group|alone> <expected exit code>
a_signal_stops_the_holder() {
  local signal="$1" target="$2" expected="$3"
  fresh_state
  launch a "$tmp" sh -c 'echo "start a" >>"$JOB_LOG"; exec sleep 30'
  pid_a=$pid
  wait_for logged "start a" || fail "the holder never started its command"
  launch b "$tmp" "$tmp/job" b
  pid_b=$pid
  wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
  release b

  if [ "$target" = group ]; then
    kill "-$signal" -- "-$pid_a"
  else
    kill "-$signal" "$pid_a"
  fi
  collect "$pid_a"
  [ "$code" = "$expected" ] &&
    pass "$signal sent to the holder ($target) stops its command, whose death is returned ($expected)" ||
    fail "after $signal ($target) the holder exited [$code], expected $expected"
  wait_for logged "end b" &&
    pass "after $signal the lock is released and the next waiter runs" ||
    fail "after $signal the waiter never ran: [$("$tool" status 2>&1)]"
  collect "$pid_b"
}
a_signal_stops_the_holder INT group 130
a_signal_stops_the_holder INT alone 130
a_signal_stops_the_holder TERM alone 143

# A signal sent to the caller's process group reaches the command's own
# children too, the way a terminal's Ctrl-C reaches every process of the job.
fresh_state
launch a "$tmp" "$tmp/family"
pid_a=$pid
wait_for logged "start child" || fail "the command's child never started"
kill -TERM -- "-$pid_a"
collect "$pid_a"
[ "$code" = 143 ] && wait_for logged "child got TERM" &&
  pass "a signal sent to the caller's process group reaches the command's own children" ||
  fail "the holder exited [$code] and the log is [$(tr '\n' ' ' <"$JOB_LOG")]"

# ── The wrapped command's own exit decides ───────────────────────────────────
# A command that handles the signal and carries on keeps the lock: the bench is
# still running, and `bench-lock` waits for it.
a_stubborn_command_decides() {
  fresh_state
  launch a "$tmp" "$tmp/stubborn" a 6
  pid_a=$pid
  wait_for logged "start a" || fail "the stubborn holder never started"
  launch b "$tmp" "$tmp/job" b
  pid_b=$pid
  wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"

  kill -INT "$pid_a"
  wait_for logged "a got INT" || fail "the interrupt never reached the wrapped command"
  kill -TERM "$pid_a"
  wait_for logged "a got TERM" || fail "the termination never reached the wrapped command"
  # Longer than one poll of the lock, so "has not started" is not a race b won.
  sleep 0.6
  if status_has "^holder: pid $pid_a," && ! logged "start b"; then
    pass "a command that survives a signal keeps the lock, and bench-lock waits for it"
  else
    fail "the lock moved under a running command: [$("$tool" status 2>&1)]"
  fi

  release a
  collect "$pid_a"
  [ "$code" = 6 ] &&
    pass "the exit code is the command's, whatever signals came by" ||
    fail "the stubborn holder exited [$code], expected 6"
  release b
  collect "$pid_b"
  log_is "start a a got INT a got TERM end a start b end b " &&
    pass "the waiter runs once the command is really done" ||
    fail "the log is [$(tr '\n' ' ' <"$JOB_LOG")]"
}
a_stubborn_command_decides

# ── An old bash ──────────────────────────────────────────────────────────────
# `bench-lock` must work under the old bash macOS ships as /bin/bash. The bash
# on PATH is usually a recent one, so the case where signals reach a running
# command runs once more through the system's old one, where there is one.
bash_major() { "$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null; }
if [ "$(bash_major bash)" -ge 5 ]; then
  if [ "$(bash_major /bin/bash)" -lt 5 ] 2>/dev/null; then
    echo "  .... through /bin/bash $(bash_major /bin/bash):"
    through=/bin/bash
    a_stubborn_command_decides
    through=""
  else
    echo "  skip the cases through an old bash: /bin/bash is not one"
  fi
fi

# ── The pid that status prints is the command ────────────────────────────────
# Callers forward signals to the pid they launched, and read its exit code:
# that pid is the wrapped command itself, not a go-between.
fresh_state
launch a "$tmp" "$tmp/stubborn" a 6
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
running="$(ps -o command= -p "$pid_a")"
[ "$(holder_pid)" = "$pid_a" ] && [ "${running#*"$tmp/stubborn a 6"}" != "$running" ] &&
  [ "${running#*bench-lock}" = "$running" ] &&
  pass "the pid that status prints is the launched pid, and it runs the command, not bench-lock" ||
  fail "status names [$(holder_pid)], launched $pid_a running [$running]"
"$tool" run -- "$tmp/no-such-command" 2>/dev/null
code=$?
[ "$code" = 127 ] &&
  pass "a command that cannot be run is refused at once, without waiting for the lock" ||
  fail "a missing command behind a holder came back as [$code]"
kill -TERM "$(holder_pid)"
wait_for logged "a got TERM" &&
  pass "a signal sent to that pid reaches the command" ||
  fail "a signal sent to the holder went nowhere: [$(tr '\n' ' ' <"$JOB_LOG")]"
release a
collect "$pid_a"
[ "$code" = 6 ] &&
  pass "and the command's exit code comes back from that pid" ||
  fail "the holder exited [$code], expected 6"

# ── A holder that died ───────────────────────────────────────────────────────
# A kill -9 gives nobody a chance to clean up: the next in line must notice on
# its own and take the lock. The callers behind still go one by one.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
launch c "$tmp" "$tmp/job" c
pid_c=$pid
wait_for status_has "^waiter 2: pid $pid_c," || fail "caller c never queued"
release c
kill -KILL "$pid_a"
collect "$pid_a"
[ "$code" = 137 ] || fail "the killed holder exited [$code], expected 137"
wait_for logged "start b" &&
  pass "a holder killed with -9 lets the next waiter through" ||
  fail "after the holder was killed the waiter never ran: [$("$tool" status 2>&1)]"
# A take-over is an ordinary release: the waiter says nothing beyond its wait
# and the verdict every holder prints before its command.
! grep -v -e '^bench-lock: waiting for the bench lock' -e '^bench-lock: on ' "$tmp/err.b" >/dev/null &&
  pass "the waiter takes over without a word about the holder it replaces" ||
  fail "the waiter that took over said [$(cat "$tmp/err.b")]"
# Longer than one poll of the lock, so "has not started" is not a race c won.
sleep 0.6
status_has "^holder: pid $pid_b," && ! logged "start c" &&
  pass "the caller behind waits for the new holder, not for the dead one" ||
  fail "after the take-over status printed [$("$tool" status 2>&1)], log [$(tr '\n' ' ' <"$JOB_LOG")]"
release b
collect "$pid_b"
collect "$pid_c"
log_is "start a start b end b start c end c " &&
  pass "after a dead holder the waiters still run one at a time, in order" ||
  fail "after the dead holder the log is [$(tr '\n' ' ' <"$JOB_LOG")]"
status_has '^free' &&
  pass "status says free once the last holder has ended" ||
  fail "status at the end printed [$("$tool" status 2>&1)]"

# ── A waiter that died ───────────────────────────────────────────────────────
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
launch c "$tmp" "$tmp/job" c
pid_c=$pid
wait_for status_has "^waiter 2: pid $pid_c," || fail "caller c never queued"
kill -KILL "$pid_b"
collect "$pid_b"
status_lacks "pid $pid_b," && status_has "^waiter 1: pid $pid_c," &&
  pass "status no longer lists a waiter that died, and the one behind moves up" ||
  fail "after a waiter died status printed [$("$tool" status 2>&1)]"
release c
release a
collect "$pid_a"
collect "$pid_c"
log_is "start a end a start c end c " &&
  pass "a waiter that died is skipped: the one behind is served" ||
  fail "after a dead waiter the log is [$(tr '\n' ' ' <"$JOB_LOG")]"

# ── Two callers find the same dead holder ────────────────────────────────────
# Launched together against a lock whose holder was killed: one takes it over,
# the other waits for that one, never for nobody and never alongside it.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
kill -KILL "$pid_a"
collect "$pid_a"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
launch c "$tmp" "$tmp/job" c
pid_c=$pid
wait_for grep -q "^start [bc]$" "$JOB_LOG" || fail "neither caller took over the dead holder's lock"
sleep 0.6
[ "$(grep -c "^start [bc]$" "$JOB_LOG")" = 1 ] &&
  pass "two callers that find the same dead holder do not run together" ||
  fail "after a dead holder both callers ran: [$(tr '\n' ' ' <"$JOB_LOG")]"
release b
release c
collect "$pid_b"
collect "$pid_c"
{ log_is "start a start b end b start c end c " || log_is "start a start c end c start b end b "; } &&
  pass "and the second runs once the first is done" ||
  fail "after a dead holder the log is [$(tr '\n' ' ' <"$JOB_LOG")]"

# ── Callers in another time zone or language ─────────────────────────────────
# A process's start time is printed in the reader's time zone and language. A
# waiter that reads it differently from the holder must still see it alive.
fresh_state
TZ=Pacific/Kiritimati LC_ALL=C launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
TZ=America/Adak LC_ALL=fr_FR.UTF-8 launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
sleep 0.6
TZ=Asia/Kathmandu "$tool" status 2>&1 | grep -q "^holder: pid $pid_a," && ! logged "start b" &&
  pass "a holder is judged alive whatever the time zone and language of the reader" ||
  fail "a reader in another time zone saw [$(TZ=Asia/Kathmandu "$tool" status 2>&1)], log [$(tr '\n' ' ' <"$JOB_LOG")]"
release b
release a
collect "$pid_a"
collect "$pid_b"

# ── A pid that now belongs to another process ────────────────────────────────
# A recorded pid that is alive but started at another time than recorded was
# handed to an unrelated process: its first owner is dead. A `ps` that lies
# about one pid stands in for the system, which cannot be made to reuse one.
as_if_reused() { PATH="$tmp/reused:$PATH" REUSED_PID="$1" "${@:2}"; }
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
as_if_reused "$pid_a" "$tool" status 2>&1 | grep -q '^free' &&
  pass "status says free when the holder's pid started at another time" ||
  fail "with the holder's pid reused status printed [$(as_if_reused "$pid_a" "$tool" status 2>&1)]"
as_if_reused "$pid_a" launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for logged "start b" &&
  pass "a caller takes the lock of a holder whose pid started at another time" ||
  fail "with the holder's pid reused the caller never ran: [$(cat "$tmp/err.b")]"
release a
release b
collect "$pid_a"
collect "$pid_b"

fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
as_if_reused "$pid_b" "$tool" status 2>&1 | grep -q "pid $pid_b," &&
  fail "with the waiter's pid reused status still lists it" ||
  pass "status does not list a waiter whose pid started at another time"
as_if_reused "$pid_b" launch c "$tmp" "$tmp/job" c
pid_c=$pid
wait_for status_has "^waiter 1: pid $pid_c," || fail "caller c never moved ahead of the reused waiter"
release c
release b
release a
collect "$pid_a"
collect "$pid_b"
collect "$pid_c"
log_is "start a end a start c end c start b end b " &&
  pass "a waiter whose pid started at another time is skipped" ||
  fail "with the waiter's pid reused the log is [$(tr '\n' ' ' <"$JOB_LOG")]"

# ── Under a held lock, a nested run passes straight through ──────────────────
# A wrapped script that calls another wrapped script must not wait for itself.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"

BENCH_LOCK_HELD=1 launch nested "$tmp" sh -c 'echo "start nested" >>"$JOB_LOG"; exit 9'
collect "$pid"
if [ "$code" = 9 ] && logged "start nested" && [ ! -s "$tmp/err.nested" ]; then
  pass "a run that sees BENCH_LOCK_HELD runs its command at once, without a word, and returns its code"
else
  fail "the nested run exited [$code] and said [$(cat "$tmp/err.nested")]"
fi
release a
collect "$pid_a"

launch outer "$tmp" "$tool" run -- sh -c 'echo "start inner" >>"$JOB_LOG"; exit 8'
collect "$pid"
[ "$code" = 8 ] && logged "start inner" &&
  pass "bench-lock run under bench-lock run does not wait for itself" ||
  fail "the nested pair exited [$code]: [$(cat "$tmp/err.outer")]"

# ── The calm verdict ─────────────────────────────────────────────────────────
# Just before the command starts, one stderr line names the machine and says
# whether it was calm or noisy. The readings are imposed through
# BENCH_LOCK_CPU_PER_CORE and BENCH_LOCK_LOAD_PER_CORE, so the verdict does not
# depend on this machine; a value that is not a number stands for a reading
# that failed.
start_verdicts() { grep '^bench-lock: on ' "$1" | grep -v '^bench-lock: on [^,]*, during the run, '; }
verdicts() { start_verdicts "$1" | grep -c .; }
fresh_state
BENCH_LOCK_CPU_PER_CORE=0.05 "$tool" run -- sh -c 'echo "command starts" >&2' 2>"$tmp/err.calm"
code=$?
[ "$code" = 0 ] && [ "$(head -n 1 "$tmp/err.calm")" = "$(start_verdicts "$tmp/err.calm")" ] &&
  grep -q '^bench-lock: on [^,]*, cpu 0.05 per core: calm (noisy above 0.50)$' "$tmp/err.calm" &&
  [ "$(sed -n 2p "$tmp/err.calm")" = "command starts" ] &&
  pass "a CPU busy below the threshold reads calm, on one line before the command starts" ||
  fail "a calm run exited [$code] and said [$(cat "$tmp/err.calm")]"

BENCH_LOCK_CPU_PER_CORE=0.05 BENCH_LOCK_LOAD_PER_CORE=3.2 "$tool" run -- true 2>"$tmp/err.both"
grep -q ', cpu 0.05 per core: calm' "$tmp/err.both" &&
  pass "the CPU reading wins over the load average when both are read" ||
  fail "with both readings the run said [$(cat "$tmp/err.both")]"

BENCH_LOCK_CPU_PER_CORE=0.3 BENCH_LOCK_NOISY_ABOVE=0.2 "$tool" run -- true 2>"$tmp/err.lower"
BENCH_LOCK_CPU_PER_CORE=0.3 BENCH_LOCK_NOISY_ABOVE=0.4 "$tool" run -- true 2>"$tmp/err.higher"
grep -q ': noisy' "$tmp/err.lower" && grep -q ': calm' "$tmp/err.higher" &&
  pass "BENCH_LOCK_NOISY_ABOVE moves the threshold, and the verdict with it" ||
  fail "with the threshold moved the runs said [$(cat "$tmp/err.lower")] and [$(cat "$tmp/err.higher")]"

# Without the settle wait, a noisy machine neither changes the code nor holds
# the command back. The wait announces itself before its first pause, so no
# such line means no wait: asserted on what the run says, never on wall time,
# which a loaded machine stretches at will.
BENCH_LOCK_CPU_PER_CORE=0.99 "$tool" run -- sh -c 'exit 5' 2>"$tmp/err.unsettled"
code=$?
[ "$code" = 5 ] &&
  ! grep -q '^bench-lock: waiting for the machine to settle' "$tmp/err.unsettled" &&
  grep -q '^bench-lock: on [^,]*, cpu 0.99 per core: noisy (noisy above 0.50)$' "$tmp/err.unsettled" &&
  pass "with BENCH_LOCK_SETTLE=0, a noisy verdict leaves the exit code unchanged and does not delay the start" ||
  fail "a noisy run without the settle wait exited [$code] and said [$(cat "$tmp/err.unsettled")]"

# CPU sampling that fails falls back to the lagging load average, and says so.
fallback_ok=1
for reading in "none" "-1" "1.2.3"; do
  BENCH_LOCK_CPU_PER_CORE="$reading" BENCH_LOCK_LOAD_PER_CORE=3.2 "$tool" run -- sh -c 'exit 6' 2>"$tmp/err.fallback"
  code=$?
  if [ "$code" != 6 ] || ! grep -q '^bench-lock: on [^,]*, load 3.20 per core: noisy (noisy above 0.50)$' "$tmp/err.fallback"; then
    fallback_ok=""
    break
  fi
done
[ -n "$fallback_ok" ] &&
  pass "a CPU reading that fails falls back to the load average, named as such" ||
  fail "an unreadable CPU [$reading] exited [$code] and said [$(cat "$tmp/err.fallback")]"

# Neither reading: no verdict, and the run goes on.
unread_ok=1
for reading in "high" "-1" "1.2.3"; do
  BENCH_LOCK_CPU_PER_CORE="$reading" BENCH_LOCK_LOAD_PER_CORE="$reading" "$tool" run -- sh -c 'exit 7' 2>"$tmp/err.unread"
  code=$?
  if [ "$code" != 7 ] || ! grep -q '^bench-lock: on [^,]*, load unknown: no verdict$' "$tmp/err.unread"; then
    unread_ok=""
    break
  fi
done
[ -n "$unread_ok" ] &&
  pass "neither reading: the line says so, and the run goes on with its own code" ||
  fail "unreadable readings [$reading] exited [$code] and said [$(cat "$tmp/err.unread")]"

# `reading` prints the same reading and verdict on stdout, for a tool that
# tags each of its own runs, and takes neither the lock nor a place in line.
fresh_state
BENCH_LOCK_CPU_PER_CORE=0.80 "$tool" run -- sh -c '"$1" reading >"$2"' _ "$tool" "$tmp/out.held" 2>/dev/null
BENCH_LOCK_CPU_PER_CORE=0.05 "$tool" reading >"$tmp/out.calm" 2>"$tmp/err.reading"
code=$?
BENCH_LOCK_CPU_PER_CORE=none BENCH_LOCK_LOAD_PER_CORE=none "$tool" reading >"$tmp/out.unread"
[ "$code" = 0 ] && [ ! -s "$tmp/err.reading" ] &&
  [ "$(cat "$tmp/out.calm")" = "cpu 0.05 per core: calm (noisy above 0.50)" ] &&
  [ "$(cat "$tmp/out.held")" = "cpu 0.80 per core: noisy (noisy above 0.50)" ] &&
  [ "$(cat "$tmp/out.unread")" = "load unknown: no verdict" ] &&
  pass "\`bench-lock reading\` prints the reading and its verdict, under the lock or not" ||
  fail "\`bench-lock reading\` exited [$code]: [$(cat "$tmp/out.calm")] [$(cat "$tmp/out.held")] [$(cat "$tmp/out.unread")] [$(cat "$tmp/err.reading")]"

# A reading file that cannot be read is a reading that failed, said by the
# verdict alone: no shell error leaks onto stderr.
BENCH_LOCK_CPU_PER_CORE="$tmp/no-such-reading" BENCH_LOCK_LOAD_PER_CORE=none "$tool" reading \
  >"$tmp/out.missing" 2>"$tmp/err.missing"
[ "$(cat "$tmp/out.missing")" = "load unknown: no verdict" ] && [ ! -s "$tmp/err.missing" ] &&
  pass "a reading file that cannot be read gives no verdict, and nothing on stderr" ||
  fail "a missing reading file printed [$(cat "$tmp/out.missing")] and said [$(cat "$tmp/err.missing")]"

# Without an imposed value, the machine's real CPU is sampled, over about a
# second: some CPU verdict is given, whatever the machine, Linux or macOS. A
# noisy one included, and no settle wait for it: asserted on what the run says,
# not on wall time, which a loaded machine stretches at will.
env -u BENCH_LOCK_CPU_PER_CORE "$tool" run -- true 2>"$tmp/err.real"
grep -Eq '^bench-lock: on [^ ,]+, cpu [0-9]+\.[0-9]{2} per core: (calm|noisy) \(noisy above 0\.50\)$' "$tmp/err.real" &&
  ! grep -q '^bench-lock: waiting for the machine to settle' "$tmp/err.real" &&
  pass "without an imposed reading, the machine's own CPU is sampled" ||
  fail "a run on the real CPU said [$(cat "$tmp/err.real")]"

# The machine is named by its short name, never with a local-network suffix;
# on a Mac, the name the system gives it on the local network.
machine="$(sed -n 's/^bench-lock: on \([^,]*\),.*/\1/p' "$tmp/err.real")"
case "$machine" in
  "" | *.local | *.lan) short_name="" ;;
  *) short_name=1 ;;
esac
if [ -x /usr/sbin/scutil ]; then
  [ "$machine" = "$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)" ] || short_name=""
fi
[ -n "$short_name" ] &&
  pass "the line names the machine by its short local name ($machine)" ||
  fail "the line named the machine [$machine]"

# Once the lock is obtained, not while waiting; and a nested run says nothing.
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
BENCH_LOCK_CPU_PER_CORE=0.05 launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
sleep 0.6
[ "$(verdicts "$tmp/err.b")" = 0 ] &&
  pass "a waiter gives no verdict while it waits" ||
  fail "the waiter said [$(cat "$tmp/err.b")]"
release b
release a
collect "$pid_a"
collect "$pid_b"
[ "$(verdicts "$tmp/err.b")" = 1 ] &&
  pass "the waiter gives its verdict once it has the lock" ||
  fail "the waiter that got the lock said [$(cat "$tmp/err.b")]"

BENCH_LOCK_CPU_PER_CORE=0.05 launch outer "$tmp" "$tool" run -- true
collect "$pid"
[ "$code" = 0 ] && [ "$(verdicts "$tmp/err.outer")" = 1 ] &&
  pass "a run nested under a held lock gives no second verdict" ||
  fail "the nested pair exited [$code] and said [$(cat "$tmp/err.outer")]"

# ── The end-of-run verdict ───────────────────────────────────────────────────
# Once the command is over, one more stderr line gives the reading over the
# whole run, max and mean per core, calm or noisy. It comes after everything
# the command printed, and nothing of bench-lock is left once it is said: a
# caller reading stderr through a pipe sees the pipe close.
end_line() { grep '^bench-lock: on [^,]*, during the run, ' "$1"; }

# through_a_pipe <name> <command...>: `bench-lock run` with stdout and stderr
# through one pipe into $tmp/out.<name>, its exit code in $code. The pipe ends
# once every writer is gone, bench-lock's own included.
through_a_pipe() {
  local name="$1"
  shift
  "$tool" run -- "$@" 2>&1 | cat >"$tmp/out.$name"
  code=${PIPESTATUS[0]}
}

fresh_state
through_a_pipe calm sh -c 'echo "command output"; echo "command error" >&2; exit 5'
[ "$code" = 5 ] && [ "$(end_line "$tmp/out.calm" | grep -c .)" = 1 ] &&
  [ "$(tail -n 1 "$tmp/out.calm")" = "$(end_line "$tmp/out.calm")" ] &&
  grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.05, max 0.05, mean 0.05 per core: calm (noisy above 0.50)$' "$tmp/out.calm" &&
  pass "a run ends with one line, max and mean per core, after the command's output, and its exit code unchanged" ||
  fail "a run exited [$code] and printed [$(cat "$tmp/out.calm")]"

BENCH_LOCK_CPU_PER_CORE=none BENCH_LOCK_LOAD_PER_CORE=3.2 through_a_pipe fallback true
BENCH_LOCK_CPU_PER_CORE=none BENCH_LOCK_LOAD_PER_CORE=none through_a_pipe unread true
grep -q '^bench-lock: on [^,]*, during the run, load besides the bench p90 3.20, max 3.20, mean 3.20 per core: noisy (noisy above 0.50)$' "$tmp/out.fallback" &&
  grep -q '^bench-lock: on [^,]*, during the run, load unknown: no verdict$' "$tmp/out.unread" &&
  pass "during the run too, the load average stands in for the CPU, and neither reading gives no verdict" ||
  fail "the fallback printed [$(cat "$tmp/out.fallback")] and the unreadable run [$(cat "$tmp/out.unread")]"

# On macOS the run is also read for the CPU speed limit, the thermal pressure
# and the power source: each flags it noisy, whatever the CPU reads, and the
# line says why. The worst reading of the run counts, even once it is over:
# the command puts the default back half a second in.
# a_reading_flags_noisy <name> <variable> <worse file> <default file> <what the line says...>
a_reading_flags_noisy() {
  local name="$1" variable="$2" worse="$3" default="$4"
  shift 4
  cp "$tmp/$worse" "$tmp/$name.burst"
  env "$variable=$tmp/$name.burst" "$tool" run -- \
    sh -c 'sleep 0.5; cp "$1" "$2"; sleep 2.5' _ "$tmp/$default" "$tmp/$name.burst" 2>&1 | cat >"$tmp/out.$name"
  grep -q "^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.05, max 0.05, mean 0.05 per core: calm (noisy above 0.50); $*: noisy\$" "$tmp/out.$name" &&
    pass "$* at any sample flags the run noisy, and says so" ||
    fail "a run with $* printed [$(cat "$tmp/out.$name")]"
}
a_reading_flags_noisy throttled PMSET_THERM therm.hot therm.cool CPU speed limit down to 70%
a_reading_flags_noisy pressure THERMAL_PRESSURE pressure.heavy pressure.nominal thermal pressure heavy
a_reading_flags_noisy battery PMSET_BATT batt.battery batt.ac on battery power

PMSET_THERM="$tmp/missing" PMSET_BATT="$tmp/missing" THERMAL_PRESSURE="$tmp/missing" through_a_pipe unreadable sh -c 'exit 3'
[ "$code" = 3 ] &&
  grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.05, max 0.05, mean 0.05 per core: calm (noisy above 0.50); CPU speed limit unknown; thermal pressure unknown; power source unknown$' "$tmp/out.unreadable" &&
  pass "an unreadable thermal or power reading reads unknown, and the exit code stays the command's" ||
  fail "an unreadable pmset exited [$code] and printed [$(cat "$tmp/out.unreadable")]"

# This Mac's own pmset and notifyutil: every thermal reading is understood.
if [ -x /usr/bin/pmset ] && [ "$(uname -s)" = Darwin ]; then
  env -u BENCH_LOCK_PMSET -u BENCH_LOCK_NOTIFYUTIL "$tool" run -- true 2>&1 | cat >"$tmp/out.real.thermal"
  end_line "$tmp/out.real.thermal" | grep -q . && ! grep -q 'unknown' "$tmp/out.real.thermal" &&
    pass "on this Mac, the real pmset and notifyutil give every thermal and power reading" ||
    fail "on this Mac the end-of-run line was [$(cat "$tmp/out.real.thermal")]"
fi

through_a_pipe nested "$tool" run -- true
[ "$code" = 0 ] && [ "$(end_line "$tmp/out.nested" | grep -c .)" = 1 ] &&
  pass "a run nested under a held lock gives no second end-of-run line" ||
  fail "the nested pair exited [$code] and printed [$(cat "$tmp/out.nested")]"

# A command that prepares before it measures (a remote run's fetch and
# install) calls `bench-lock settle` once ready: the end-of-run reading starts
# over from there, and the preparation's load is left out of it.
echo 0.8 >"$tmp/cpu.prepare"
BENCH_LOCK_CPU_PER_CORE="$tmp/cpu.prepare" through_a_pipe window \
  sh -c 'sleep 2.5; echo 0.05 >"$1"; "$2" settle; sleep 0.5' _ "$tmp/cpu.prepare" "$tool"
[ "$code" = 0 ] && [ "$(end_line "$tmp/out.window" | grep -c .)" = 1 ] &&
  grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.05, max 0.05, mean 0.05 per core: calm ' "$tmp/out.window" &&
  pass "a settle called by the holder starts the end-of-run reading over" ||
  fail "a run that settled midway exited [$code] and printed [$(cat "$tmp/out.window")]"

# The same settle, called by anything but the holder itself, leaves it be.
# The inner shell runs two commands, so that it forks the settle instead of
# becoming it.
echo 0.8 >"$tmp/cpu.prepare"
BENCH_LOCK_CPU_PER_CORE="$tmp/cpu.prepare" through_a_pipe stranger \
  sh -c 'sleep 2.5; echo 0.05 >"$1"; sh -c "\"\$0\" settle; true" "$2"; sleep 0.5' _ "$tmp/cpu.prepare" "$tool"
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.80, max 0.80, ' "$tmp/out.stranger" &&
  pass "a settle from deeper down leaves the end-of-run reading whole" ||
  fail "a run settled from a grandchild exited [$code] and printed [$(cat "$tmp/out.stranger")]"

# A caller that cannot read stderr through a pipe (a log file, with a bench
# that leaves a child holding it) learns the line is written from the file
# BENCH_LOCK_END_MARKER names: created once the line is out, never before.
fresh_state
rm -f "$tmp/end-said"
BENCH_LOCK_END_MARKER="$tmp/end-said" "$tool" run -- sh -c '[ ! -e "$1" ] && echo "no marker yet"' _ "$tmp/end-said" \
  >"$tmp/out.marker" 2>"$tmp/err.marker"
code=$?
wait_for test -e "$tmp/end-said"
[ "$code" = 0 ] && grep -qx "no marker yet" "$tmp/out.marker" && [ -e "$tmp/end-said" ] &&
  [ -n "$(end_line "$tmp/err.marker")" ] &&
  pass "BENCH_LOCK_END_MARKER is created once the end-of-run line is written" ||
  fail "with an end marker the run exited [$code], printed [$(cat "$tmp/out.marker")] and said [$(cat "$tmp/err.marker")]"

# The run lasts several sampling periods: the readings keep coming, and the
# line still comes once, when the command is over. A burst at the start, then
# calm: a run this short is judged on its busiest reading, which shows the
# burst and decides, and the mean dilutes it. The reading
# is imposed through a file the command rewrites, as the settle wait's cases do.
# How many samples fall in the burst and after it is the scheduler's call on a
# loaded machine, so the mean is only asked to sit below the burst. The bound
# on the duration is the point of "soon": a sampler that outlived the command
# would hold the pipe for good, so it is set at several times the five seconds
# expected, wide enough for a loaded machine.
echo 0.8 >"$tmp/cpu.burst"
started=$SECONDS
BENCH_LOCK_CPU_PER_CORE="$tmp/cpu.burst" through_a_pipe long \
  sh -c 'sleep 0.5; echo 0.2 >"$1"; sleep 4.5; echo "command done"' burst "$tmp/cpu.burst"
[ "$code" = 0 ] && [ "$(grep -v "^bench-lock: busiest " "$tmp/out.long" | tail -n 1)" = "$(end_line "$tmp/out.long")" ] &&
  [ "$(end_line "$tmp/out.long" | grep -c .)" = 1 ] && [ $((SECONDS - started)) -lt 30 ] &&
  grep -Eq ', during the run, cpu besides the bench p90 0\.80, max 0\.80, mean 0\.[2-6][0-9] per core: noisy ' "$tmp/out.long" &&
  pass "a run over several sampling periods ends with one line, soon after the command, a burst in its max" ||
  fail "a long run exited [$code] after $((SECONDS - started))s and printed [$(cat "$tmp/out.long")]"

# A run of ten readings or more is judged on its 90th percentile: a noisy
# second or two among many calm ones is forgiven, the max still shows it. The
# first reading is taken at once, before the command turns the reading calm.
# On a loaded machine the command can be late enough for a second reading to
# land before it does: how many is the scheduler's call, so the run is long
# enough, twenty readings and more at a one-second period, for the percentile
# to forgive two.
printf '%s\n' "  301     1  80.0   0:42.00 other" >"$tmp/processes.p90"
echo 0.8 >"$tmp/cpu.spike"
BENCH_LOCK_SAMPLE_SECONDS=1 BENCH_LOCK_PROCESSES="$tmp/processes.p90" BENCH_LOCK_CPU_PER_CORE="$tmp/cpu.spike" through_a_pipe spike \
  sh -c 'sleep 0.5; echo 0.05 >"$1"; sleep 25' _ "$tmp/cpu.spike"
[ "$code" = 0 ] &&
  grep -Eq ', during the run, cpu besides the bench p90 0\.05, max 0\.80, mean 0\.[01][0-9] per core: calm \(noisy above 0\.50\)$' "$tmp/out.spike" &&
  [ -z "$(culprits "$tmp/out.spike")" ] &&
  pass "one noisy reading among many calm ones reads calm: the 90th percentile decides" ||
  fail "a run with one spike exited [$code] and printed [$(cat "$tmp/out.spike")]"

# Load that lasts is still noisy, and the culprits are read over the noisy
# readings, their CPU percent averaged over them.
echo 0.05 >"$tmp/cpu.sustained"
BENCH_LOCK_SAMPLE_SECONDS=1 BENCH_LOCK_PROCESSES="$tmp/processes.p90" BENCH_LOCK_CPU_PER_CORE="$tmp/cpu.sustained" through_a_pipe sustained \
  sh -c 'sleep 2.5; echo 0.8 >"$1"; sleep 11' _ "$tmp/cpu.sustained"
[ "$code" = 0 ] &&
  grep -Eq ', during the run, cpu besides the bench p90 0\.80, max 0\.80, mean 0\.[5-7][0-9] per core: noisy \(noisy above 0\.50\)$' "$tmp/out.sustained" &&
  [ "$(tail -n 1 "$tmp/out.sustained")" = "bench-lock: busiest besides the bench: other (pid 301, 80% cpu)" ] &&
  pass "load that lasts reads noisy, and names the processes busy over the noisy readings" ||
  fail "a run under sustained load exited [$code] and printed [$(cat "$tmp/out.sustained")]"

# A signal that kills the command: the line still comes, after the command's
# output, and the pipe closes, so nothing of bench-lock outlives the command.
# The command is a process with no child of bench-lock's: what `pgrep -P`
# lists under the pid that status prints is the bench's alone.
fresh_state
("$tool" run -- sh -c 'echo "command output"; echo "start a" >>"$JOB_LOG"; exec sleep 30' 2>&1
  echo "code $?" >>"$JOB_LOG") 2>/dev/null | cat >"$tmp/out.killed" &
pipeline=$!
wait_for logged "start a" || fail "the command never started"
pid_a="$(holder_pid)"
[ -n "$pid_a" ] && [ -z "$(pgrep -P "$pid_a")" ] &&
  pass "the command has no child of bench-lock's" ||
  fail "under the holder [$pid_a]: [$(pgrep -lP "$pid_a")]"
kill -TERM "$pid_a"
collect "$pipeline"
[ "$code" = 0 ] && logged "code 143" &&
  [ "$(tail -n 1 "$tmp/out.killed")" = "$(end_line "$tmp/out.killed")" ] &&
  [ "$(head -n 2 "$tmp/out.killed" | tail -n 1)" = "command output" ] &&
  pass "a command killed by a signal ends with the line, its death returned, and nothing left behind" ||
  fail "after TERM the pipe gave [$code], the log is [$(tr '\n' ' ' <"$JOB_LOG")], the output [$(cat "$tmp/out.killed")]"

# Signals to the whole process group, as a terminal sends them, reach the
# command, which decides: one that carries on keeps its run sampled.
fresh_state
launch group "$tmp" "$tmp/stubborn" a 6
pid_a=$pid
wait_for logged "start a" || fail "the stubborn command never started"
kill -INT -- "-$pid_a"
kill -TERM -- "-$pid_a"
wait_for logged "a got TERM" || fail "the signals never reached the command"
sleep 0.6
early="$(end_line "$tmp/err.group")"
release a
collect "$pid_a"
has_end_line() { [ -n "$(end_line "$1")" ]; }
[ "$code" = 6 ] && [ -z "$early" ] && wait_for has_end_line "$tmp/err.group" &&
  pass "signals to the process group leave a running command sampled, and its line comes once it is over" ||
  fail "after INT and TERM to the group the command exited [$code], said [$early] while running, and [$(cat "$tmp/err.group")]"

# ── The settle wait ──────────────────────────────────────────────────────────
# Under the lock, before the command starts, a noisy machine is waited on until
# it reads calm, for a capped time. A reading that changes during the wait
# cannot be imposed through the environment, which the run reads once: here
# BENCH_LOCK_CPU_PER_CORE names a file instead, rewritten by the case while the
# run waits.
settling() { [ "$(grep -c '^bench-lock: waiting for the machine to settle' "$tmp/err.$1")" -ge "$2" ]; }
fresh_state
reading="$tmp/reading"
echo 0.8 >"$reading"
BENCH_LOCK_SETTLE=60 BENCH_LOCK_NOTICE_SECONDS=1 BENCH_LOCK_CPU_PER_CORE="$reading" launch s "$tmp" "$tmp/job" s 4
pid_s=$pid
wait_for settling s 2 &&
  grep -q '^bench-lock: waiting for the machine to settle, cpu 0.80 per core (noisy above 0.50), [0-9]*s waited of 60s at most$' "$tmp/err.s" &&
  pass "a noisy machine is waited on, one line per notice period" ||
  fail "a run on a noisy machine said [$(cat "$tmp/err.s")]"
! logged "start s" && [ "$(verdicts "$tmp/err.s")" = 0 ] && status_has "^holder: pid $pid_s," &&
  pass "the settle wait happens under the lock, before the verdict and the command" ||
  fail "while settling the log is [$(tr '\n' ' ' <"$JOB_LOG")], stderr [$(cat "$tmp/err.s")], status [$("$tool" status 2>&1)]"
echo 0.05 >"$reading"
wait_for logged "start s" &&
  grep -q '^bench-lock: on [^,]*, cpu 0.05 per core: calm (noisy above 0.50)$' "$tmp/err.s" &&
  pass "once the machine reads calm, the verdict says so and the command starts" ||
  fail "after the machine calmed down the run said [$(cat "$tmp/err.s")]"
release s
collect "$pid_s"
[ "$code" = 4 ] &&
  pass "after a settle wait the exit code is the command's" ||
  fail "the run that settled exited [$code], expected 4"

# The wait is capped: a machine that stays noisy is measured anyway, and the
# verdict says the wait ran out. The verdict only names the cap it was given,
# so the duration is what proves the cap held: bounded at 30s, many times the
# one-second cap for a loaded machine, and far below the 120s default.
started=$SECONDS
BENCH_LOCK_SETTLE=1 BENCH_LOCK_CPU_PER_CORE=0.8 "$tool" run -- sh -c 'exit 3' 2>"$tmp/err.capped"
code=$?
elapsed=$((SECONDS - started))
[ "$code" = 3 ] && [ "$elapsed" -lt 30 ] &&
  grep -q '^bench-lock: on [^,]*, cpu 0.80 per core: noisy (noisy above 0.50); the settle wait ran out after 1s$' "$tmp/err.capped" &&
  pass "a settle wait that runs out starts the command anyway, and the verdict says so" ||
  fail "a capped wait exited [$code] after ${elapsed}s and said [$(cat "$tmp/err.capped")]"

# A machine that cannot be read cannot be waited on. The wait announces itself
# before its first pause, so no such line means no wait.
BENCH_LOCK_SETTLE=60 BENCH_LOCK_CPU_PER_CORE=none BENCH_LOCK_LOAD_PER_CORE=none "$tool" run -- true 2>"$tmp/err.unread.settle"
! grep -q 'settle' "$tmp/err.unread.settle" &&
  grep -q '^bench-lock: on [^,]*, load unknown: no verdict$' "$tmp/err.unread.settle" &&
  pass "a machine that cannot be read is not waited on" ||
  fail "an unreadable machine said [$(cat "$tmp/err.unread.settle")]"

# By default the wait is capped at two minutes, and a signal during it gives
# the lock back: no command ran under it.
fresh_state
env -u BENCH_LOCK_SETTLE BENCH_LOCK_CPU_PER_CORE=0.8 "$tool" run -- "$tmp/job" d 2>"$tmp/err.d" &
pid_d=$!
wait_for settling d 1 &&
  grep -q ', [0-9]*s waited of 120s at most$' "$tmp/err.d" &&
  pass "by default the settle wait is capped at 120s" ||
  fail "a run with the default cap said [$(cat "$tmp/err.d")]"
kill -TERM "$pid_d"
collect "$pid_d"
[ "$code" = 143 ] && ! logged "start d" && wait_for status_has '^free' &&
  pass "a signal during the settle wait gives the lock back and the command never runs" ||
  fail "a run stopped while settling exited [$code], log [$(tr '\n' ' ' <"$JOB_LOG")], status [$("$tool" status 2>&1)]"

# `settle` alone: the same wait and verdict, for a caller already under the
# lock that loaded the machine since. It takes no lock, and ends at 0. As for
# `run` above, the duration proves the one-second cap held, not the default:
# bounded at 30s, generous for a loaded machine.
started=$SECONDS
BENCH_LOCK_HELD=1 BENCH_LOCK_SETTLE=1 BENCH_LOCK_CPU_PER_CORE=0.8 "$tool" settle 2>"$tmp/err.alone"
code=$?
[ "$code" = 0 ] && [ $((SECONDS - started)) -lt 30 ] && status_has '^free' &&
  grep -q '^bench-lock: waiting for the machine to settle, cpu 0.80 per core' "$tmp/err.alone" &&
  grep -q '^bench-lock: on [^,]*, cpu 0.80 per core: noisy (noisy above 0.50); the settle wait ran out after 1s$' "$tmp/err.alone" &&
  pass "settle on its own waits, says the verdict and exits 0, under a held lock too" ||
  fail "settle on its own exited [$code] and said [$(cat "$tmp/err.alone")]"

# ── The culprits ─────────────────────────────────────────────────────────────
# A noisy verdict, at the start or at the end of the run, is followed by one
# line naming the three busiest processes besides the bench. A calm one is not.
# BENCH_LOCK_PROCESSES names a file that stands in for the process table `ps`
# prints (pid, parent pid, CPU percent, CPU time, command), read anew each
# time, so a case can name the bench's own pid in it once that pid exists.
culprits() { grep '^bench-lock: busiest besides the bench: ' "$1"; }
fresh_state
cat >"$tmp/processes" <<'PS'
  101     1  12.0   0:03.10 /usr/libexec/idle-thing
  102     1  85.4  12:41.07 /Applications/Big App.app/Contents/MacOS/Big App
  103     1   0.0   0:00.00 /bin/quiet
  104   102  40.0   3:12.55 node
  105     1  30.0   1:00.00 /usr/bin/yes
PS
expected='bench-lock: busiest besides the bench: Big App (pid 102, 85% cpu), node (pid 104, 40% cpu), yes (pid 105, 30% cpu)'
BENCH_LOCK_PROCESSES="$tmp/processes" BENCH_LOCK_CPU_PER_CORE=0.8 through_a_pipe culprits true
[ "$code" = 0 ] && [ "$(sed -n 2p "$tmp/out.culprits")" = "$expected" ] &&
  [ "$(tail -n 1 "$tmp/out.culprits")" = "$expected" ] && [ "$(culprits "$tmp/out.culprits" | grep -c .)" = 2 ] &&
  grep -q '^bench-lock: on [^,]*, cpu 0.80 per core: noisy' "$tmp/out.culprits" &&
  pass "a noisy verdict, at the start and at the end, is followed by the three busiest processes" ||
  fail "a noisy run exited [$code] and printed [$(cat "$tmp/out.culprits")]"

BENCH_LOCK_PROCESSES="$tmp/processes" BENCH_LOCK_CPU_PER_CORE=0.05 through_a_pipe innocent true
[ "$code" = 0 ] && [ -z "$(culprits "$tmp/out.innocent")" ] &&
  pass "a calm verdict names no culprit" ||
  fail "a calm run printed [$(cat "$tmp/out.innocent")]"

# At the start there is no bench yet: bench-lock itself, and whatever it runs
# to read the machine, are left out.
: >"$tmp/processes.self"
BENCH_LOCK_SETTLE=2 BENCH_LOCK_PROCESSES="$tmp/processes.self" BENCH_LOCK_CPU_PER_CORE=0.8 "$tool" settle 2>"$tmp/err.self" &
self=$!
printf '%s\n' "$self 1 99.0 0:01.00 bench-lock" "9$self $self 98.0 0:00.50 ps" "201 1 5.0 0:00.20 other" >"$tmp/processes.self"
collect "$self"
[ "$code" = 0 ] && [ "$(tail -n 1 "$tmp/err.self")" = "bench-lock: busiest besides the bench: other (pid 201, 5% cpu)" ] &&
  pass "a settle wait that runs out names the culprits, bench-lock and its children left out" ||
  fail "settle exited [$code] and said [$(cat "$tmp/err.self")]"

# During the run the bench and its children are left out, and the processes
# are named while the run is noisy, not once it is over. The command writes
# the table with its own pid, then turns the reading noisy. The bench's own
# share is small: what is left of the reading stays noisy on any core count.
echo 0.05 >"$tmp/reading.run"
BENCH_LOCK_PROCESSES="$tmp/processes.run" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.run" through_a_pipe bench \
  sh -c 'printf "%s\n" "$$ 1 9.0 0:00.10 sh" "9$$ $$ 8.0 0:00.10 node" "301 1 7.0 0:00.10 other" >"$1"; echo 0.8 >"$2"; sleep 3
    printf "%s\n" "401 1 50.0 0:01.00 later" >"$1"' _ "$tmp/processes.run" "$tmp/reading.run"
[ "$code" = 0 ] && [ "$(culprits "$tmp/out.bench" | grep -c .)" = 1 ] &&
  [ "$(tail -n 2 "$tmp/out.bench" | head -n 1)" = "$(end_line "$tmp/out.bench")" ] &&
  [ "$(tail -n 1 "$tmp/out.bench")" = "bench-lock: busiest besides the bench: other (pid 301, 7% cpu)" ] &&
  pass "a noisy run names the culprits seen while it ran, the bench and its children left out" ||
  fail "a run noisy midway exited [$code] and printed [$(cat "$tmp/out.bench")]"

# The end-of-run reading judges the load besides the bench: the CPU time the
# bench and its children consumed over each reading, from the process table
# read just before and just after it, is taken off. A bench that keeps every
# core busy from its first instant, on the machine's own CPU reading and
# process table, leaves only the rest of the machine besides it: calm, the
# threshold set just short of a full machine so that a desk's background
# load does not count.
cores="$(getconf _NPROCESSORS_ONLN)"
env -u BENCH_LOCK_CPU_PER_CORE -u BENCH_LOCK_PROCESSES BENCH_LOCK_NOISY_ABOVE=0.9 "$tool" run -- \
  sh -c 'i=0; while [ $i -lt "$1" ]; do sh -c "while :; do :; done" & i=$((i + 1)); done
    sleep 3; kill $(jobs -p)' _ "$cores" 2>&1 | cat >"$tmp/out.own"
grep -Eq '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0\.[0-8][0-9], max 0\.[0-8][0-9], mean 0\.[0-8][0-9] per core: calm \(noisy above 0\.90\)$' "$tmp/out.own" &&
  pass "a bench that keeps the machine busy by itself reads calm: only the load besides it is judged" ||
  fail "a busy bench on the real machine printed [$(cat "$tmp/out.own")]"

# A bench busy earlier and idle now: `ps` still gives it a large CPU share
# (decaying on macOS, a lifetime average on Linux), but its CPU time no longer
# grows. The load besides it is all of the reading, and is reported.
echo 0.05 >"$tmp/reading.idle"
BENCH_LOCK_PROCESSES="$tmp/processes.idle" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.idle" through_a_pipe idle \
  sh -c 'printf "%s\n" "$$ 1 $(($3 * 70)).0 5:00.00 sh" "301 1 80.0 0:42.00 other" >"$1"; echo 0.8 >"$2"; sleep 3' \
  _ "$tmp/processes.idle" "$tmp/reading.idle" "$cores"
[ "$code" = 0 ] &&
  grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.80, max 0.80, ' "$tmp/out.idle" &&
  grep -q ' per core: noisy (noisy above 0.50)$' "$tmp/out.idle" &&
  [ "$(tail -n 1 "$tmp/out.idle")" = "bench-lock: busiest besides the bench: other (pid 301, 80% cpu)" ] &&
  pass "a bench busy earlier and idle now hides none of the load besides it" ||
  fail "an idle bench on a busy machine exited [$code] and printed [$(cat "$tmp/out.idle")]"

# A CPU time that cannot be read takes nothing off: the reading is kept whole.
echo 0.05 >"$tmp/reading.untimed"
BENCH_LOCK_PROCESSES="$tmp/processes.untimed" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.untimed" through_a_pipe untimed \
  sh -c 'printf "%s\n" "$$ 1 70.0 ? sh" "301 1 1.0 ? other" >"$1"; echo 0.8 >"$2"; sleep 3' \
  _ "$tmp/processes.untimed" "$tmp/reading.untimed"
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.80, max 0.80, ' "$tmp/out.untimed" &&
  pass "without a readable CPU time, the reading is kept whole" ||
  fail "a bench without CPU time exited [$code] and printed [$(cat "$tmp/out.untimed")]"

# A process of the bench's own outside its tree (Chrome started through `open`,
# say, owned by launchd) reads as load besides the bench, and as a culprit,
# until the bench lists its pid in the file BENCH_LOCK_OWN_PIDS names, created
# empty. From then on it and its descendants are the bench's own: left out of
# the culprits, their CPU time taken off. Lines that are not a pid are ignored.
cat >"$tmp/processes.outside" <<'PS'
  501     1  90.0   0:10.00 Google Chrome for Testing
  502   501  40.0   0:05.00 Google Chrome for Testing Helper
  301     1   7.0   0:00.10 other
PS
outside_bench='[ -f "$BENCH_LOCK_OWN_PIDS" ] && [ ! -s "$BENCH_LOCK_OWN_PIDS" ] && echo "an empty list"
  [ -z "$2" ] || printf "%s\n" "not a pid" "" "$2" >>"$BENCH_LOCK_OWN_PIDS"
  echo 0.8 >"$1"; sleep 3'
fresh_state
echo 0.05 >"$tmp/reading.outside"
BENCH_LOCK_PROCESSES="$tmp/processes.outside" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.outside" through_a_pipe outside \
  sh -c "$outside_bench" _ "$tmp/reading.outside" ""
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.80, max 0.80, ' "$tmp/out.outside" &&
  [ "$(tail -n 1 "$tmp/out.outside")" = "bench-lock: busiest besides the bench: Google Chrome for Testing (pid 501, 90% cpu), Google Chrome for Testing Helper (pid 502, 40% cpu), other (pid 301, 7% cpu)" ] &&
  pass "a busy process outside the bench's tree is load besides it, and a culprit" ||
  fail "a run beside an undeclared process exited [$code] and printed [$(cat "$tmp/out.outside")]"

echo 0.05 >"$tmp/reading.declared"
BENCH_LOCK_PROCESSES="$tmp/processes.outside" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.declared" through_a_pipe declared \
  sh -c "$outside_bench" _ "$tmp/reading.declared" 501
[ "$code" = 0 ] && grep -qx 'an empty list' "$tmp/out.declared" &&
  [ "$(tail -n 1 "$tmp/out.declared")" = "bench-lock: busiest besides the bench: other (pid 301, 7% cpu)" ] &&
  pass "a process the bench lists as its own, and its descendants, are no culprits" ||
  fail "a run that declared its process exited [$code] and printed [$(cat "$tmp/out.declared")]"

# Its CPU time is the bench's own share: a table whose CPU times grow by a
# thousand minutes at every read, through a FIFO, makes that share outweigh
# any reading.
mkfifo "$tmp/processes.growing"
(
  minutes=0
  while :; do
    minutes=$((minutes + 1000))
    printf '%s\n' "501 1 90.0 $minutes:00 chrome" "502 501 40.0 $minutes:00 helper" >"$tmp/processes.growing"
    sleep 0.1
  done
) &
writer=$!
echo 0.05 >"$tmp/reading.growing"
BENCH_LOCK_PROCESSES="$tmp/processes.growing" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.growing" through_a_pipe growing \
  sh -c "$outside_bench" _ "$tmp/reading.growing" 501
{ kill -TERM -- "-$writer" && wait "$writer"; } 2>/dev/null
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.[0-4][0-9], max 0.[0-4][0-9], .*: calm' "$tmp/out.growing" &&
  [ -z "$(culprits "$tmp/out.growing")" ] &&
  pass "the CPU time of a process the bench lists as its own is taken off the reading" ||
  fail "a run beside a busy declared process exited [$code] and printed [$(cat "$tmp/out.growing")]"

# A browser is busiest while it starts, before the bench can know its pid: the
# run is judged once it is over, against every pid the bench declared by then.
# Here the process burns CPU from the first reading and is declared only after
# a couple of them.
late_bench='echo 0.8 >"$1"; sleep 3; echo 501 >>"$BENCH_LOCK_OWN_PIDS"; sleep 3'
mkfifo "$tmp/processes.late"
(
  minutes=0
  while :; do
    minutes=$((minutes + 1000))
    printf '%s\n' "501 1 90.0 $minutes:00 chrome" "502 501 40.0 $minutes:00 helper" "301 1 7.0 0:00.10 other" >"$tmp/processes.late"
    sleep 0.1
  done
) &
writer=$!
echo 0.05 >"$tmp/reading.late"
BENCH_LOCK_PROCESSES="$tmp/processes.late" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.late" through_a_pipe late \
  sh -c "$late_bench" _ "$tmp/reading.late"
{ kill -TERM -- "-$writer" && wait "$writer"; } 2>/dev/null
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.[0-4][0-9], max 0.[0-4][0-9], .*: calm' "$tmp/out.late" &&
  [ -z "$(culprits "$tmp/out.late")" ] &&
  pass "a process declared late is the bench's own from the first reading" ||
  fail "a run that declared its busy process late exited [$code] and printed [$(cat "$tmp/out.late")]"

# The same late declaration on a machine loaded besides the bench still reads
# noisy, and the culprits leave the declared process out, though they were
# read before it was declared: the busiest reading comes first.
cat >"$tmp/processes.loaded" <<'PS'
  501     1  90.0   0:10.00 chrome
  502   501  40.0   0:05.00 helper
  301     1  80.0   0:42.00 other
PS
echo 0.05 >"$tmp/reading.loaded"
BENCH_LOCK_PROCESSES="$tmp/processes.loaded" BENCH_LOCK_CPU_PER_CORE="$tmp/reading.loaded" through_a_pipe loaded \
  sh -c 'echo 0.9 >"$1"; sleep 3; echo 501 >>"$BENCH_LOCK_OWN_PIDS"; echo 0.6 >"$1"; sleep 3' _ "$tmp/reading.loaded"
[ "$code" = 0 ] && grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.90, max 0.90, .*: noisy' "$tmp/out.loaded" &&
  [ "$(tail -n 1 "$tmp/out.loaded")" = "bench-lock: busiest besides the bench: other (pid 301, 80% cpu)" ] &&
  pass "a run loaded besides the bench reads noisy, its late-declared process no culprit" ||
  fail "a loaded run that declared its process late exited [$code] and printed [$(cat "$tmp/out.loaded")]"

# The real process table: `ps` flags valid on macOS and Linux alike.
env -u BENCH_LOCK_PROCESSES BENCH_LOCK_CPU_PER_CORE=0.8 "$tool" settle 2>"$tmp/err.real.culprits"
culprits "$tmp/err.real.culprits" | grep -Eq '^bench-lock: busiest besides the bench: (none|[^ ].* \(pid [0-9]+, [0-9]+% cpu\))$' &&
  pass "without an imposed table, the machine's own processes are read" ||
  fail "a noisy verdict on the real table said [$(cat "$tmp/err.real.culprits")]"

# ── A long wait does not look like a hang ────────────────────────────────────
# The waiting line comes back periodically. BENCH_LOCK_NOTICE_SECONDS sets the
# period, so the case does not have to sit through the default minute.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch patient "$tmp" "$tmp/job" patient
pid_patient=$pid
wait_for status_has "^waiter 1: pid $pid_patient," || fail "the patient caller never queued"
BENCH_LOCK_NOTICE_SECONDS=1 launch b "$tmp" "$tmp/job" b
pid_b=$pid
said() { [ "$(grep -Ec "held for [0-9]+s by pid $pid_a " "$tmp/err.$1")" -ge "$2" ]; }
wait_for said b 3 &&
  pass "the waiting line is repeated periodically, holder and age each time" ||
  fail "the waiter with a one-second period said [$(cat "$tmp/err.b")]"
[ "$(grep -c . "$tmp/err.patient")" = 1 ] &&
  pass "by default the line is not repeated on every poll" ||
  fail "the waiter with the default period said [$(cat "$tmp/err.patient")]"
grep -q "1 ahead in the queue" "$tmp/err.b" &&
  pass "a waiter that is not next in line says how many are ahead" ||
  fail "the second waiter said [$(cat "$tmp/err.b")]"
release patient
release b
release a
collect "$pid_a"
collect "$pid_patient"
collect "$pid_b"

# ── Where the state lives ────────────────────────────────────────────────────
# Asked through the tool alone: two commands share a lock exactly when they
# resolve the same state directory.
fresh_state
home="$tmp/home"
mkdir -p "$home"
XDG_STATE_HOME="" HOME="$home" launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
held_for() { "$@" "$tool" status 2>&1 | grep -q "^holder: pid $pid_a,"; }
held_for env XDG_STATE_HOME="$home/.local/state" &&
  pass "without XDG_STATE_HOME the state is under HOME, in .local/state" ||
  fail "the lock taken with HOME alone is not under $home/.local/state"
! held_for env XDG_STATE_HOME="" HOME="$tmp/another-home" &&
  pass "another HOME is another lock" ||
  fail "a different HOME sees the same lock"
! held_for env XDG_STATE_HOME="$tmp/another-state" HOME="$home" &&
  pass "XDG_STATE_HOME, when set, decides" ||
  fail "a different XDG_STATE_HOME sees the same lock"
held_for env XDG_STATE_HOME="relative/state" HOME="$home" &&
  pass "a relative XDG_STATE_HOME is ignored, not resolved against the working directory" ||
  fail "a relative XDG_STATE_HOME moved the lock"
release a
collect "$pid_a"

# ── Nothing but a shell and the system's utilities ───────────────────────────
# A copy of the executable, alone in another directory, with an empty
# environment and the bare system PATH: no Node, no harness checkout.
fresh_state
mkdir -p "$tmp/elsewhere"
cp "$tool" "$tmp/elsewhere/bench-lock"
env -i PATH=/usr/bin:/bin HOME="$home" "$tmp/elsewhere/bench-lock" run -- sh -c 'exit 4' 2>"$tmp/err.bare"
code=$?
bare_status="$(env -i PATH=/usr/bin:/bin HOME="$home" "$tmp/elsewhere/bench-lock" status 2>&1)"
[ "$code" = 4 ] && [ "$bare_status" = "free: no bench holds the lock" ] &&
  pass "a lone copy runs on the bare system PATH, away from the harness checkout" ||
  fail "the lone copy exited [$code], said [$(cat "$tmp/err.bare")], status [$bare_status]"

# ── A state directory wiped by hand ──────────────────────────────────────────
# Never to be done: it breaks the exclusion for the benches in flight. But it
# must not leave a waiter queueing for ever behind nothing, nor let the old
# holder take its successor's lock away on its way out.
fresh_state
launch a "$tmp" "$tmp/job" a
pid_a=$pid
wait_for logged "start a" || fail "the holder never started its command"
launch b "$tmp" "$tmp/job" b
pid_b=$pid
wait_for status_has "^waiter 1: pid $pid_b," || fail "caller b never queued"
mv "$XDG_STATE_HOME" "$tmp/wiped"
wait_for logged "start b" && grep -q "joining again" "$tmp/err.b" &&
  pass "a waiter whose place in the queue vanished says so and joins again" ||
  fail "after the wipe the waiter said [$(cat "$tmp/err.b")]"
release a
collect "$pid_a"
status_has "^holder: pid $pid_b," &&
  pass "a holder whose lock vanished leaves its successor's alone" ||
  fail "after the old holder left, status printed [$("$tool" status 2>&1)]"
release b
collect "$pid_b"
status_has '^free' || fail "status at the end printed [$("$tool" status 2>&1)]"

# ── At a terminal ────────────────────────────────────────────────────────────
# `script` provides the terminal, and whatever is piped into it is typed at the
# keyboard. Only its BSD form is spoken here.
#
# at_terminal <name> <keys> <command...>: `bench-lock run` on a terminal of its
# own, <keys> being the function that types; output in $tmp/out.<name>.
at_terminal() {
  local name="$1" keys="$2"
  shift 2
  "$keys" | script -q /dev/null "$tool" run -- "$@" >"$tmp/out.$name" 2>&1 &
  pid=$!
}
# The keyboard stays open for a moment after the last key: its end of file
# would be typed as Ctrl-D.
no_keys() { sleep 2; }
ctrl_c_once_started() {
  wait_for logged "start a" && printf '\003'
  sleep 2
}

if script -q /dev/null true >/dev/null 2>&1; then
  fresh_state
  at_terminal streams no_keys sh -c '[ -t 0 ] && echo "stdin: the terminal"; [ -t 1 ] && echo "stdout: the terminal"'
  collect "$pid"
  if [ "$code" = 0 ] && grep -q "stdin: the terminal" "$tmp/out.streams" && grep -q "stdout: the terminal" "$tmp/out.streams"; then
    pass "at a terminal the command reads from it and writes to it, as it would unwrapped"
  else
    fail "at a terminal the command exited [$code] and printed [$(cat "$tmp/out.streams")]"
  fi

  fresh_state
  # script(1) reports a command killed by a signal its own way: the reference
  # is the same command at the same terminal, without bench-lock.
  ctrl_c_once_started | script -q /dev/null sh -c 'echo "start a" >>"$JOB_LOG"; exec sleep 30' >/dev/null 2>&1
  unwrapped=$?
  fresh_state
  at_terminal a ctrl_c_once_started sh -c 'echo "start a" >>"$JOB_LOG"; exec sleep 30'
  collect "$pid"
  [ "$code" = "$unwrapped" ] &&
    pass "at a terminal Ctrl-C stops the wrapped command, which ends as it would unwrapped" ||
    fail "after Ctrl-C the caller exited [$code], unwrapped [$unwrapped]: [$(cat "$tmp/out.a")]"
  wait_for status_has '^free' &&
    pass "after Ctrl-C the lock is released" ||
    fail "status after Ctrl-C printed [$("$tool" status 2>&1)]"

  fresh_state
  at_terminal a ctrl_c_once_started "$tmp/stubborn" a 6
  pid_a=$pid
  wait_for logged "a got INT" || fail "Ctrl-C never reached the wrapped command"
  # Long enough for a duplicate to land.
  sleep 1
  [ "$(count_logged "a got INT")" = 1 ] && status_has '^holder: pid ' &&
    pass "Ctrl-C reaches the command, which keeps the lock if it carries on" ||
    fail "after one Ctrl-C the log is [$(tr '\n' ' ' <"$JOB_LOG")] and status [$("$tool" status 2>&1)]"
  kill -TERM "$(holder_pid)"
  wait_for logged "a got TERM" &&
    pass "at a terminal too, a signal sent to the pid that status prints reaches the command" ||
    fail "a signal sent to the holder at a terminal went nowhere: [$(tr '\n' ' ' <"$JOB_LOG")]"
  release a
  collect "$pid_a"
  [ "$code" = 6 ] &&
    pass "at a terminal too, the exit code is the command's" ||
    fail "the stubborn command at a terminal exited [$code], expected 6"
else
  echo "  skip the cases at a terminal: no BSD script(1) here"
fi

if [ "$fails" -eq 0 ]; then
  echo "bench-lock: all pass"
else
  echo "bench-lock: $fails failure(s)"
fi
exit "$((fails > 0))"
