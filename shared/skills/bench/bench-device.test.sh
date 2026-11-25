#!/usr/bin/env bash
# bench-device.test.sh: behavioural tests for bin/bench-device.
#
# No phone is ever real here. adb is BENCH_DEVICE_ADB, pointing at a fake that
# answers from the current case's fixtures (the devices attached and their
# states, the screen's wakefulness, the keyguard, Chrome's DevTools socket) and
# logs every call. The phone Chrome's DevTools HTTP endpoint is a small local
# HTTP server, on the port the fake adb hands out for the forward: it answers
# from the same fixtures and logs every request to the same log, so the log
# holds the order of everything the tool did. The lock is the real
# `bench-lock`, against a throwaway state directory. Every case launches the
# real executable as a process and asserts only on what a caller can observe:
# exit codes, stderr, the environment the wrapped command sees, and the call
# log.
set -u

# Job control, so that every backgrounded `bench-device` below is its own
# process group with default signal dispositions, the way a command typed at a
# terminal is. Without it bash starts background commands with SIGINT ignored,
# and no case below could interrupt one.
set -m

# The suite's own stdin is never a terminal, wherever it is launched from.
exec </dev/null

# A run of this suite under a held lock must still exercise the lock, and no
# ambient setting may change what it proves. The CPU reading is imposed, so
# that `bench-lock`'s calm verdict line, which shows a run went through the
# lock, says the same on every machine.
unset BENCH_LOCK_HELD BENCH_LOCK_NOTICE_SECONDS BENCH_LOCK_NOISY_ABOVE BENCH_DEVICE_SERIAL
export BENCH_LOCK_CPU_PER_CORE=0.10
export BENCH_LOCK_POLL_SECONDS=0.2
# A Chrome whose DevTools never answers is refused after a second, not ten.
export BENCH_DEVICE_CHROME_SECONDS=1
# A phone that never cools is waited for two seconds, not minutes, and read
# five times a second.
export BENCH_DEVICE_THERMAL_SECONDS=2
export BENCH_DEVICE_THERMAL_POLL_SECONDS=0.2

here="$(cd "$(dirname "$0")" && pwd -P)"
tool="$here/bin/bench-device"
lock_tool="$here/bin/bench-lock"
# `bench-device` finds `bench-lock` on PATH, as it does once installed.
export PATH="$here/bin:$PATH"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  fails=$((fails + 1))
}

# A signal ignored when a shell starts stays ignored in everything it launches.
sigint_heard=""
trap 'sigint_heard=1' INT
kill -INT "$$"
trap - INT
if [ -z "$sigint_heard" ]; then
  echo "bench-device: SIGINT is ignored in this shell, so no case could interrupt anything."
  echo "bench-device: run the suite with \`pnpm test\`, or from a foreground shell."
  exit 1
fi

tmp="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local leader
  for leader in $(jobs -p); do kill -TERM -- "-$leader" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

# ── The fake adb ─────────────────────────────────────────────────────────────
# Logs every call, one line each, then answers from $FAKE_ADB_DIR:
#
#   devices              the lines `adb devices` lists, "<serial>\t<state>"
#   devices.fails        present: `adb devices` fails
#   wakefulness.<serial> what `dumpsys power` says of the screen (Awake, Asleep...)
#   keyguard.<serial>    what `dumpsys window` says of the keyguard (true, false)
#   power.fails, window.fails
#                        present: that dumpsys fails
#   no-socket            present: Chrome's DevTools socket never shows up
#   reverse.fails        present: setting a reversal fails
#   forwards             the lines `adb forward --list` lists, every device's
#   thermal              the thermal statuses `dumpsys thermalservice` says, one
#                        per line: each reading takes the first line off, the
#                        last one stays
#   thermal.fails, battery.fails
#                        present: that dumpsys fails
#   battery              the lines `dumpsys battery` says after its header
#   model                what `getprop ro.product.model` says
#
# Chrome's DevTools socket is listed in /proc/net/unix once Chrome was started
# on its blank page, and gone once it is force-stopped. The forward to it
# answers the port of the fake DevTools endpoint below. A reading with no
# fixture comes back without its line, as from a device whose dumpsys does not
# say. Lines end with CR LF, as some adb versions send them. Any other call is
# unexpected: it fails, and says so.
cat >"$tmp/adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_ADB_LOG"
fixtures="$FAKE_ADB_DIR"
if [ "$*" = devices ]; then
  [ ! -e "$fixtures/devices.fails" ] || exit 1
  printf 'List of devices attached\r\n'
  [ ! -f "$fixtures/devices" ] || sed 's/$/\r/' "$fixtures/devices"
  printf '\r\n'
  exit 0
fi
if [ "$*" = "forward --list" ]; then
  [ ! -f "$fixtures/forwards" ] || sed 's/$/\r/' "$fixtures/forwards"
  exit 0
fi
if [ "$1" != -s ]; then
  echo "fake adb: unexpected call: $*" >&2
  exit 1
fi
serial="$2"
shift 2
case "$*" in
  "shell dumpsys power")
    [ ! -e "$fixtures/power.fails" ] || exit 1
    printf 'POWER MANAGER (dumpsys power)\r\n'
    printf '  mWakefulnessChanging=false\r\n'
    [ ! -f "$fixtures/wakefulness.$serial" ] || printf '  mWakefulness=%s\r\n' "$(cat "$fixtures/wakefulness.$serial")"
    ;;
  "shell dumpsys window")
    [ ! -e "$fixtures/window.fails" ] || exit 1
    printf 'WINDOW MANAGER POLICY STATE (dumpsys window policy)\r\n'
    printf '    mShowingDream=false mDreamingLockscreen=false\r\n'
    [ ! -f "$fixtures/keyguard.$serial" ] || printf '    isKeyguardShowing=%s\r\n' "$(cat "$fixtures/keyguard.$serial")"
    ;;
  "shell dumpsys thermalservice")
    [ ! -e "$fixtures/thermal.fails" ] || exit 1
    printf 'IsStatusOverride: false\r\n'
    if [ -s "$fixtures/thermal" ]; then
      printf 'Thermal Status: %s\r\n' "$(head -n 1 "$fixtures/thermal")"
      if [ "$(wc -l <"$fixtures/thermal")" -gt 1 ]; then
        tail -n +2 "$fixtures/thermal" >"$fixtures/thermal.next"
        mv "$fixtures/thermal.next" "$fixtures/thermal"
      fi
    fi
    printf 'Cached temperatures:\r\n'
    printf '\tTemperature{mValue=45.6, mType=0, mName=cpu-0-0-usr, mStatus=0}\r\n'
    ;;
  "shell dumpsys battery")
    [ ! -e "$fixtures/battery.fails" ] || exit 1
    printf 'Current Battery Service state:\r\n'
    printf '  AC powered: true\r\n'
    printf '  Max charging voltage: 5000000\r\n'
    [ ! -f "$fixtures/battery" ] || sed 's/$/\r/' "$fixtures/battery"
    ;;
  "shell getprop ro.product.model")
    [ ! -f "$fixtures/model" ] || sed 's/$/\r/' "$fixtures/model"
    ;;
  "reverse --remove-all" | "forward --remove tcp:"*) ;;
  "shell am force-stop com.android.chrome")
    rm -f "$fixtures/chrome.started"
    ;;
  "shell am start -a android.intent.action.VIEW -d about:blank com.android.chrome")
    printf 'Starting: Intent { act=android.intent.action.VIEW dat=about:blank pkg=com.android.chrome }\r\n'
    : >"$fixtures/chrome.started"
    ;;
  "shell cat /proc/net/unix")
    printf 'Num       RefCount Protocol Flags    Type St Inode Path\r\n'
    printf '0000000000000000: 00000002 00000000 00010000 0001 01 39204 @stetho_com.example_devtools_remote\r\n'
    if [ -e "$fixtures/chrome.started" ] && [ ! -e "$fixtures/no-socket" ]; then
      printf '0000000000000000: 00000002 00000000 00010000 0001 01 211446 @chrome_devtools_remote\r\n'
    fi
    ;;
  "reverse tcp:"*" tcp:"*)
    [ ! -e "$fixtures/reverse.fails" ] || exit 1
    ;;
  "forward tcp:0 localabstract:chrome_devtools_remote")
    printf '%s\r\n' "$(cat "$FAKE_DEVTOOLS_PORT_FILE")"
    ;;
  "shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.android.chrome/com.google.android.apps.chrome.Main")
    printf 'Starting: Intent { act=android.intent.action.MAIN cat=[android.intent.category.LAUNCHER] cmp=com.android.chrome/com.google.android.apps.chrome.Main }\r\n'
    ;;
  "shell input keyevent KEYCODE_WAKEUP") ;;
  *)
    echo "fake adb: unexpected call: -s $serial $*" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$tmp/adb"
export BENCH_DEVICE_ADB="$tmp/adb"

# ── The fake DevTools endpoint ───────────────────────────────────────────────
# One HTTP server for the whole suite, on a port of its own choosing, which the
# fake adb hands out as the forward's local port. It answers from the current
# case ($tmp/current points at it), and logs every request as "http <path>" to
# the case's call log, after the adb calls that came before it:
#
#   GET /json/version    device/version.json
#   GET /json/list       device/list.json
#   GET /json/close/<id> "Target is closing"
#
# A missing file is a 404, which is how a case makes the endpoint not answer.
export FAKE_DEVTOOLS_PORT_FILE="$tmp/devtools.port"
cat >"$tmp/devtools.mjs" <<'EOF'
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const [current, portFile] = process.argv.slice(2);
const files = { "/json/version": "version.json", "/json/list": "list.json" };

const server = createServer((request, response) => {
  appendFileSync(`${current}/adb.log`, `http ${request.url}\n`);
  if (request.url.startsWith("/json/close/")) {
    response.end("Target is closing");
    return;
  }
  try {
    response.end(readFileSync(`${current}/device/${files[request.url]}`));
  } catch {
    response.statusCode = 404;
    response.end("not found");
  }
});
server.listen(0, "127.0.0.1", () => {
  writeFileSync(portFile, String(server.address().port));
});
EOF
node "$tmp/devtools.mjs" "$tmp/current" "$FAKE_DEVTOOLS_PORT_FILE" &
devtools_listening() { [ -s "$FAKE_DEVTOOLS_PORT_FILE" ]; }

# The wrapped command: records the serial and the DevTools endpoint it was
# given, and its own start in the call log, so that a case can tell what came
# before it. Then it exits with the code it is told.
cat >"$tmp/probe" <<'EOF'
#!/bin/sh
echo "the command starts" >>"$FAKE_ADB_LOG"
echo "${BENCH_DEVICE_SERIAL-unset}" >"$CASE_DIR/ran"
echo "${BENCH_DEVICE_CDP-unset}" >"$CASE_DIR/cdp"
exit "${1:-0}"
EOF
chmod +x "$tmp/probe"
# A lock holder: holds until the case releases it.
cat >"$tmp/job" <<'EOF'
#!/bin/sh
echo "start $1" >>"$CASE_DIR/jobs"
while [ -d "$CASE_DIR" ] && [ ! -e "$CASE_DIR/release.$1" ]; do sleep 0.1; done
exit 0
EOF
chmod +x "$tmp/job"

# Each case gets its own fixtures, state directory and logs.
cases=0
fresh_case() {
  cases=$((cases + 1))
  export CASE_DIR="$tmp/case.$cases"
  export FAKE_ADB_DIR="$CASE_DIR/device"
  export FAKE_ADB_LOG="$CASE_DIR/adb.log"
  export XDG_STATE_HOME="$CASE_DIR/state"
  mkdir -p "$FAKE_ADB_DIR"
  : >"$FAKE_ADB_LOG"
  rm -f "$tmp/current"
  ln -s "$CASE_DIR" "$tmp/current"
  printf '{\n   "Browser": "Chrome/156.0.8078.79",\n   "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/browser"\n}\n' \
    >"$FAKE_ADB_DIR/version.json"
  given_tabs 3275:about:blank
  # The phone as it was read: cool, its battery good at full charge.
  printf '0\n' >"$FAKE_ADB_DIR/thermal"
  printf '  status: 5\n  health: 2\n  level: 100\n  temperature: 251\n' >"$FAKE_ADB_DIR/battery"
  printf 'Pixel 5\n' >"$FAKE_ADB_DIR/model"
}

# given_tabs <id>:<url>...: the targets /json/list lists, in that order, laid out the
# way Chrome Android lays them out. A numeric id is a tab; Chrome also lists a
# hidden target with a long hexadecimal id and an empty URL, which is no tab.
given_tabs() {
  local tab separator="["
  {
    for tab in "$@"; do
      printf '%s {\n' "$separator"
      printf '   "description": "",\n'
      printf '   "id": "%s",\n' "${tab%%:*}"
      printf '   "title": "%s",\n' "${tab#*:}"
      printf '   "type": "page",\n'
      printf '   "url": "%s",\n' "${tab#*:}"
      printf '   "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/page/%s"\n' "${tab%%:*}"
      separator="},"
    done
    printf '} ]\n'
  } >"$FAKE_ADB_DIR/list.json"
}

# attach <serial> <state> [<wakefulness> [<keyguard showing>]]
attach() {
  printf '%s\t%s\n' "$1" "$2" >>"$FAKE_ADB_DIR/devices"
  printf '%s\n' "${3:-Awake}" >"$FAKE_ADB_DIR/wakefulness.$1"
  printf '%s\n' "${4:-false}" >"$FAKE_ADB_DIR/keyguard.$1"
}

wait_for() {
  local tries=100
  while [ "$tries" -gt 0 ]; do
    tries=$((tries - 1))
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# launch <command...>: a backgrounded process, its stderr in $CASE_DIR/err,
# its pid in $pid.
pid=""
launch() {
  ("$@") 2>"$CASE_DIR/err" &
  pid=$!
}
code=""
gone() { ! kill -0 "$1" 2>/dev/null; }
collect() {
  if wait_for gone "$1"; then
    wait "$1" 2>/dev/null
    code=$?
  else
    code="still running"
  fi
}

# device_run <arguments...>: `bench-device` with those arguments, bounded, its
# exit code in $code and its stderr in $CASE_DIR/err.
device_run() {
  launch "$tool" "$@"
  collect "$pid"
}

ran() { [ -f "$CASE_DIR/ran" ]; }
ran_with() { [ "$(cat "$CASE_DIR/ran" 2>/dev/null)" = "$1" ]; }
said() { grep -Eq -- "$1" "$CASE_DIR/err"; }
adb_untouched() { [ ! -s "$FAKE_ADB_LOG" ]; }
adb_called() { grep -qx -- "$1" "$FAKE_ADB_LOG"; }
err() { tr '\n' ' ' <"$CASE_DIR/err"; }
waiting_in_status() { "$lock_tool" status | grep -q "^waiter 1: pid $1,"; }
job_started() { grep -qx "start $1" "$CASE_DIR/jobs" 2>/dev/null; }

# hold_lock: the real `bench-lock` holds the machine's lock around a job that
# runs until `release holder`.
hold_lock() {
  ("$lock_tool" run -- "$tmp/job" holder) 2>/dev/null &
  wait_for job_started holder || fail "the lock holder never started"
}
release() { : >"$CASE_DIR/release.$1"; }

wait_for devtools_listening || {
  echo "bench-device: the fake DevTools endpoint never started (is node on PATH?)"
  exit 1
}

# line_of <exact line>: where it first is in the call log, or nothing.
line_of() { grep -nx -m 1 -- "$1" "$FAKE_ADB_LOG" | cut -d: -f1; }
# in_order <exact line>...: each one is in the call log, after the one before.
in_order() {
  local previous=0 at line
  for line in "$@"; do
    at="$(line_of "$line")"
    [ -n "$at" ] && [ "$at" -gt "$previous" ] || return 1
    previous="$at"
  done
}
calls() { tr '\n' '|' <"$FAKE_ADB_LOG"; }

echo "bench-device:"

# ── A ready device ───────────────────────────────────────────────────────────
fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe" 3
if [ "$code" = 3 ] && ran_with PHONE1; then
  pass "one ready device: the command runs, sees BENCH_DEVICE_SERIAL, and its exit code is returned"
else
  fail "one ready device: exit [$code], serial [$(cat "$CASE_DIR/ran" 2>/dev/null)], stderr [$(err)]"
fi
said '^bench-lock: on .*, cpu 0.10 per core: calm' &&
  pass "the run went through the bench lock, which said its calm verdict" ||
  fail "no calm verdict on stderr: [$(err)]"
adb_called devices && adb_called "-s PHONE1 shell dumpsys power" && adb_called "-s PHONE1 shell dumpsys window" &&
  pass "the device's state and readiness were read through adb" ||
  fail "adb log: [$(tr '\n' ' ' <"$FAKE_ADB_LOG")]"

fresh_case
attach PHONE1 device
attach PHONE2 device
device_run run --serial PHONE2 -- "$tmp/probe"
[ "$code" = 0 ] && ran_with PHONE2 &&
  pass "--serial picks one of several attached devices" ||
  fail "--serial PHONE2: exit [$code], serial [$(cat "$CASE_DIR/ran" 2>/dev/null)], stderr [$(err)]"

fresh_case
attach PHONE1 device
device_run run --reverse 8080 --reverse 65535 --serial PHONE1 --reverse 1 -- "$tmp/probe"
first="$code"
rm -f "$CASE_DIR/ran"
device_run run --serial PHONE1 --reverse 8080 -- "$tmp/probe"
[ "$first" = 0 ] && [ "$code" = 0 ] && ran_with PHONE1 &&
  pass "valid --reverse ports, before or after --serial, are accepted" ||
  fail "valid ports: exits [$first] and [$code], stderr [$(err)]"

# ── Chrome and the ports ─────────────────────────────────────────────────────
stop_chrome="-s PHONE1 shell am force-stop com.android.chrome"
start_chrome="-s PHONE1 shell am start -a android.intent.action.VIEW -d about:blank com.android.chrome"
read_sockets="-s PHONE1 shell cat /proc/net/unix"
forward="-s PHONE1 forward tcp:0 localabstract:chrome_devtools_remote"
to_front="-s PHONE1 shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n com.android.chrome/com.google.android.apps.chrome.Main"
wake="-s PHONE1 shell input keyevent KEYCODE_WAKEUP"

fresh_case
attach PHONE1 device
device_run run --reverse 8080 --reverse 9090 -- "$tmp/probe"
[ "$code" = 0 ] || fail "a wired run: exit [$code], stderr [$(err)]"
in_order "$stop_chrome" "$start_chrome" "$read_sockets" "$forward" "http /json/version" &&
  pass "Chrome is force-stopped, started on a blank page, and its DevTools socket found, before the forward is used" ||
  fail "Chrome's cold restart: [$(calls)]"
in_order "-s PHONE1 reverse --remove-all" "-s PHONE1 reverse tcp:8080 tcp:8080" "-s PHONE1 reverse tcp:9090 tcp:9090" &&
  pass "the device's previous reversals are cleared, then one reversal per --reverse port is set" ||
  fail "the reversals: [$(calls)]"
port="$(cat "$FAKE_DEVTOOLS_PORT_FILE")"
[ "$(cat "$CASE_DIR/cdp" 2>/dev/null)" = "http://127.0.0.1:$port" ] && ran_with PHONE1 &&
  pass "the command sees BENCH_DEVICE_CDP, the forwarded local port, and BENCH_DEVICE_SERIAL" ||
  fail "BENCH_DEVICE_CDP [$(cat "$CASE_DIR/cdp" 2>/dev/null)], forwarded port [$port]"
in_order "http /json/list" "$to_front" "$wake" "the command starts" &&
  pass "Chrome is brought to the foreground, the screen woken, last thing before the command starts" ||
  fail "the foreground: [$(calls)]"

fresh_case
attach PHONE1 device
printf 'PHONE1 tcp:5001 localabstract:chrome_devtools_remote\nPHONE2 tcp:5002 tcp:9222\nPHONE1 tcp:5003 tcp:8000\n' \
  >"$FAKE_ADB_DIR/forwards"
device_run run -- "$tmp/probe"
if [ "$code" = 0 ] && in_order "-s PHONE1 forward --remove tcp:5001" "-s PHONE1 forward --remove tcp:5003" "$forward" &&
  ! grep -q -- "--remove tcp:5002" "$FAKE_ADB_LOG"; then
  pass "the device's previous forwards are cleared, another device's kept, then Chrome's is set"
else
  fail "the forwards: exit [$code], calls [$(calls)], stderr [$(err)]"
fi

fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe"
[ "$code" = 0 ] && ! grep -q -- '^-s PHONE1 reverse tcp:' "$FAKE_ADB_LOG" && adb_called "$forward" &&
  adb_called "-s PHONE1 reverse --remove-all" &&
  pass "zero --reverse is allowed: earlier reversals are cleared, none is set, Chrome is still forwarded" ||
  fail "no --reverse: exit [$code], calls [$(calls)], stderr [$(err)]"

fresh_case
attach PHONE1 device
given_tabs C548EBF7B488DAD11B6E1E32B82735B5: 3275:about:blank 12:https://example.test/ 13:about:blank
device_run run -- "$tmp/probe"
if [ "$code" = 0 ] && adb_called "http /json/close/12" && adb_called "http /json/close/13" &&
  ! grep -q '^http /json/close/3275$' "$FAKE_ADB_LOG" && ! grep -q '^http /json/close/C548' "$FAKE_ADB_LOG" &&
  in_order "http /json/close/13" "the command starts"; then
  pass "leftover tabs are closed before the command starts; this run's blank tab and Chrome's hidden target are kept"
else
  fail "leftover tabs: exit [$code], calls [$(calls)], stderr [$(err)]"
fi

# Every run starts Chrome afresh, however it was left.
fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe"
first="$code"
device_run run -- "$tmp/probe"
[ "$first" = 0 ] && [ "$code" = 0 ] &&
  [ "$(grep -cx -- "$stop_chrome" "$FAKE_ADB_LOG")" = 2 ] && [ "$(grep -cx -- "$start_chrome" "$FAKE_ADB_LOG")" = 2 ] &&
  pass "every run force-stops Chrome and starts it again" ||
  fail "two runs: exits [$first] and [$code], calls [$(calls)]"

fresh_case
attach PHONE1 device
launch env BENCH_DEVICE_CHROME_SECONDS=08 "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 125 ] && said 'BENCH_DEVICE_CHROME_SECONDS must be a whole number' && adb_untouched && ! ran &&
  pass "a malformed BENCH_DEVICE_CHROME_SECONDS is a 125 refusal, before queueing" ||
  fail "BENCH_DEVICE_CHROME_SECONDS=08: exit [$code], stderr [$(err)]"

# refused_by_chrome <stderr pattern> <description>: set up by the caller.
refused_by_chrome() {
  device_run run --reverse 8080 -- "$tmp/probe"
  if [ "$code" = 125 ] && said "$1" && ! ran; then
    pass "$2: refused with 125: $(grep -v '^bench-lock:' "$CASE_DIR/err" | head -n 1)"
  else
    fail "$2: exit [$code], stderr [$(err)], calls [$(calls)]"
  fi
}

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/no-socket"
refused_by_chrome "Chrome's DevTools socket did not show up on PHONE1" "a DevTools socket that never shows up"
adb_called "$start_chrome" && [ "$(grep -c -- "^$read_sockets\$" "$FAKE_ADB_LOG")" -gt 1 ] &&
  pass "the socket is waited for, a bounded time, before the refusal" ||
  fail "the socket wait: [$(calls)]"

fresh_case
attach PHONE1 device
rm "$FAKE_ADB_DIR/version.json"
refused_by_chrome "Chrome's DevTools on PHONE1 does not answer" "a DevTools endpoint that never answers"

fresh_case
attach PHONE1 device
given_tabs 12:https://example.test/
refused_by_chrome "no blank tab" "a Chrome without the blank tab it was started on"

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/reverse.fails"
refused_by_chrome "cannot reverse port 8080 to PHONE1" "a reversal that cannot be set"

# ── A cool phone ─────────────────────────────────────────────────────────────
read_thermal="-s PHONE1 shell dumpsys thermalservice"
thermal_reads() { grep -cx -- "$read_thermal" "$FAKE_ADB_LOG"; }
# given_thermal <status>...: what the successive readings say.
given_thermal() { printf '%s\n' "$@" >"$FAKE_ADB_DIR/thermal"; }
waiting_lines() { grep -c '^bench-device: waiting for PHONE1 to cool' "$CASE_DIR/err"; }
# Stderr up to bench-lock's end-of-run line, which lands once the command is over.
before_the_end() { grep -v '^bench-lock: on [^,]*, during the run, ' "$CASE_DIR/err"; }
# The device verdict: the last line on stderr before it, the wrapped command
# saying nothing there.
verdict() { before_the_end | tail -n 1; }

fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe"
if [ "$code" = 0 ] && [ "$(waiting_lines)" = 0 ] &&
  in_order "-s PHONE1 shell dumpsys window" "$read_thermal" "$stop_chrome"; then
  pass "a cool phone: its thermal status is read after the readiness checks, before Chrome restarts, and nothing waits"
else
  fail "a cool phone: exit [$code], calls [$(calls)], stderr [$(err)]"
fi

fresh_case
attach PHONE1 device
given_thermal 3 2 1 0
launch env BENCH_DEVICE_THERMAL_SECONDS=30 "$tool" run -- "$tmp/probe" 8
collect "$pid"
if [ "$code" = 8 ] && ran_with PHONE1 && [ "$(thermal_reads)" -ge 4 ] &&
  said '^bench-device: waiting for PHONE1 to cool: thermal status severe' &&
  sed -n 2p "$CASE_DIR/err" | grep -q '^bench-device: waiting for PHONE1 to cool'; then
  pass "a phone that cools after a few polls: the waiting line at once, then the command, well before the bound"
else
  fail "a phone that cools: exit [$code], thermal reads [$(thermal_reads)], stderr [$(err)]"
fi
said 'waiting for PHONE1 to cool: thermal status moderate' && said 'waiting for PHONE1 to cool: thermal status light' &&
  pass "the waiting line comes back on every poll, naming the current thermal status" ||
  fail "the periodic waiting line: [$(err)]"
verdict | grep -q 'thermal status none,' && ! said 'expired' &&
  pass "once cool, the verdict says thermal status none, and no bound expired" ||
  fail "the verdict after cooling: [$(verdict)]"

fresh_case
attach PHONE1 device
given_thermal 2
device_run run -- "$tmp/probe" 9
if [ "$code" = 9 ] && ran_with PHONE1 && [ "$(waiting_lines)" -ge 3 ] &&
  verdict | grep -q 'thermal status moderate (still not none when the 2s wait ran out)'; then
  pass "a phone that never cools: the command starts once the bound expires, with its exit code, and the verdict says so"
else
  fail "a phone that never cools: exit [$code], stderr [$(err)]"
fi

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/thermal.fails"
device_run run -- "$tmp/probe" 0
[ "$code" = 0 ] && [ "$(thermal_reads)" -le 2 ] && [ "$(waiting_lines)" = 0 ] &&
  verdict | grep -q 'thermal status unknown,' &&
  pass "an unreadable thermal status is not waited on, and reads unknown" ||
  fail "an unreadable thermal status: exit [$code], thermal reads [$(thermal_reads)], stderr [$(err)]"

# ── The device verdict ───────────────────────────────────────────────────────
fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe" 0
expected="bench-device: on Pixel 5 (PHONE1): thermal status none, battery temperature 25.1 C, battery health good, Chrome 156.0.8078.79"
if [ "$code" = 0 ] && [ "$(verdict)" = "$expected" ] &&
  [ "$(grep -c '^bench-device: on ' "$CASE_DIR/err")" = 1 ] &&
  [ "$(before_the_end | tail -n 2 | head -n 1 | cut -c 1-14)" = "bench-lock: on" ]; then
  pass "one device verdict line, right after the lock's calm verdict: $(verdict)"
else
  fail "the verdict: exit [$code], stderr [$(err)]"
fi
in_order "$wake" "-s PHONE1 shell dumpsys battery" "the command starts" &&
  in_order "-s PHONE1 shell getprop ro.product.model" "the command starts" &&
  pass "the verdict is read just before the command starts" ||
  fail "the verdict readings: [$(calls)]"

# ── The settle ───────────────────────────────────────────────────────────────
# The `bench-lock` on PATH, wrapped: it logs how it is called to the call log,
# then becomes the real one, so that the pid of every caller is kept.
mkdir "$tmp/logged"
cat >"$tmp/logged/bench-lock" <<EOF
#!/bin/sh
echo "bench-lock \$*" >>"\$FAKE_ADB_LOG"
exec "$lock_tool" "\$@"
EOF
chmod +x "$tmp/logged/bench-lock"
# The command, here: the end-of-run window token `bench-lock settle` leaves
# when called by the lock's holder, which names that holder first. The command
# is the holder, since `bench-device` became it.
cat >"$tmp/window-probe" <<'EOF'
#!/bin/sh
echo "the command starts" >>"$FAKE_ADB_LOG"
token=""
{ read -r token <"$XDG_STATE_HOME/bench-lock/lock/window"; } 2>/dev/null
case "$token" in "$$ "*) echo holder >"$CASE_DIR/window" ;; *) echo "[$token]" >"$CASE_DIR/window" ;; esac
exit 0
EOF
chmod +x "$tmp/window-probe"

fresh_case
attach PHONE1 device
launch env PATH="$tmp/logged:$PATH" "$tool" run -- "$tmp/window-probe"
collect "$pid"
[ "$code" = 0 ] && in_order "$wake" "bench-lock settle" "-s PHONE1 shell getprop ro.product.model" "the command starts" &&
  [ "$(grep -cx 'bench-lock settle' "$FAKE_ADB_LOG")" = 1 ] &&
  pass "bench-lock settle is called once, after the device is ready and before the command" ||
  fail "the settle: exit [$code], calls [$(calls)], stderr [$(err)]"
[ "$(cat "$CASE_DIR/window" 2>/dev/null)" = holder ] &&
  pass "the settle comes from the lock's holder, so the end-of-run window starts over there" ||
  fail "the window token: [$(cat "$CASE_DIR/window" 2>/dev/null)], stderr [$(err)]"

# Under an outer holder, the settle still happens, and marks nothing.
fresh_case
attach PHONE1 device
hold_lock
launch env BENCH_LOCK_HELD=1 PATH="$tmp/logged:$PATH" "$tool" run -- "$tmp/window-probe"
collect "$pid"
[ "$code" = 0 ] && in_order "$wake" "bench-lock settle" "the command starts" &&
  [ "$(cat "$CASE_DIR/window" 2>/dev/null)" = "[]" ] &&
  pass "under BENCH_LOCK_HELD, bench-lock settle is called and leaves no window token" ||
  fail "the settle under an outer holder: exit [$code], calls [$(calls)], window [$(cat "$CASE_DIR/window" 2>/dev/null)], stderr [$(err)]"
release holder

fresh_case
attach PHONE1 device
printf '  health: 3\n  temperature: 412\n' >"$FAKE_ADB_DIR/battery"
device_run run -- "$tmp/probe" 2
[ "$code" = 2 ] && verdict | grep -q 'battery temperature 41.2 C, battery health overheat (not good), Chrome' &&
  pass "a battery health other than good is flagged, and the exit code is the command's" ||
  fail "a degraded battery: exit [$code], verdict [$(verdict)]"

fresh_case
attach PHONE1 device
printf '  health: 7\n  temperature: -5\n' >"$FAKE_ADB_DIR/battery"
device_run run -- "$tmp/probe" 0
[ "$code" = 0 ] && verdict | grep -q 'battery temperature -0.5 C, battery health cold (not good)' &&
  pass "a temperature below zero reads as such" ||
  fail "a cold battery: exit [$code], verdict [$(verdict)]"

fresh_case
attach PHONE1 device
rm "$FAKE_ADB_DIR/model" "$FAKE_ADB_DIR/thermal"
: >"$FAKE_ADB_DIR/battery.fails"
printf '{\n   "Protocol-Version": "1.3"\n}\n' >"$FAKE_ADB_DIR/version.json"
device_run run -- "$tmp/probe" 6
expected="bench-device: on an unknown model (PHONE1): thermal status unknown, battery temperature unknown, battery health unknown, Chrome unknown"
[ "$code" = 6 ] && [ "$(verdict)" = "$expected" ] &&
  pass "readings that fail print as unknown and never fail the run" ||
  fail "unknown readings: exit [$code], verdict [$(verdict)], stderr [$(err)]"

fresh_case
attach PHONE1 device
printf '  health: 2\n' >"$FAKE_ADB_DIR/battery"
given_thermal 9
device_run run -- "$tmp/probe" 0
[ "$code" = 0 ] && verdict | grep -q 'thermal status 9 (still not none when the 2s wait ran out), battery temperature unknown, battery health good' &&
  pass "a thermal status with no known name prints its number" ||
  fail "an unnamed thermal status: exit [$code], verdict [$(verdict)]"

# refused_tunable <variable> <value>
refused_tunable() {
  fresh_case
  attach PHONE1 device
  launch env "$1=$2" "$tool" run -- "$tmp/probe"
  collect "$pid"
  [ "$code" = 125 ] && said "$1 must be" && adb_untouched && ! ran &&
    pass "$1=$2 is a 125 refusal, before queueing" ||
    fail "$1=$2: exit [$code], stderr [$(err)]"
}
refused_tunable BENCH_DEVICE_THERMAL_SECONDS 1.5
refused_tunable BENCH_DEVICE_THERMAL_SECONDS 08
refused_tunable BENCH_DEVICE_THERMAL_POLL_SECONDS 0
refused_tunable BENCH_DEVICE_THERMAL_POLL_SECONDS abc

fresh_case
attach PHONE1 device
given_thermal 4
launch env BENCH_DEVICE_THERMAL_SECONDS=0 "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 0 ] && [ "$(thermal_reads)" = 2 ] && verdict | grep -q 'thermal status critical (still not none when the 0s wait ran out)' &&
  pass "BENCH_DEVICE_THERMAL_SECONDS=0 reads the status once and does not wait" ||
  fail "no thermal wait: exit [$code], thermal reads [$(thermal_reads)], stderr [$(err)]"

# ── Lock first ───────────────────────────────────────────────────────────────
# Behind a held lock the run waits in the queue, and talks to no device until
# it holds the lock.
fresh_case
attach PHONE1 device
hold_lock
launch "$tool" run -- "$tmp/probe" 4
waiter=$pid
wait_for waiting_in_status "$waiter" &&
  pass "behind a held lock, the run queues as an ordinary bench-lock waiter" ||
  fail "the run never showed up as a waiter: [$("$lock_tool" status 2>&1)]"
# Longer than one poll of the lock, so "has not started" is not a race it won.
sleep 0.6
if adb_untouched && ! ran; then
  pass "while it waits, no device step happens and the command does not run"
else
  fail "while waiting: adb log [$(tr '\n' ' ' <"$FAKE_ADB_LOG")], command ran: $(ran && echo yes || echo no)"
fi
release holder
collect "$waiter"
[ "$code" = 4 ] && ran_with PHONE1 && adb_called devices &&
  pass "once the lock is free, the device is checked and the command runs" ||
  fail "after the release: exit [$code], stderr [$(err)]"

# Under a held lock (a repo shim or bench-remote took it), the run proceeds at
# once, whoever holds the machine's lock.
fresh_case
attach PHONE1 device
hold_lock
launch env BENCH_LOCK_HELD=1 "$tool" run -- "$tmp/probe" 5
collect "$pid"
[ "$code" = 5 ] && ran_with PHONE1 &&
  pass "under BENCH_LOCK_HELD, the run proceeds at once" ||
  fail "under BENCH_LOCK_HELD: exit [$code], stderr [$(err)]"
release holder

# ── Signals during the lock wait ─────────────────────────────────────────────
# signal_during_the_wait <signal> <expected exit code>
signal_during_the_wait() {
  fresh_case
  attach PHONE1 device
  hold_lock
  launch "$tool" run -- "$tmp/probe"
  waiter=$pid
  wait_for waiting_in_status "$waiter" || fail "the run never queued"
  kill "-$1" -- "-$waiter"
  collect "$waiter"
  if [ "$code" = "$2" ] && ! "$lock_tool" status | grep -q '^waiter' && adb_untouched && ! ran; then
    pass "$1 during the lock wait leaves the queue and exits $2, before any device step"
  else
    fail "$1 during the wait: exit [$code], status [$("$lock_tool" status 2>&1)], adb log [$(tr '\n' ' ' <"$FAKE_ADB_LOG")]"
  fi
  release holder
}
signal_during_the_wait INT 130
signal_during_the_wait TERM 143

# signal_while_cooling <signal> <expected exit code>: the lock is taken, the
# phone stays hot.
cooling() { grep -q '^bench-device: waiting for PHONE1 to cool' "$CASE_DIR/err"; }
signal_while_cooling() {
  fresh_case
  attach PHONE1 device
  given_thermal 3
  launch env BENCH_DEVICE_THERMAL_SECONDS=30 "$tool" run -- "$tmp/probe"
  wait_for cooling || fail "the run never waited for the phone to cool: [$(err)]"
  kill "-$1" -- "-$pid"
  collect "$pid"
  if [ "$code" = "$2" ] && "$lock_tool" status | grep -q '^free:' && ! ran && ! adb_called "$stop_chrome"; then
    pass "$1 during the thermal wait exits $2 and gives the lock back, before Chrome is touched"
  else
    fail "$1 during the thermal wait: exit [$code], status [$("$lock_tool" status 2>&1)], calls [$(calls)]"
  fi
}
signal_while_cooling INT 130
signal_while_cooling TERM 143

# A signal to the run alone, not its process group, ends the wait at once too,
# and does not wait for the poll in progress to end.
fresh_case
attach PHONE1 device
given_thermal 3
launch env BENCH_DEVICE_THERMAL_SECONDS=30 BENCH_DEVICE_THERMAL_POLL_SECONDS=20 "$tool" run -- "$tmp/probe"
wait_for cooling || fail "the run never waited for the phone to cool: [$(err)]"
holder="$("$lock_tool" status | sed -n 's/^holder: pid \([0-9]*\),.*/\1/p')"
kill -INT "$holder"
collect "$pid"
if [ "$code" = 130 ] && "$lock_tool" status | grep -q '^free:' && ! ran; then
  pass "INT to the run alone, mid-poll, exits 130 at once and gives the lock back"
else
  fail "INT to the run alone: holder [$holder], exit [$code], status [$("$lock_tool" status 2>&1)]"
fi

# A phone that cools between the end of the wait and the verdict: the verdict
# says both.
fresh_case
attach PHONE1 device
given_thermal 2 0
launch env BENCH_DEVICE_THERMAL_SECONDS=0 "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 0 ] && verdict | grep -q 'thermal status none (was moderate when the 0s wait ran out),' &&
  pass "a phone that cooled after the wait ran out: the verdict says what it was then" ||
  fail "cooled after the wait: exit [$code], verdict [$(verdict)]"

# ── Refused before queueing ──────────────────────────────────────────────────
# Usage errors and a command that cannot run come back at once, even behind a
# held lock: a typo never waits for its turn, and never reaches a device.
fresh_case
attach PHONE1 device
hold_lock
: >"$tmp/not-executable"
# refused_at_once <expected code> <stderr pattern> <arguments...>
refused_at_once() {
  local expected="$1" pattern="$2"
  shift 2
  device_run "$@"
  if [ "$code" = "$expected" ] && said "$pattern" && adb_untouched && ! ran; then
    pass "\`bench-device $*\` exits $expected at once: $(head -n 1 "$CASE_DIR/err")"
  else
    fail "\`bench-device $*\` exited [$code]: [$(err)]"
  fi
}
refused_at_once 125 'Usage:'
refused_at_once 125 'Usage:' nope
refused_at_once 125 'Usage:' run
refused_at_once 125 'Usage:' run --
refused_at_once 125 'Usage:' run "$tmp/probe"
refused_at_once 125 'Usage:' run --serial
refused_at_once 125 'Usage:' run --serial -- "$tmp/probe"
refused_at_once 125 'Usage:' run --serial "" -- "$tmp/probe"
refused_at_once 125 'Usage:' run --serial A --serial B -- "$tmp/probe"
refused_at_once 125 'Usage:' run --reverse -- "$tmp/probe"
refused_at_once 125 'Usage:' run --bogus -- "$tmp/probe"
for port in abc 0 65536 080 -1 99999999999999999999; do
  refused_at_once 125 "--reverse: $port is not a port" run --reverse "$port" -- "$tmp/probe"
done
refused_at_once 127 'no-such-command: No such file or directory' run -- "$tmp/no-such-command"
refused_at_once 127 'no-such-command-on-path: command not found' run -- no-such-command-on-path
refused_at_once 126 'not-executable: Permission denied' run -- "$tmp/not-executable"
refused_at_once 126 ': Is a directory' run -- "$tmp"
release holder

# ── adb itself ───────────────────────────────────────────────────────────────
fresh_case
attach PHONE1 device
no_adb_path="$here/bin:/usr/bin:/bin"
if PATH="$no_adb_path" type -P adb >/dev/null; then
  echo "  skip adb missing from PATH: this machine has adb in /usr/bin or /bin"
else
  launch env -u BENCH_DEVICE_ADB PATH="$no_adb_path" "$tool" run -- "$tmp/probe"
  collect "$pid"
  [ "$code" = 125 ] && said "adb not found on PATH \($no_adb_path\)" && ! ran &&
    pass "adb missing from PATH is a 125 refusal naming PATH" ||
    fail "without adb: exit [$code], stderr [$(err)]"
fi

fresh_case
launch env BENCH_DEVICE_ADB="$tmp/no-such-adb" "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 125 ] && said "BENCH_DEVICE_ADB" && ! ran &&
  pass "a BENCH_DEVICE_ADB that is not an executable is a 125 refusal" ||
  fail "with a missing BENCH_DEVICE_ADB: exit [$code], stderr [$(err)]"

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/devices.fails"
device_run run -- "$tmp/probe"
[ "$code" = 125 ] && said 'adb devices' && ! ran &&
  pass "adb failing to list the devices is a 125 refusal" ||
  fail "with adb devices failing: exit [$code], stderr [$(err)]"

fresh_case
attach PHONE1 device
launch env PATH=/usr/bin:/bin "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 125 ] && said 'bench-lock not found on PATH \(/usr/bin:/bin\)' && adb_untouched && ! ran &&
  pass "bench-lock missing from PATH is a 125 refusal naming PATH, before any device step" ||
  fail "without bench-lock: exit [$code], stderr [$(err)]"

# Without curl, the DevTools endpoint cannot be spoken to. curl lives in
# /usr/bin, so this PATH holds bash alone, for the first line of the file.
fresh_case
attach PHONE1 device
mkdir -p "$tmp/no-curl-bin"
ln -sf "$(type -P bash)" "$tmp/no-curl-bin/bash"
launch env PATH="$tmp/no-curl-bin" "$tool" run -- "$tmp/probe"
collect "$pid"
[ "$code" = 125 ] && said "curl not found on PATH \($tmp/no-curl-bin\)" && adb_untouched && ! ran &&
  pass "curl missing from PATH is a 125 refusal naming PATH, before any device step" ||
  fail "without curl: exit [$code], stderr [$(err)]"

# ── Refused devices ──────────────────────────────────────────────────────────
# Each refusal names its cause, exits 125, and the command never runs: a device
# run never falls back to anything.
# refused <stderr pattern> <description> <bench-device arguments...>
refused() {
  local pattern="$1" description="$2"
  shift 2
  device_run "$@" "$tmp/probe"
  if [ "$code" = 125 ] && said "$pattern" && ! ran && ! grep -q 'chrome' "$FAKE_ADB_LOG"; then
    pass "$description: refused with 125, Chrome untouched: $(grep -v '^bench-lock:' "$CASE_DIR/err" | head -n 1)"
  else
    fail "$description: exit [$code], stderr [$(err)], calls [$(calls)]"
  fi
}

fresh_case
refused 'no device attached' "no device" run --

fresh_case
attach PHONE1 device
attach PHONE2 unauthorized
refused 'several devices.*PHONE1 \(device\).*PHONE2 \(unauthorized\).*--serial' \
  "several devices without --serial" run --

fresh_case
attach PHONE1 device
attach PHONE2 offline
refused 'PHONE3 is not attached.*PHONE1 \(device\).*PHONE2 \(offline\)' \
  "an unknown serial" run --serial PHONE3 --

fresh_case
attach PHONE1 unauthorized
refused 'PHONE1.*not authorized' "an unauthorized device" run --

fresh_case
attach PHONE1 offline
refused 'PHONE1 is offline' "an offline device" run --

fresh_case
attach PHONE1 device
attach PHONE2 offline
refused 'PHONE2 is offline' "an offline device named by --serial" run --serial PHONE2 --

fresh_case
attach PHONE1 recovery
refused "PHONE1 is in state 'recovery'" "a device in another state" run --

fresh_case
attach PHONE1 device Asleep
refused 'screen of PHONE1 is off \(Asleep\)' "a screen off" run --

fresh_case
attach PHONE1 device Dozing
refused 'screen of PHONE1 is off \(Dozing\)' "a dozing screen" run --

fresh_case
attach PHONE1 device Awake true
refused 'keyguard is showing on PHONE1' "a keyguard showing" run --

fresh_case
attach PHONE1 device
rm "$FAKE_ADB_DIR/wakefulness.PHONE1"
refused 'cannot tell whether the screen of PHONE1 is awake' "an unreadable wakefulness" run --

fresh_case
attach PHONE1 device
rm "$FAKE_ADB_DIR/keyguard.PHONE1"
refused 'cannot tell whether the keyguard is showing on PHONE1' "an unreadable keyguard" run --

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/power.fails"
refused 'cannot read the power state of PHONE1' "dumpsys power failing" run --

fresh_case
attach PHONE1 device
: >"$FAKE_ADB_DIR/window.fails"
refused 'cannot read the window state of PHONE1' "dumpsys window failing" run --

# Readiness is re-checked on every run: a device that was fine a run ago and
# went to sleep since is refused.
fresh_case
attach PHONE1 device
device_run run -- "$tmp/probe"
first="$code"
rm -f "$CASE_DIR/ran"
printf 'Asleep\n' >"$FAKE_ADB_DIR/wakefulness.PHONE1"
device_run run -- "$tmp/probe"
[ "$first" = 0 ] && [ "$code" = 125 ] && ! ran &&
  [ "$(grep -cx -- '-s PHONE1 shell dumpsys power' "$FAKE_ADB_LOG")" = 2 ] &&
  pass "readiness is read again on every run" ||
  fail "two runs: first [$first], second [$code], adb log [$(tr '\n' ' ' <"$FAKE_ADB_LOG")]"

# ── An old bash ──────────────────────────────────────────────────────────────
# `bench-device` must work under the old bash macOS ships as /bin/bash. The
# bash on PATH is usually a recent one, so the parsing, the selection and a
# refusal run once more through the system's old one, where there is one.
# Under BENCH_LOCK_HELD, so that no re-launch hands the file back to the bash
# its first line names.
bash_major() { "$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null; }
if [ "$(bash_major /bin/bash)" -lt 5 ] 2>/dev/null; then
  fresh_case
  attach PHONE1 device
  attach PHONE2 device
  device_run_old() {
    launch env BENCH_LOCK_HELD=1 /bin/bash "$tool" "$@"
    collect "$pid"
  }
  device_run_old run --reverse 8080 --serial PHONE2 -- "$tmp/probe" 6
  first="$code"
  ran_with PHONE2 || first="ran on [$(cat "$CASE_DIR/ran" 2>/dev/null)]"
  rm -f "$CASE_DIR/ran"
  printf '2\n0\n' >"$FAKE_ADB_DIR/thermal"
  device_run_old run --serial PHONE1 -- "$tmp/probe" 7
  if [ "$first" = 6 ] && [ "$code" = 7 ] && ran_with PHONE1 && said 'waiting for PHONE1 to cool: thermal status moderate' &&
    [ "$(verdict)" = "bench-device: on Pixel 5 (PHONE1): thermal status none, battery temperature 25.1 C, battery health good, Chrome 156.0.8078.79" ]; then
    pass "through /bin/bash $(bash_major /bin/bash): a hot phone is waited for, and the verdict reads the same"
  else
    fail "through /bin/bash, a hot phone: exits [$first] and [$code], stderr [$(err)]"
  fi
  device_run_old run -- "$tmp/probe"
  if [ "$first" = 6 ] && [ "$code" = 125 ] && said 'several devices attached'; then
    pass "through /bin/bash $(bash_major /bin/bash): a ready device runs, and several are refused"
  else
    fail "through /bin/bash: exits [$first] and [$code], stderr [$(err)]"
  fi
else
  echo "  skip the cases through an old bash: /bin/bash is not one"
fi

if [ "$fails" -eq 0 ]; then
  echo "bench-device: all pass"
else
  echo "bench-device: $fails failure(s)"
fi
exit "$((fails > 0))"
