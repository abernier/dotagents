#!/usr/bin/env bash
# Sibling test of the grill-one-at-a-time.sh hook.
set -uo pipefail
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/grill-hook-test.XXXXXX")
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
H="$(dirname "${BASH_SOURCE[0]}")/grill-one-at-a-time.sh"
fails=0

check() { # name, expected (yes|no), json
  local out
  if ! out=$(printf '%s' "$3" | bash "$H"); then
    echo "  FAIL $1 (hook failed)"
    fails=$((fails+1))
    return
  fi
  local got=no; [[ -n $out ]] && got=yes
  if [[ $got == "$2" ]]; then echo "  ok   $1"; else echo "  FAIL $1 (expected $2, got $got)"; fails=$((fails+1)); fi
}

S="test-$$"
check "trigger /grill-me"              yes "{\"session_id\":\"$S\",\"prompt\":\"/grill-me\"}"
check "next turn, same session"        yes "{\"session_id\":\"$S\",\"prompt\":\"(a) root always\"}"
check "session without trigger"        no  "{\"session_id\":\"$S-other\",\"prompt\":\"fix the bug\"}"
check "French trigger"                 yes "{\"session_id\":\"$S-fr\",\"prompt\":\"grille-moi sur ce plan\"}"
check "French stop"                    no  "{\"session_id\":\"$S-fr\",\"prompt\":\"fin du grilling\"}"
check "after French stop"              no  "{\"session_id\":\"$S-fr\",\"prompt\":\"suite\"}"
check "stop"                           no  "{\"session_id\":\"$S\",\"prompt\":\"end grilling\"}"
check "after stop"                     no  "{\"session_id\":\"$S\",\"prompt\":\"next\"}"
check "empty prompt"                   no  "{\"session_id\":\"$S-empty\",\"prompt\":\"\"}"

rm -f "${TMPDIR:-/tmp}/claude-grill/$S"*
[[ $fails -eq 0 ]] && echo "grill-one-at-a-time: all pass" || echo "grill-one-at-a-time: $fails failure(s)"
exit $fails
