#!/usr/bin/env bash
# bench-remote.test.sh: behavioural tests for bin/bench-remote.
#
# No host is ever real here. ssh is BENCH_REMOTE_SSH, pointing at a fake that
# runs the would-be remote command locally, with a minimal environment whose
# HOME is a temporary "remote home". "GitHub" is a local bare repository. Every
# case launches the real executable as a process and asserts on what a caller
# can observe: exit codes, stdout and stderr, and the run's log and exit code
# on the worker.
set -u

# Job control, so that a backgrounded `bench-remote` is its own process group,
# the way a command typed at a terminal is.
set -m
exec </dev/null

# A run of this suite under a held bench lock must not change what it proves.
unset BENCH_LOCK_HELD BENCH_LOCK_NOTICE_SECONDS

here="$(cd "$(dirname "$0")" && pwd -P)"
tool="$here/bin/bench-remote"

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  fails=$((fails + 1))
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  local leader
  for leader in $(jobs -p); do kill -TERM -- "-$leader" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

# The caller's side: its own HOME and no system or user git configuration, so
# that nothing here reads or writes the real home.
export HOME="$tmp/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=bench GIT_AUTHOR_EMAIL=bench@example.invalid
export GIT_COMMITTER_NAME=bench GIT_COMMITTER_EMAIL=bench@example.invalid
git_bin_dir="$(dirname "$(command -v git)")"

# ── The fake ssh ─────────────────────────────────────────────────────────────
# Logs every call, then runs the command the way sshd does: through a shell,
# in an environment that carries nothing from the caller but what a worker
# has, a minimal PATH included. Like a chatty shell startup file, it prints a
# line on stdout first: nothing may depend on parsing what ssh prints.
#
# FAKE_SSH_DROP names a file: once it exists, the connection "drops", the
# remote command is killed and ssh exits 255, as a real one does, and every
# later connection fails before running anything, as one to a host with no
# route does. With FAKE_SSH_DROP_ONCE set, the drop removes the file: the
# connection after it goes through again.
#
# FAKE_SSH_FAULTS names a file of one-shot faults, one per line,
# `<fault> <pattern>`: the first line whose shell pattern matches a call's
# command is removed and applied to that call.
#
#   refuse               the connection fails: nothing runs, ssh exits 255
#   drop-after           the command runs to its end, then the connection
#                        drops before ssh can report it: ssh exits 255
#   lose-launcher-after  as drop-after, the run's launcher file lost too, as if
#                        the drop had come between the nohup and its record
cat >"$tmp/ssh" <<'EOF'
#!/usr/bin/env bash
host="$1"
shift
printf '%s\t%s\n' "$host" "$*" >>"$FAKE_SSH_LOG"
remote_home="$FAKE_SSH_HOMES/$host"
mkdir -p "$remote_home"
if [ -n "${FAKE_SSH_DROP:-}" ] && [ -e "$FAKE_SSH_DROP" ]; then
  echo "ssh: connect to host $host port 22: No route to host" >&2
  exit 255
fi
fault=""
if [ -n "${FAKE_SSH_FAULTS:-}" ] && [ -f "$FAKE_SSH_FAULTS" ]; then
  kept=""
  while IFS=' ' read -r kind pattern; do
    # shellcheck disable=SC2254
    if [ -z "$fault" ] && case "$*" in $pattern) true ;; *) false ;; esac; then
      fault="$kind"
    else
      kept="$kept$kind $pattern"$'\n'
    fi
  done <"$FAKE_SSH_FAULTS"
  printf '%s' "$kept" >"$FAKE_SSH_FAULTS"
fi
if [ "$fault" = refuse ]; then
  echo "ssh: connect to host $host port 22: No route to host" >&2
  exit 255
fi
echo "Welcome to $host"
env -i HOME="$remote_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin LOGNAME=bench USER=bench \
  /bin/bash -c "$*" 0<&0 &
remote=$!
while kill -0 "$remote" 2>/dev/null; do
  if [ -n "${FAKE_SSH_DROP:-}" ] && [ -e "$FAKE_SSH_DROP" ]; then
    kill -TERM "$remote" 2>/dev/null
    [ -n "${FAKE_SSH_DROP_ONCE:-}" ] && rm -f "$FAKE_SSH_DROP"
    echo "fake ssh: connection to $host closed" >&2
    exit 255
  fi
  sleep 0.1
done
wait "$remote"
code=$?
case "$fault" in
  drop-after)
    echo "fake ssh: connection to $host closed" >&2
    exit 255
    ;;
  lose-launcher-after)
    rm -f "$remote_home"/bench/logs/*/launcher
    echo "fake ssh: connection to $host closed" >&2
    exit 255
    ;;
esac
exit "$code"
EOF
chmod +x "$tmp/ssh"
export BENCH_REMOTE_SSH="$tmp/ssh"
export FAKE_SSH_LOG="$tmp/ssh.log" FAKE_SSH_HOMES="$tmp/hosts"
export FAKE_SSH_FAULTS="$tmp/ssh.faults"
: >"$FAKE_SSH_LOG"
# Every retry at once: the delays are the real ones' business, not the cases'.
export BENCH_REMOTE_RETRY_DELAYS="0 0 0"

# A worker: a home whose login profile, like the real one, prints a greeting
# on stdout and puts the toolchain on PATH. The toolchain is a fake pnpm that
# records how it was called and leaves a mark the bench can check, and a fake
# node that only knows its version.
make_worker() { # $1 = host name
  local home="$FAKE_SSH_HOMES/$1"
  mkdir -p "$home/toolchain"
  cat >"$home/toolchain/pnpm" <<'EOF'
#!/usr/bin/env bash
printf 'pnpm %s in %s, lock held: %s, node: %s\n' "$*" "$PWD" "${BENCH_LOCK_HELD:-no}" "$(node --version 2>/dev/null || echo none)" >>"$HOME/pnpm.calls"
mkdir -p node_modules
git rev-parse HEAD >node_modules/.installed-for
EOF
  chmod +x "$home/toolchain/pnpm"
  make_node "$home/toolchain" v20.0.0
  {
    echo 'echo "Last login: a while ago"'
    echo "export PATH=\"\$HOME/toolchain:$git_bin_dir:\$PATH\""
    # The worker's CPU is this machine's, busy with the suites running beside
    # this one: a real reading, or a settle wait, would only slow every case
    # down.
    echo "export BENCH_LOCK_SETTLE=0 BENCH_LOCK_CPU_PER_CORE=0.05 BENCH_LOCK_POLL_SECONDS=0.2"
  } >"$home/.bash_profile"
}

make_node() { # $1 = directory, $2 = the version it reports
  mkdir -p "$1"
  printf '#!/bin/sh\necho %s\n' "$2" >"$1/node"
  chmod +x "$1/node"
}

# nvm on a worker, as on the real one: a shell function defined by a file the
# login profile sources, whose default node then comes first on PATH. A version
# is a major (22, 24): installed under versions/, or offered for "download"
# under remote/; every download is recorded.
add_nvm() { # $1 = host name, $2 = default version, then the versions offered
  local home="$FAKE_SSH_HOMES/$1" version
  local nvm_dir="$home/.nvm"
  make_node "$nvm_dir/versions/node/v$2/bin" "v$2.0.0"
  echo "$2" >"$nvm_dir/default"
  shift 2
  for version in "$@"; do make_node "$nvm_dir/remote/v$version/bin" "v$version.0.0"; done
  cat >"$nvm_dir/nvm.sh" <<'EOF'
nvm() {
  local asked
  case "$1" in
    install)
      asked="${2:-$(cat .nvmrc)}"
      if [ ! -d "$NVM_DIR/versions/node/v$asked" ]; then
        if [ ! -d "$NVM_DIR/remote/v$asked" ]; then
          echo "Version '$asked' not found - try \`nvm ls-remote\` to browse available versions." >&2
          return 3
        fi
        echo "Downloading and installing node v$asked..."
        echo "v$asked" >>"$NVM_DIR/downloads"
        cp -R "$NVM_DIR/remote/v$asked" "$NVM_DIR/versions/node/v$asked"
      fi
      nvm use "$asked"
      ;;
    use)
      asked="${2:-$(cat .nvmrc)}"
      [ "$asked" = default ] && asked="$(cat "$NVM_DIR/default")"
      if [ ! -d "$NVM_DIR/versions/node/v$asked" ]; then
        echo "N/A: version \"v$asked\" is not yet installed." >&2
        return 3
      fi
      PATH="$NVM_DIR/versions/node/v$asked/bin:$PATH"
      echo "Now using node v$asked"
      ;;
    *) return 1 ;;
  esac
}
if [ "${1:-}" != --no-use ]; then nvm use default >/dev/null; fi
EOF
  {
    echo 'export NVM_DIR="$HOME/.nvm"'
    echo '. "$NVM_DIR/nvm.sh"'
  } >>"$home/.bash_profile"
}

# "GitHub": a bare repository, and the caller's clone of it.
origin="$tmp/github/acme/widget.git"
work="$tmp/work/widget"
git init --quiet --bare "$origin"
git init --quiet "$work"
git -C "$work" remote add origin "$origin"
printf 'lockfileVersion: 9\n' >"$work/pnpm-lock.yaml"
git -C "$work" add pnpm-lock.yaml
git -C "$work" commit --quiet -m first
git -C "$work" push --quiet origin HEAD:refs/heads/main

# The caller's bench-compare: a fake that records its arguments and the
# samples it was given in FAKE_COMPARE_DIR, prints a verdict line and exits
# FAKE_COMPARE_EXIT. fresh_compare gives it a new, empty directory.
mkdir -p "$tmp/caller-bin"
cat >"$tmp/caller-bin/bench-compare" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_COMPARE_DIR/args"
cp "${@: -2:1}" "$FAKE_COMPARE_DIR/control"
cp "${@: -1}" "$FAKE_COMPARE_DIR/experiment"
echo "fake verdict"
exit "${FAKE_COMPARE_EXIT:-0}"
EOF
chmod +x "$tmp/caller-bin/bench-compare"
compares=0
fresh_compare() {
  compares=$((compares + 1))
  export FAKE_COMPARE_DIR="$tmp/compare.$compares"
  mkdir -p "$FAKE_COMPARE_DIR"
}
fresh_compare
caller_path="$tmp/caller-bin:$PATH"
# A caller without bench-compare: git and the system's tools only.
bare_caller_path="$git_bin_dir:/usr/bin:/bin:/usr/sbin:/sbin"

# Runs bench-remote from the caller's clone, with the fake bench-compare on
# PATH (CALLER_PATH replaces that PATH); its output lands in $out and $err,
# its exit code in $code.
out="$tmp/out" err="$tmp/err" code=""
bench_remote() {
  (cd "$work" && PATH="${CALLER_PATH:-$caller_path}" "$tool" "$@") >"$out" 2>"$err"
  code=$?
}

make_worker worker

# ── A worker that has never run anything ─────────────────────────────────────
echo "status on a worker that has never run anything"
make_worker fresh
bench_remote fresh status
if [ "$code" -eq 0 ] && grep -q "no run" "$out"; then
  pass "says so and succeeds"
else
  fail "says so and succeeds (exit $code: $(cat "$out" "$err"))"
fi

# ── A run ────────────────────────────────────────────────────────────────────
# The caller's origin is GitHub over ssh, the worker's clone must be over
# HTTPS; each side's git configuration sends that URL to the bare repository.
git -C "$work" remote set-url origin git@github.com:acme/widget.git
git config --global url."$origin".insteadOf git@github.com:acme/widget.git
git config --file "$FAKE_SSH_HOMES/worker/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
worker_home="$FAKE_SSH_HOMES/worker"
checkout="$worker_home/bench/widget"

# What the bench sees: its commit, whether HEAD is detached, what the install
# step installed for, which bench-lock and bench-device it finds.
probe='echo "head=$(git rev-parse HEAD)"
git symbolic-ref -q HEAD || echo "detached"
echo "installed-for=$(cat node_modules/.installed-for)"
echo "bench-lock=$(command -v bench-lock)"
echo "bench-device=$(command -v bench-device)"
echo "lock-held=${BENCH_LOCK_HELD:-no}"
echo "node=$(node --version 2>/dev/null || echo none)"
exit "${1:-0}"'

run_id=""
find_run_id() {
  run_id="$(sed -n 's/^bench-remote: run \([^ ]*\) on .*/\1/p' "$err" | head -n 1)"
}

echo "a first run"
first="$(git -C "$work" rev-parse HEAD)"
bench_remote worker -- bash -c "$probe" probe 3
find_run_id
if [ "$code" -eq 3 ]; then
  pass "returns the job's exit code"
else
  fail "returns the job's exit code (exit $code: $(cat "$err"))"
fi
if grep -qx "head=$first" "$out" && grep -qx detached "$out"; then
  pass "runs on exactly the caller's commit, detached"
else
  fail "runs on exactly the caller's commit, detached ($(cat "$out"))"
fi
if [ "$(git -C "$checkout" config --get remote.origin.url 2>/dev/null)" = https://github.com/acme/widget.git ]; then
  pass "clones over HTTPS under the worker's bench directory"
else
  fail "clones over HTTPS under the worker's bench directory"
fi
if grep -qx "installed-for=$first" "$out" && grep -q -- "install --frozen-lockfile" "$worker_home/pnpm.calls"; then
  pass "installs the dependencies before the command runs"
else
  fail "installs the dependencies before the command runs ($(cat "$out"))"
fi
if grep -qx "bench-lock=$worker_home/bench/bin/bench-lock" "$out" &&
  cmp -s "$here/bin/bench-lock" "$worker_home/bench/bin/bench-lock" &&
  [ -x "$worker_home/bench/bin/bench-lock" ]; then
  pass "copies bench-lock and puts it first on the command's PATH"
else
  fail "copies bench-lock and puts it first on the command's PATH ($(cat "$out"))"
fi
if grep -qx "bench-device=$worker_home/bench/bin/bench-device" "$out" &&
  cmp -s "$here/bin/bench-device" "$worker_home/bench/bin/bench-device" &&
  [ -x "$worker_home/bench/bin/bench-device" ]; then
  pass "copies bench-device beside bench-lock, on the command's PATH"
else
  fail "copies bench-device beside bench-lock, on the command's PATH ($(cat "$out"))"
fi
if [ "$(grep -c '^bench-lock: on [^,]*, during the run, ' "$out")" = 1 ] &&
  grep -q '^bench-lock: on [^,]*, during the run, ' <(sed '1,/^node=/d' "$out"); then
  pass "follows the run to its end-of-run verdict, after the command's output"
else
  fail "follows the run to its end-of-run verdict, after the command's output ($(cat "$out"))"
fi
if grep -qx "lock-held=1" "$out" && grep -q -- "--frozen-lockfile in .*, lock held: 1," "$worker_home/pnpm.calls"; then
  pass "holds the worker's bench lock from the install to the end of the command"
else
  fail "holds the worker's bench lock from the install to the end of the command ($(cat "$out"))"
fi
# The fake pnpm is only on the profile's PATH: the profile did run.
if grep -qx "installed-for=$first" "$out" && [ "$code" -eq 3 ] &&
  ! grep -q "Last login" "$out" "$worker_home/bench/logs/$run_id/log"; then
  pass "is not disturbed by a login profile that prints on stdout"
else
  fail "is not disturbed by a login profile that prints on stdout"
fi
if [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-widget-[0-9a-f]{7}$ ]] &&
  grep -qx "head=$first" "$worker_home/bench/logs/$run_id/log" &&
  [ "$(cat "$worker_home/bench/logs/$run_id/exit")" = 3 ]; then
  pass "keeps its log and exit code on the worker under a dated identifier"
else
  fail "keeps its log and exit code on the worker under a dated identifier (run '$run_id')"
fi
if grep -qx "node=v20.0.0" "$out" && grep -q "node: v20.0.0$" "$worker_home/pnpm.calls" &&
  grep -q "^bench-remote: node v20.0.0" "$worker_home/bench/logs/$run_id/log"; then
  pass "without a .nvmrc, uses the login shell's node and names it in the log"
else
  fail "without a .nvmrc, uses the login shell's node and names it in the log ($(cat "$worker_home/bench/logs/$run_id/log"))"
fi
# The steps of the run, in the order the log shows them: a calm verdict before
# the fetch, and a second one after the install, just before the command.
steps="$(awk '
  /^bench-lock: on [^,]*, (cpu|load) / { print "verdict"; next }
  /^bench-remote: (cloning|fetching) / { print "fetch"; next }
  /^bench-remote: pnpm install / { print "install"; next }
  /^bench-remote: running / { print "command" }
' "$worker_home/bench/logs/$run_id/log" | tr '\n' ' ')"
if [ "$steps" = "verdict fetch install verdict command " ]; then
  pass "reads a verdict before the fetch, and another after the install, before the command"
else
  fail "reads a verdict before the fetch, and another after the install, before the command (steps: $steps)"
fi
if [ ! -e "$worker_home/bench/logs/$run_id/commit.bundle" ] &&
  grep -qx "commit_source='origin'" "$worker_home/bench/logs/$run_id/job.sh"; then
  pass "for a pushed commit, creates no bundle and fetches from origin"
else
  fail "for a pushed commit, creates no bundle and fetches from origin"
fi

echo "status and attach on a finished run"
first_run="$run_id"
bench_remote worker status
if [ "$code" -eq 0 ] && grep -Eq "^$first_run +exit 3 +bash -c " "$out"; then
  pass "status lists the run with its identifier, its exit code and its command"
else
  fail "status lists the run with its identifier, its exit code and its command (exit $code: $(cat "$out" "$err"))"
fi
bench_remote worker attach "$first_run"
if [ "$code" -eq 3 ] && grep -qx "head=$first" "$out" && grep -qx "lock-held=1" "$out"; then
  pass "attach prints the kept log and returns the recorded exit code"
else
  fail "attach prints the kept log and returns the recorded exit code (exit $code: $(cat "$out" "$err"))"
fi
bench_remote worker attach 20000101-000000-widget-0000000
if [ "$code" -eq 125 ] && grep -q "no run 20000101-000000-widget-0000000" "$err"; then
  pass "attach on an unknown identifier fails with a clear message"
else
  fail "attach on an unknown identifier fails with a clear message (exit $code: $(cat "$out" "$err"))"
fi
bench_remote worker attach ../../etc
if [ "$code" -eq 125 ] && grep -q "not a run id" "$err"; then
  pass "attach refuses an identifier that is a path"
else
  fail "attach refuses an identifier that is a path (exit $code: $(cat "$err"))"
fi

echo "a later run"
touch "$checkout/left-by-the-first-run"
echo second >"$work/second.txt"
git -C "$work" add second.txt
git -C "$work" commit --quiet -m second
git -C "$work" push --quiet origin HEAD:refs/heads/main
second="$(git -C "$work" rev-parse HEAD)"
bench_remote worker -- bash -c "$probe" probe 0
if [ "$code" -eq 0 ] && grep -qx "head=$second" "$out" && [ -e "$checkout/left-by-the-first-run" ]; then
  pass "fetches the new commit into the same checkout"
else
  fail "fetches the new commit into the same checkout (exit $code: $(cat "$out" "$err"))"
fi
if [ -z "$(git -C "$work" status --porcelain --ignored)" ] && [ "$(ls -A "$HOME")" = .gitconfig ]; then
  pass "copies no file back to the caller"
else
  fail "copies no file back to the caller"
fi

# ── An unpushed commit ───────────────────────────────────────────────────────
echo "an unpushed commit"
echo local >"$work/local.txt"
git -C "$work" add local.txt
git -C "$work" commit --quiet -m local
unpushed="$(git -C "$work" rev-parse HEAD)"
bundle_tmp="$tmp/bundle-tmp"
mkdir -p "$bundle_tmp"
TMPDIR="$bundle_tmp" bench_remote worker -- bash -c "echo \"local=\$(cat local.txt)\"; $probe" probe 0
find_run_id
if [ "$code" -eq 0 ] && grep -qx "head=$unpushed" "$out" && grep -qx detached "$out" &&
  grep -qx "local=local" "$out" && grep -qx "lock-held=1" "$out"; then
  pass "transfers the unpushed commit via bundle, checks it out detached under the lock, and runs"
else
  fail "transfers the unpushed commit via bundle, checks it out detached under the lock, and runs (exit $code: $(cat "$out" "$err"))"
fi
if [ -f "$worker_home/bench/logs/$run_id/commit.bundle" ] &&
  grep -qx "commit_source='bundle'" "$worker_home/bench/logs/$run_id/job.sh" &&
  grep -qx "bench-remote: fetching unpushed commit $unpushed from local bundle" "$worker_home/bench/logs/$run_id/log" &&
  grep -q "unpushed, sending local bundle" "$err"; then
  pass "records the bundle transfer in the run directory, job, log and stderr"
else
  fail "records the bundle transfer in the run directory, job, log and stderr ($(cat "$err"))"
fi
if [ -z "$(git -C "$origin" branch --contains "$unpushed" 2>/dev/null)" ]; then
  pass "is not pushed to origin by the tool"
else
  fail "is not pushed to origin by the tool"
fi
if [ -z "$(ls -A "$bundle_tmp")" ]; then
  pass "cleans up the temporary local bundle file"
else
  fail "cleans up the temporary local bundle file (left: $(ls -A "$bundle_tmp"))"
fi

echo "re-running an unpushed commit with dirty tracked files"
echo dirty >"$work/local.txt"
TMPDIR="$bundle_tmp" bench_remote worker -- bash -c 'echo "head=$(git rev-parse HEAD)"; echo "local=$(cat local.txt)"'
if [ "$code" -eq 0 ] && grep -qx "head=$unpushed" "$out" && grep -qx "local=local" "$out" &&
  grep -q "uncommitted changes are not part of the run" "$err" &&
  [ -z "$(ls -A "$bundle_tmp")" ]; then
  pass "warns on dirty tracked files, runs the committed unpushed tree, and cleans up"
else
  fail "warns on dirty tracked files, runs the committed unpushed tree, and cleans up (exit $code: $(cat "$out" "$err"))"
fi
git -C "$work" checkout -- local.txt

echo "a stack of unpushed commits whose bundle transfer hits ssh faults"
echo local2 >"$work/local2.txt"
git -C "$work" add local2.txt
git -C "$work" commit --quiet -m local2
unpushed2="$(git -C "$work" rev-parse HEAD)"
printf '%s\n' "refuse *commit.bundle.new*" "drop-after *commit.bundle.new*" >"$FAKE_SSH_FAULTS"
TMPDIR="$bundle_tmp" bench_remote worker -- bash -c 'echo "head=$(git rev-parse HEAD)"; echo "files=$(cat local.txt),$(cat local2.txt)"'
if [ "$code" -eq 0 ] && [ "$(grep -c "; retry [0-9] of 3" "$err")" -eq 2 ] &&
  grep -qx "head=$unpushed2" "$out" && grep -qx "files=local,local2" "$out" &&
  [ -z "$(git -C "$origin" branch --contains "$unpushed2" 2>/dev/null)" ] &&
  [ -z "$(ls -A "$bundle_tmp")" ]; then
  pass "retries bundle copy on ssh 255, runs on the second unpushed commit, and cleans up"
else
  fail "retries bundle copy on ssh 255, runs on the second unpushed commit, and cleans up (exit $code: $(cat "$out" "$err"))"
fi
git -C "$work" reset --quiet --hard "$second"

echo "an unpushed commit when origin has no refs yet"
empty_origin="$tmp/github/acme/empty.git"
empty_work="$tmp/work/empty"
git init --quiet --bare "$empty_origin"
git init --quiet "$empty_work"
git -C "$empty_work" remote add origin "$empty_origin"
echo hello >"$empty_work/hello.txt"
git -C "$empty_work" add hello.txt
git -C "$empty_work" commit --quiet -m initial
empty_commit="$(git -C "$empty_work" rev-parse HEAD)"
make_worker emptyworker
(cd "$empty_work" && TMPDIR="$bundle_tmp" PATH="$caller_path" "$tool" emptyworker -- bash -c 'echo "head=$(git rev-parse HEAD)"; git symbolic-ref -q HEAD || echo detached; echo "hello=$(cat hello.txt)"') >"$out" 2>"$err"
code=$?
find_run_id
if [ "$code" -eq 0 ] && grep -qx "head=$empty_commit" "$out" && grep -qx detached "$out" &&
  grep -qx "hello=hello" "$out" &&
  [ -f "$FAKE_SSH_HOMES/emptyworker/bench/logs/$run_id/commit.bundle" ] &&
  [ -z "$(git -C "$empty_origin" for-each-ref)" ] &&
  [ -z "$(ls -A "$bundle_tmp")" ]; then
  pass "falls back to a full bundle and runs on a fresh worker without pushing"
else
  fail "falls back to a full bundle and runs on a fresh worker without pushing (exit $code: $(cat "$out" "$err"))"
fi

# ── An A/B session ───────────────────────────────────────────────────────────
# Each side says on stderr whether it runs under the lock, and prints a sample.
# The worker has no bench-compare: the caller compares.
echo "an A/B session"
fresh_compare
FAKE_COMPARE_EXIT=1 bench_remote worker -- bench-ab -n 4 --warmup 0 \
  --control 'echo "lock-held=${BENCH_LOCK_HELD:-no}" >&2; echo 10' \
  --experiment 'echo "lock-held=${BENCH_LOCK_HELD:-no}" >&2; echo 12' -- --min-effect "5 %"
find_run_id
if [ "$code" -eq 1 ] && [ "$(tail -n 1 "$out")" = "fake verdict" ]; then
  pass "compares the samples on the caller, after the log: bench-compare's verdict and exit code are the run's"
else
  fail "compares the samples on the caller, after the log: bench-compare's verdict and exit code are the run's (exit $code: $(cat "$out" "$err"))"
fi
if [ "$(head -n 2 "$FAKE_COMPARE_DIR/args" 2>/dev/null | tr '\n' '|')" = "--min-effect|5 %|" ] &&
  [ "$(wc -l <"$FAKE_COMPARE_DIR/args")" -eq 4 ] &&
  [ "$(tr '\n' ' ' <"$FAKE_COMPARE_DIR/control" 2>/dev/null)" = "10 10 10 10 " ] &&
  [ "$(tr '\n' ' ' <"$FAKE_COMPARE_DIR/experiment" 2>/dev/null)" = "12 12 12 12 " ]; then
  pass "hands bench-compare the session's options and each side's samples"
else
  fail "hands bench-compare the session's options and each side's samples ($(cat "$FAKE_COMPARE_DIR/args" 2>&1))"
fi
caller_name="$(uname -n)"
caller_name="${caller_name%%.*}"
if [ "$(tail -n 2 "$out" | head -n 1)" = "bench-remote: comparing on $caller_name: bench-compare --min-effect '5 %'" ]; then
  pass "names the caller and the options just before bench-compare's verdict"
else
  fail "names the caller and the options just before bench-compare's verdict ($(tail -n 3 "$out"))"
fi
ab_log="$worker_home/bench/logs/$run_id/log"
# shellcheck disable=SC2016  # the command's words, as the log quotes them
if grep -qxF "bench-remote: running bench-ab -n 4 --warmup 0 --control 'echo \"lock-held=\${BENCH_LOCK_HELD:-no}\" >&2; echo 10' --experiment 'echo \"lock-held=\${BENCH_LOCK_HELD:-no}\" >&2; echo 12' -- --min-effect '5 %'" "$ab_log"; then
  pass "the log names the command with its words shell-quoted"
else
  fail "the log names the command with its words shell-quoted ($(grep '^bench-remote: running' "$ab_log"))"
fi
if grep -qx "bench-ab: bench-compare is not on PATH; bench-remote compares these samples on the caller" "$ab_log" &&
  ! grep -q "compare on the caller: bench-compare" "$ab_log"; then
  pass "bench-ab on the worker leaves the comparison to bench-remote, naming no worker path"
else
  fail "bench-ab on the worker leaves the comparison to bench-remote, naming no worker path ($(grep '^bench-ab: bench-compare' "$ab_log"))"
fi
if cmp -s "$here/bin/bench-ab" "$worker_home/bench/bin/bench-ab" &&
  [ -x "$worker_home/bench/bin/bench-ab" ]; then
  pass "copies bench-ab beside bench-lock, on the command's PATH"
else
  fail "copies bench-ab beside bench-lock, on the command's PATH (exit $code: $(cat "$out" "$err"))"
fi
if [ "$(grep -cx "lock-held=1" "$ab_log")" -eq 8 ] && [ "$(sed -n '/^bench-remote: running /,$p' "$ab_log" | grep "^bench-lock: on " | grep -vc ", during the run,")" -eq 0 ] &&
  ! grep -q "NOT isolated" "$ab_log"; then
  pass "runs the whole session under the worker's single lock"
else
  fail "runs the whole session under the worker's single lock ($(cat "$ab_log"))"
fi
bench_remote worker attach "$run_id"
if [ "$(sed -n 's/^bench: sample control //p' "$out" | tr '\n' ' ')" = "10 10 10 10 " ] &&
  [ "$(sed -n 's/^bench: sample experiment //p' "$out" | tr '\n' ' ')" = "12 12 12 12 " ]; then
  pass "brings every sample back in the run log, for bench-compare on the caller"
else
  fail "brings every sample back in the run log, for bench-compare on the caller ($(cat "$out"))"
fi
if [ "$code" -eq 0 ] && [ "$(tail -n 1 "$out")" = "fake verdict" ]; then
  pass "attach compares the samples of a finished A/B session too"
else
  fail "attach compares the samples of a finished A/B session too (exit $code: $(cat "$out" "$err"))"
fi
CALLER_PATH="$bare_caller_path" bench_remote worker attach "$run_id"
if [ "$code" -eq 125 ] && [ "$(grep -c "bench-compare" "$err")" -eq 1 ] && ! grep -q "fake verdict" "$out"; then
  pass "without bench-compare on the caller, fails as the tool (125) in one line: never green"
else
  fail "without bench-compare on the caller, fails as the tool (125) in one line: never green (exit $code: $(cat "$err"))"
fi
fresh_compare
bench_remote worker -- sh -c 'echo "bench: sample control 1"; echo "bench: sample experiment 2"; exit 3'
if [ "$code" -eq 3 ] && [ ! -e "$FAKE_COMPARE_DIR/args" ]; then
  pass "a job that exits non-zero keeps its own code, its samples not compared"
else
  fail "a job that exits non-zero keeps its own code, its samples not compared (exit $code: $(cat "$out" "$err"))"
fi

# ── Live output, and a dropped connection ────────────────────────────────────
# The job prints a line, waits to be released, prints another. Every wait is
# bounded, so that a failure cannot hang the suite.
wait_for() { # $1 = seconds, then a test command
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

echo "a run whose connection drops for good"
release="$tmp/release" dropped="$tmp/dropped"
job='echo "first line"
for i in $(seq 300); do [ -e "$1" ] && break; sleep 0.1; done
echo "second line"
exit 4'
(cd "$work" && FAKE_SSH_DROP="$dropped" "$tool" worker -- bash -c "$job" job "$release") >"$out" 2>"$err" &
caller=$!
if wait_for 20 grep -qx "first line" "$out"; then
  pass "shows the remote output live"
else
  fail "shows the remote output live ($(cat "$out" "$err"))"
fi
find_run_id
touch "$dropped"
wait "$caller"
code=$?
if [ "$code" -eq 125 ] && grep -q "the run goes on" "$err" && grep -q "$run_id" "$err" &&
  ! grep -qx "second line" "$out"; then
  pass "fails as the tool, once its retries are spent, and says where the run goes on"
else
  fail "fails as the tool, once its retries are spent, and says where the run goes on (exit $code, run $run_id: $(cat "$out" "$err"))"
fi
if [ "$(grep -c "; retry [0-9] of 3" "$err")" -eq 3 ]; then
  pass "retries the connection three times first"
else
  fail "retries the connection three times first ($(cat "$err"))"
fi
if grep -q "bench-remote worker attach $run_id" "$err"; then
  pass "says how to attach to the run again"
else
  fail "says how to attach to the run again ($(cat "$err"))"
fi
bench_remote worker status
if [ "$code" -eq 0 ] && grep -Eq "^$run_id +running +bash -c " "$out"; then
  pass "status shows the run, still running"
else
  fail "status shows the run, still running (exit $code: $(cat "$out" "$err"))"
fi
(cd "$work" && "$tool" worker attach "$run_id") >"$out" 2>"$err" &
caller=$!
if wait_for 20 grep -qx "first line" "$out" && ! grep -qx "second line" "$out"; then
  pass "attach follows the running job live"
else
  fail "attach follows the running job live ($(cat "$out" "$err"))"
fi
touch "$release"
wait "$caller"
code=$?
if [ "$code" -eq 4 ] && grep -qx "second line" "$out"; then
  pass "attach follows the log to the end and returns the job's exit code"
else
  fail "attach follows the log to the end and returns the job's exit code (exit $code: $(cat "$out" "$err"))"
fi
bench_remote worker status
if [ "$code" -eq 0 ] && grep -Eq "^$run_id +exit 4 " "$out"; then
  pass "status then shows the run's exit code"
else
  fail "status then shows the run's exit code ($(cat "$out"))"
fi

echo "an interrupted follow"
# Ctrl-C at the caller's terminal: the signal goes to its whole process group.
release="$tmp/release-interrupted"
(cd "$work" && "$tool" worker -- bash -c "$job" job "$release") >"$out" 2>"$err" &
caller=$!
wait_for 20 grep -qx "first line" "$out" || fail "the interrupted run starts ($(cat "$out" "$err"))"
find_run_id
kill -INT -- "-$caller"
wait "$caller"
code=$?
if [ "$code" -eq 130 ] && grep -q "the run goes on" "$err" && grep -q "bench-remote worker attach $run_id" "$err"; then
  pass "says the run goes on and how to attach to it again"
else
  fail "says the run goes on and how to attach to it again (exit $code: $(cat "$err"))"
fi
touch "$release"
bench_remote worker attach "$run_id"
if [ "$code" -eq 4 ] && grep -qx "first line" "$out" && grep -qx "second line" "$out"; then
  pass "leaves the job running to its end, its whole log kept"
else
  fail "leaves the job running to its end, its whole log kept (exit $code: $(cat "$out" "$err"))"
fi

echo "a job killed on the worker"
# The bench kills its job, the newest run on the worker: no exit code is ever
# written.
bench_remote worker -- bash -c 'runs=("$HOME"/bench/logs/*/); kill -9 "$(cat "${runs[${#runs[@]}-1]}pid")"; sleep 1'
if [ "$code" -eq 125 ] && grep -q "died without an exit code" "$err"; then
  pass "is reported as a failure of the tool instead of a hang"
else
  fail "is reported as a failure of the tool instead of a hang (exit $code: $(cat "$err"))"
fi

echo "a killed job whose pid was handed on"
# The bench kills its job, after handing the job's pid to a process of its own
# that outlives it: the pid is alive, but no longer the job's. A start time is
# read to the second: the new process starts a second after the job at least,
# as a reused pid always does, or the two could not be told apart.
started_at=$SECONDS
bench_remote worker -- bash -c 'runs=("$HOME"/bench/logs/*/); run="${runs[${#runs[@]}-1]}"; job="$(cat "${run}pid")"; sleep 1.1; sleep 30 & echo "$!" >"${run}pid"; kill -9 "$job"; sleep 1'
if [ "$code" -eq 125 ] && grep -q "died without an exit code" "$err" && [ $((SECONDS - started_at)) -lt 15 ]; then
  pass "is told apart from the process now holding its pid"
else
  fail "is told apart from the process now holding its pid (exit $code after $((SECONDS - started_at))s: $(cat "$err"))"
fi
# The process that took the pid is the newest run's; it has nothing left to do.
runs=("$FAKE_SSH_HOMES"/worker/bench/logs/*/)
kill "$(cat "${runs[${#runs[@]}-1]}pid")" 2>/dev/null

# ── The node a run uses ──────────────────────────────────────────────────────
# A worker with nvm, whose default node is 22, as on the real one, and which
# can "download" 24.
make_worker mini
add_nvm mini 22 24
git config --file "$FAKE_SSH_HOMES/mini/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
mini_home="$FAKE_SSH_HOMES/mini"

# The pin is pushed for good: every later case runs with a .nvmrc, the case
# of a worker without nvm by design.
pin_node() { # $1 = the version the repository's .nvmrc pins
  echo "$1" >"$work/.nvmrc"
  git -C "$work" add .nvmrc
  git -C "$work" commit --quiet -m "pin node $1"
  git -C "$work" push --quiet origin HEAD:refs/heads/main
}

echo "a run whose .nvmrc pins a node nvm does not have yet"
pin_node 24
bench_remote mini -- bash -c "$probe" probe 0
find_run_id
if [ "$code" -eq 0 ] && grep -qx "node=v24.0.0" "$out" && grep -q "node: v24.0.0$" "$mini_home/pnpm.calls"; then
  pass "runs the install and the command under the pinned node"
else
  fail "runs the install and the command under the pinned node (exit $code: $(cat "$out" "$err"))"
fi
if [ "$(cat "$mini_home/.nvm/downloads" 2>/dev/null)" = v24 ]; then
  pass "installs the pinned node first"
else
  fail "installs the pinned node first ($(cat "$mini_home/.nvm/downloads" 2>/dev/null))"
fi
if grep -q "^bench-remote: node v24.0.0" "$mini_home/bench/logs/$run_id/log"; then
  pass "names the pinned node in the log"
else
  fail "names the pinned node in the log ($(cat "$mini_home/bench/logs/$run_id/log"))"
fi

echo "a later run with the same .nvmrc"
bench_remote mini -- bash -c "$probe" probe 0
if [ "$code" -eq 0 ] && grep -qx "node=v24.0.0" "$out" && [ "$(cat "$mini_home/.nvm/downloads")" = v24 ]; then
  pass "uses the pinned node already installed, without installing it again"
else
  fail "uses the pinned node already installed, without installing it again (exit $code: $(cat "$out" "$err"))"
fi

echo "a run whose .nvmrc pins a node that cannot be installed"
pin_node 99
: >"$mini_home/pnpm.calls"
bench_remote mini -- bash -c "$probe" probe 0
if [ "$code" -eq 125 ] && grep -q "^bench-remote: cannot install node 99" "$out"; then
  pass "fails the run as a failure to prepare it, with a clear line"
else
  fail "fails the run as a failure to prepare it, with a clear line (exit $code: $(cat "$out" "$err"))"
fi
if [ ! -s "$mini_home/pnpm.calls" ] && ! grep -q "^head=" "$out"; then
  pass "runs neither the install nor the command"
else
  fail "runs neither the install nor the command ($(cat "$out"))"
fi

echo "a run whose .nvmrc pins a node on a worker without nvm"
pin_node 24
bench_remote worker -- bash -c "$probe" probe 0
find_run_id
if [ "$code" -eq 0 ] && grep -qx "node=v20.0.0" "$out" &&
  grep -q "^bench-remote: node v20.0.0" "$worker_home/bench/logs/$run_id/log"; then
  pass "runs with the login shell's node, named in the log"
else
  fail "runs with the login shell's node, named in the log (exit $code: $(cat "$out" "$err"))"
fi
if grep -q "^bench-remote: .*nvm is not on this worker" "$worker_home/bench/logs/$run_id/log"; then
  pass "says the .nvmrc is not followed"
else
  fail "says the .nvmrc is not followed ($(cat "$worker_home/bench/logs/$run_id/log"))"
fi

# ── A run whose login profile takes its time ─────────────────────────────────
# The job only records itself once the profile has loaded; this profile waits
# to be released, a bounded wait.
echo "a run whose login profile is still loading"
make_worker slow
git config --file "$FAKE_SSH_HOMES/slow/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
echo 'while [ ! -e "$HOME/profile-may-finish" ] && [ "$SECONDS" -lt 30 ]; do sleep 0.1; done' >>"$FAKE_SSH_HOMES/slow/.bash_profile"
status_out="$tmp/status-out"
(cd "$work" && "$tool" slow -- true) >"$out" 2>"$err" &
caller=$!
wait_for 20 grep -q "^bench-remote: run " "$err"
find_run_id
wait_for 20 test -f "$FAKE_SSH_HOMES/slow/bench/logs/$run_id/job.sh"
(cd "$work" && "$tool" slow status) >"$status_out" 2>&1
if grep -Eq "^$run_id +starting +true$" "$status_out"; then
  pass "status shows the run as starting while its launcher lives"
else
  fail "status shows the run as starting while its launcher lives ($(cat "$status_out"))"
fi
touch "$FAKE_SSH_HOMES/slow/profile-may-finish"
wait "$caller"
code=$?
if [ "$code" -eq 0 ]; then
  pass "runs once the profile has loaded"
else
  fail "runs once the profile has loaded (exit $code: $(cat "$out" "$err"))"
fi

# ── A launch that never got going ────────────────────────────────────────────
# Made by hand, as a dropped launch leaves it: a job and its command, and either
# no launcher at all or a launcher long gone, and no pid.
echo "a launch whose launcher is gone"
dead_launcher() { # $1 = run id; with $2 = "with-launcher", a launcher that died
  local run="$worker_home/bench/logs/$1" gone
  mkdir -p "$run"
  echo true >"$run/job.sh"
  echo "never-ran" >"$run/command"
  if [ "${2:-}" = with-launcher ]; then
    sh -c 'exit 0' &
    gone=$!
    wait "$gone"
    # Recorded at another time: a process since given its pid is not it.
    echo "Thu Jan  1 00:00:00 1970" >"$run/launcher-started"
    echo "$gone" >"$run/launcher"
  fi
}
dead_launcher 20000101-000000-widget-dead000 with-launcher
dead_launcher 20000101-000001-widget-none000
bench_remote worker status
if grep -Eq "^20000101-000000-widget-dead000 +not started +never-ran$" "$out" &&
  grep -Eq "^20000101-000001-widget-none000 +not started +never-ran$" "$out"; then
  pass "status shows it as not started at once, launcher dead or never recorded"
else
  fail "status shows it as not started at once, launcher dead or never recorded ($(cat "$out" "$err"))"
fi
started_at=$SECONDS
bench_remote worker attach 20000101-000000-widget-dead000
if [ "$code" -eq 125 ] && grep -q "not started; see .*/bench/logs/20000101-000000-widget-dead000" "$err" &&
  [ $((SECONDS - started_at)) -lt 10 ]; then
  pass "attach fails at once, naming the run directory"
else
  fail "attach fails at once, naming the run directory (exit $code after $((SECONDS - started_at))s: $(cat "$err"))"
fi

# ── Connections that fail ────────────────────────────────────────────────────
echo "a launch whose connections fail now and then"
: >"$worker_home/ran"
printf '%s\n' "refuse *bench-lock.new*" "refuse *nohup*" "drop-after *nohup*" >"$FAKE_SSH_FAULTS"
bench_remote worker -- bash -c 'echo ran >>"$HOME/ran"'
if [ "$code" -eq 0 ] && [ "$(grep -c "; retry [0-9] of 3" "$err")" -eq 3 ]; then
  pass "is retried, a line for each retry, and runs"
else
  fail "is retried, a line for each retry, and runs (exit $code: $(cat "$err"))"
fi
if [ "$(wc -l <"$worker_home/ran")" -eq 1 ]; then
  pass "runs the job exactly once, however many launches went through"
else
  fail "runs the job exactly once, however many launches went through ($(wc -l <"$worker_home/ran") runs)"
fi

echo "a status whose connection fails once"
printf '%s\n' "refuse *-- status*" >"$FAKE_SSH_FAULTS"
bench_remote worker status
if [ "$code" -eq 0 ] && grep -q "retry" "$err" && grep -Eq " +exit 0 +bash -c " "$out"; then
  pass "is retried and lists the runs"
else
  fail "is retried and lists the runs (exit $code: $(cat "$out" "$err"))"
fi

echo "a launch dropped between its nohup and its launcher record"
# The job is held in its login profile, so that the relaunch finds no pid:
# the two jobs then race for the run.
make_worker flaky
git config --file "$FAKE_SSH_HOMES/flaky/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
echo 'while [ ! -e "$HOME/profile-may-finish" ] && [ "$SECONDS" -lt 30 ]; do sleep 0.1; done' >>"$FAKE_SSH_HOMES/flaky/.bash_profile"
printf '%s\n' "lose-launcher-after *nohup*" >"$FAKE_SSH_FAULTS"
: >"$FAKE_SSH_LOG"
(cd "$work" && "$tool" flaky -- bash -c 'echo ran >>"$HOME/ran"; sleep 1') >"$out" 2>"$err" &
caller=$!
wait_for 20 test -f "$FAKE_SSH_HOMES/flaky/bench/logs/"*/launcher
sleep 0.5
touch "$FAKE_SSH_HOMES/flaky/profile-may-finish"
wait "$caller"
code=$?
# A second job, had it run, would still be queued behind the first's lock.
no_job_left() { ! pgrep -f "$FAKE_SSH_HOMES/flaky/bench/logs/" >/dev/null; }
wait_for 20 no_job_left
if [ "$code" -eq 0 ] && [ "$(grep -c "^ran$" "$FAKE_SSH_HOMES/flaky/ran" 2>/dev/null)" -eq 1 ]; then
  pass "starts the job once, the second launch's job finding the run taken"
else
  fail "starts the job once, the second launch's job finding the run taken (exit $code, $(grep -c "^ran$" "$FAKE_SSH_HOMES/flaky/ran" 2>/dev/null) runs: $(cat "$err"))"
fi
if [ "$(grep -c "nohup bash -lc" "$FAKE_SSH_LOG")" -eq 2 ]; then
  pass "was launched twice, the launcher record lost the first time"
else
  fail "was launched twice, the launcher record lost the first time ($(grep -c "nohup bash -lc" "$FAKE_SSH_LOG") launches)"
fi

echo "a follow whose connection drops mid-run"
release="$tmp/release-resumed" dropped="$tmp/dropped-once"
(cd "$work" && FAKE_SSH_DROP="$dropped" FAKE_SSH_DROP_ONCE=1 "$tool" worker -- bash -c "$job" job "$release") >"$out" 2>"$err" &
caller=$!
wait_for 20 grep -qx "first line" "$out" || fail "the resumed run starts ($(cat "$out" "$err"))"
find_run_id
touch "$dropped"
wait_for 20 grep -q "retry" "$err"
touch "$release"
wait "$caller"
code=$?
if [ "$code" -eq 4 ] && grep -q "retry" "$err" && ! grep -q "attach" "$err"; then
  pass "resumes the follow and returns the job's exit code"
else
  fail "resumes the follow and returns the job's exit code (exit $code: $(cat "$err"))"
fi
if [ "$(grep -v "^Welcome to worker$" "$out")" = "$(cat "$worker_home/bench/logs/$run_id/log")" ]; then
  pass "shows the whole log once, no line missing or repeated"
else
  fail "shows the whole log once, no line missing or repeated ($(cat "$out"))"
fi

echo "a run whose install leaves the machine noisy"
# The worker's CPU reading is a file its profile names: calm before the run,
# made noisy by the install, made calm again by the case once it has seen the
# wait. The settle wait is on for this worker alone.
make_worker busy
busy_home="$FAKE_SSH_HOMES/busy"
git config --file "$busy_home/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
echo 0.05 >"$busy_home/reading"
{
  echo "export BENCH_LOCK_SETTLE=60 BENCH_LOCK_NOTICE_SECONDS=1"
  echo "export BENCH_LOCK_CPU_PER_CORE=\"\$HOME/reading\""
} >>"$busy_home/.bash_profile"
echo 'echo 0.8 >"$HOME/reading"' >>"$busy_home/toolchain/pnpm"
(cd "$work" && "$tool" busy -- sh -c 'echo "bench started"') >"$out" 2>"$err" &
caller=$!
if wait_for 20 grep -q "^bench-lock: waiting for the machine to settle, cpu 0.80 per core" "$out" &&
  ! grep -qx "bench started" "$out"; then
  pass "waits for the machine to settle after the install, before the command"
else
  fail "waits for the machine to settle after the install, before the command ($(cat "$out" "$err"))"
fi
echo 0.05 >"$busy_home/reading"
wait "$caller"
code=$?
if [ "$code" -eq 0 ] && grep -qx "bench started" "$out" &&
  [ "$(grep -c '^bench-lock: on [^,]*, cpu 0.05 per core: calm' "$out")" -eq 2 ] &&
  [ "$(sed -n '/^bench-lock: waiting for the machine to settle/,$p' "$out" | grep '^bench-lock: on ' | grep -vc ', during the run,')" -eq 1 ]; then
  pass "then reads it calm, says so, and starts the command"
else
  fail "then reads it calm, says so, and starts the command (exit $code: $(cat "$out" "$err"))"
fi
if grep -q '^bench-lock: on [^,]*, during the run, cpu besides the bench p90 0.05, max 0.05, ' "$out"; then
  pass "judges the run from the settle on: the install's load is not in the end-of-run verdict"
else
  fail "judges the run from the settle on: the install's load is not in the end-of-run verdict ($(cat "$out"))"
fi

echo "a bench that leaves a child behind"
# The child sleeps on, holding the log open: the run still ends with the
# bench, its end-of-run line in the log first.
(cd "$work" && "$tool" worker -- sh -c 'sleep 30 & echo "$!" >"$HOME/orphan"; echo "bench done"') >"$out" 2>"$err" &
caller=$!
if wait_for 20 sh -c '! kill -0 "$1" 2>/dev/null' _ "$caller"; then
  wait "$caller"
  code=$?
  if [ "$code" -eq 0 ] && grep -qx "bench done" "$out" &&
    grep -q '^bench-lock: on [^,]*, during the run, ' <(sed '1,/^bench done$/d' "$out"); then
    pass "ends with the bench, its end-of-run verdict shown, whatever the bench left running"
  else
    fail "ends with the bench, its end-of-run verdict shown, whatever the bench left running (exit $code: $(cat "$out" "$err"))"
  fi
else
  fail "ends with the bench, its end-of-run verdict shown, whatever the bench left running (still running after 20s: $(cat "$out"))"
  kill -TERM -- "-$caller" 2>/dev/null
fi
kill "$(cat "$worker_home/orphan" 2>/dev/null)" 2>/dev/null

echo "a job that exits 255 itself"
bench_remote worker -- sh -c 'echo hi; exit 255'
if [ "$code" -eq 255 ] && [ "$(grep -cx hi "$out")" -eq 1 ] &&
  ! grep -q "connection\|retry\|attach" "$err"; then
  pass "returns 255, its output once, without a word about the connection"
else
  fail "returns 255, its output once, without a word about the connection (exit $code: $(cat "$out" "$err"))"
fi

# ── Tools next to bench-remote ───────────────────────────────────────────────
echo "a bench-remote without bench-ab next to it"
mkdir -p "$tmp/no-ab"
cp "$here/bin/bench-remote" "$here/bin/bench-lock" "$here/bin/bench-device" "$tmp/no-ab/"
(cd "$work" && "$tmp/no-ab/bench-remote" worker -- true) >"$out" 2>"$err"
code=$?
if [ "$code" -eq 125 ] && grep -q "cannot find bench-ab next to bench-remote" "$err"; then
  pass "is refused, naming the missing tool"
else
  fail "is refused, naming the missing tool (exit $code: $(cat "$err"))"
fi

# A bench-lock that runs the command and never gets as far as its sampler: no
# end-of-run line, no marker. Its own worker, since the tools are copied there.
echo "a bench-lock that never reaches its sampler"
make_worker nosampler
git config --file "$FAKE_SSH_HOMES/nosampler/.gitconfig" url."$origin".insteadOf https://github.com/acme/widget.git
mkdir -p "$tmp/no-sampler"
cp "$here/bin/bench-remote" "$here/bin/bench-device" "$here/bin/bench-ab" "$tmp/no-sampler/"
cat >"$tmp/no-sampler/bench-lock" <<'EOF'
#!/bin/sh
case "$1" in
  run)
    shift
    [ "$1" = -- ] && shift
    exec "$@"
    ;;
esac
EOF
chmod +x "$tmp/no-sampler/bench-lock"
started_at=$SECONDS
(cd "$work" && PATH="$caller_path" "$tmp/no-sampler/bench-remote" nosampler -- sh -c 'echo "bench done"; exit 6') >"$out" 2>"$err"
code=$?
elapsed=$((SECONDS - started_at))
if [ "$code" -eq 6 ] && grep -qx "bench done" "$out" && [ "$elapsed" -ge 9 ] && [ "$elapsed" -lt 25 ]; then
  pass "ends the run anyway, its exit code written once the 10 s wait for the marker runs out"
else
  fail "ends the run anyway, its exit code written once the 10 s wait for the marker runs out (exit $code after ${elapsed}s: $(cat "$out" "$err"))"
fi

if [ "$fails" -eq 0 ]; then
  echo "bench-remote: all cases passed"
else
  echo "bench-remote: $fails failed"
  exit 1
fi
