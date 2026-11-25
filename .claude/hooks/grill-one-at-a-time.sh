#!/usr/bin/env bash
# UserPromptSubmit: during an interview session ("grilling"), injects the rules
# the `grilling` skill does not know: one question per turn, in the user's reply
# language. The rules themselves live in shared/policies/grilling.md.
#
# Why a session marker rather than a plain grep of the prompt: the hook only
# sees the current prompt, yet the rules must hold for the whole interview. The
# marker is set by the triggering prompt and lives as long as the session.
#
# Triggers and stop phrases are matched in English and in French.
set -euo pipefail

input=$(cat)
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"')
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')

state_dir="${TMPDIR:-/tmp}/claude-grill"
marker="$state_dir/$session"

start_re='(^|[[:space:]/])(grill|grilling|grille[-_ ]?moi|cuisine[-_ ]?moi|interroge[-_ ]?moi)'
stop_re='(end grilling|stop grilling|fin du grilling|arr[eê]te le grilling)'

shopt -s nocasematch
if [[ $prompt =~ $stop_re ]]; then
  rm -f "$marker"
  exit 0
elif [[ $prompt =~ $start_re ]]; then
  mkdir -p "$state_dir"
  : >"$marker"
fi
shopt -u nocasematch

[[ -f $marker ]] || exit 0

# Resolve the installed hook symlink before locating the canonical policy.
script_path="${BASH_SOURCE[0]}"
while [[ -L $script_path ]]; do
  script_dir=$(cd -P "$(dirname "$script_path")" && pwd)
  link_target=$(readlink "$script_path")
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *) script_path="$script_dir/$link_target" ;;
  esac
done
script_dir=$(cd -P "$(dirname "$script_path")" && pwd)
policy_path="$script_dir/../../shared/policies/grilling.md"

jq -n --rawfile ctx "$policy_path" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
