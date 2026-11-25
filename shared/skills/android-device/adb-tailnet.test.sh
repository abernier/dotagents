#!/usr/bin/env bash
# adb-tailnet.test.sh: behavioural tests for bin/adb-tailnet.
#
# No phone and no network here. adb, the Tailscale CLI and the port scanner
# are fakes, through ADB_TAILNET_ADB, ADB_TAILNET_TAILSCALE and
# ADB_TAILNET_SCANNER: they answer from the current case's fixtures and log
# every call. Every case launches the real executable as a process and
# asserts only on what a caller can observe: exit code, stdout, stderr and
# the call log.
set -u
exec </dev/null
unset ADB_TAILNET_ADB ADB_TAILNET_TAILSCALE ADB_TAILNET_SCANNER
export ADB_TAILNET_SETTLE_SECONDS=0

here="$(cd "$(dirname "$0")" && pwd -P)"
tool="$here/bin/adb-tailnet"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  fails=$((fails + 1))
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# ── The fakes ────────────────────────────────────────────────────────────────
# adb answers from $FAKE_DIR:
#
#   devices       the lines `adb devices` lists, "<serial>\t<state>"
#   port.<port>   the state a serial on that port comes up in once connected
#                 (device, offline); absent: the connection fails
#
# `adb connect` adds the serial to devices, `adb disconnect` removes it.
cat >"$tmp/adb" <<'EOF'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  devices)
    printf 'List of devices attached\r\n'
    [ ! -f "$FAKE_DIR/devices" ] || sed 's/$/\r/' "$FAKE_DIR/devices"
    printf '\r\n'
    ;;
  connect)
    port="${2##*:}"
    [ -f "$FAKE_DIR/port.$port" ] || { echo "failed to connect to $2"; exit 1; }
    printf '%s\t%s\n' "$2" "$(cat "$FAKE_DIR/port.$port")" >>"$FAKE_DIR/devices"
    echo "connected to $2"
    ;;
  disconnect)
    grep -v "^$2	" "$FAKE_DIR/devices" >"$FAKE_DIR/devices.new"
    mv "$FAKE_DIR/devices.new" "$FAKE_DIR/devices"
    ;;
  *) echo "fake adb: unexpected call: $*" >&2; exit 1 ;;
esac
EOF

# tailscale resolves the names listed in $FAKE_DIR/names, "<name> <ip>".
cat >"$tmp/tailscale" <<'EOF'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >>"$FAKE_LOG"
[ "$1 $2" = "ip -4" ] || { echo "fake tailscale: unexpected call: $*" >&2; exit 1; }
ip="$(awk -v name="$3" '$1 == name { print $2 }' "$FAKE_DIR/names" 2>/dev/null)"
[ -n "$ip" ] || { echo "no such host" >&2; exit 1; }
echo "$ip"
EOF

# The scanner prints $FAKE_DIR/open, one port per line.
cat >"$tmp/scanner" <<'EOF'
#!/usr/bin/env bash
printf 'scan %s\n' "$*" >>"$FAKE_LOG"
[ ! -f "$FAKE_DIR/open" ] || cat "$FAKE_DIR/open"
EOF
chmod +x "$tmp/adb" "$tmp/tailscale" "$tmp/scanner"

# A fresh case: empty fixtures and log, the fakes in place.
case_dir=""
new_case() {
  case_dir="$(mktemp -d "$tmp/case.XXXXXX")"
  export FAKE_DIR="$case_dir" FAKE_LOG="$case_dir/log"
  : >"$FAKE_LOG"
  export ADB_TAILNET_ADB="$tmp/adb" ADB_TAILNET_TAILSCALE="$tmp/tailscale" ADB_TAILNET_SCANNER="$tmp/scanner"
}

# Runs the tool; sets status, out and err.
status=0 out="" err=""
run() {
  "$tool" "$@" >"$case_dir/out" 2>"$case_dir/err"
  status=$?
  out="$(cat "$case_dir/out")"
  err="$(cat "$case_dir/err")"
}

logged() { grep -qxF -- "$1" "$FAKE_LOG"; }

echo "adb-tailnet"

# ── Arguments ────────────────────────────────────────────────────────────────
new_case
run --help
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^Usage: adb-tailnet connect <host>' && [ ! -s "$FAKE_LOG" ]; then
  pass "--help prints the usage on stdout and touches nothing"
else
  fail "--help: status $status, out: $out"
fi

for args in "" "frobnicate" "connect" "connect phone extra"; do
  new_case
  # shellcheck disable=SC2086
  run $args
  if [ "$status" -eq 2 ] && printf '%s' "$err" | grep -q '^Usage:' && [ ! -s "$FAKE_LOG" ]; then
    pass "'$args' is a usage error, exit 2, before any call"
  else
    fail "'$args': status $status, err: $err"
  fi
done

# ── Resolution ───────────────────────────────────────────────────────────────
new_case
echo "phone 100.64.0.7" >"$FAKE_DIR/names"
echo 40123 >"$FAKE_DIR/open"
echo device >"$FAKE_DIR/port.40123"
run connect phone
if [ "$status" -eq 0 ] && [ "$out" = 100.64.0.7:40123 ] && logged "tailscale ip -4 phone" && logged "scan 100.64.0.7"; then
  pass "a name is resolved through tailscale ip -4, and the address scanned"
else
  fail "name resolution: status $status, out: $out, err: $err"
fi

new_case
echo 40123 >"$FAKE_DIR/open"
echo device >"$FAKE_DIR/port.40123"
run connect 100.64.0.9
if [ "$status" -eq 0 ] && [ "$out" = 100.64.0.9:40123 ] && ! grep -q '^tailscale' "$FAKE_LOG"; then
  pass "an IPv4 address is used as is"
else
  fail "IPv4 address: status $status, out: $out, err: $err"
fi

new_case
echo 40123 >"$FAKE_DIR/open"
echo device >"$FAKE_DIR/port.40123"
run connect fd7a:115c:a1e0::7
if [ "$status" -eq 0 ] && [ "$out" = "[fd7a:115c:a1e0::7]:40123" ] && ! grep -q '^tailscale' "$FAKE_LOG"; then
  pass "an IPv6 address is used as is, bracketed in the serial"
else
  fail "IPv6 address: status $status, out: $out, err: $err"
fi

new_case
run connect nowhere
if [ "$status" -eq 1 ] && printf '%s' "$err" | grep -q 'cannot resolve nowhere' && ! grep -q '^scan' "$FAKE_LOG"; then
  pass "a name tailscale cannot resolve fails before any scan"
else
  fail "unresolved name: status $status, err: $err"
fi

# ── Connection ───────────────────────────────────────────────────────────────
new_case
printf '100.64.0.9:41000\tdevice\n' >"$FAKE_DIR/devices"
run connect 100.64.0.9
if [ "$status" -eq 0 ] && [ "$out" = 100.64.0.9:41000 ] && ! grep -q '^scan' "$FAKE_LOG"; then
  pass "a phone already connected is printed without a scan"
else
  fail "already connected: status $status, out: $out, err: $err"
fi

new_case
printf '%s\n' 5000 40123 45000 >"$FAKE_DIR/open"
echo offline >"$FAKE_DIR/port.40123"
echo device >"$FAKE_DIR/port.45000"
run connect 100.64.0.9
if [ "$status" -eq 0 ] && [ "$out" = 100.64.0.9:45000 ] &&
  logged "adb disconnect 100.64.0.9:40123" &&
  ! grep -q '100.64.0.9:40123' "$FAKE_DIR/devices"; then
  pass "a port that comes up offline is disconnected, and the next one tried"
else
  fail "offline then device: status $status, out: $out, err: $err"
fi

new_case
printf '%s\n' 40123 45000 >"$FAKE_DIR/open"
echo device >"$FAKE_DIR/port.40123"
echo device >"$FAKE_DIR/port.45000"
run connect 100.64.0.9
if [ "$status" -eq 0 ] && [ "$out" = 100.64.0.9:40123 ] && ! logged "adb connect 100.64.0.9:45000"; then
  pass "the first port listed as device wins, and the scan of ports stops there"
else
  fail "first device: status $status, out: $out, err: $err"
fi

new_case
printf '%s\n' 40123 >"$FAKE_DIR/open"
echo offline >"$FAKE_DIR/port.40123"
run connect 100.64.0.9
if [ "$status" -eq 1 ] && [ -z "$out" ] && printf '%s' "$err" | grep -q 'not paired' &&
  printf '%s' "$err" | grep -q 'adb pair'; then
  pass "offline ports and no device: exit 1, likely not paired, pointing to adb pair"
else
  fail "not paired: status $status, out: $out, err: $err"
fi

new_case
run connect 100.64.0.9
if [ "$status" -eq 1 ] && printf '%s' "$err" | grep -q 'no open port'; then
  pass "no open port: exit 1, saying so"
else
  fail "no open port: status $status, err: $err"
fi

new_case
echo 5000 >"$FAKE_DIR/open"
run connect 100.64.0.9
if [ "$status" -eq 1 ] && printf '%s' "$err" | grep -q 'answered as an adb device' &&
  ! printf '%s' "$err" | grep -q 'not paired'; then
  pass "open ports that adb cannot connect to: exit 1, no pairing advice"
else
  fail "no adb port: status $status, err: $err"
fi

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
