#!/usr/bin/env bash
# branchstat.sh — net diff overview of the current branch vs its base.
#
# Usage: bash branchstat.sh [base]          # or the /branchstat skill
#        bash branchstat.sh --md [base]     # markdown, for a PR comment
#        bash branchstat.sh --of <branch>   # measure a branch other than this one
#        bash branchstat.sh --depth <n>     # cap the module rollup (default 5)
#        bash branchstat.sh --classify      # paths on stdin → "<bucket> <path>"
#
# It runs against whatever repo the caller stands in — nothing here is specific
# to one project, and it lives outside all of them, as a user-level skill. It
# needs nothing from the repo it measures: no node_modules, no install step.
# Requirements degrade rather than fail: git alone prints the headline total,
# cloc and node (≥ 22.6, or `tsx` through npx) buy the breakdown under it;
# without cloc the total still prints and says so. The markdown footer's
# "reproduce locally" line names `/branchstat`; $BRANCHSTAT_REPRO overrides it,
# for a caller whose readers reach the report some other way.
#
# Base resolution: explicit arg > the PR's own base branch > origin/HEAD > main.
# The PR base comes from `gh pr view --json baseRefName` — for the checked-out
# branch when none is named, for the branch named with --of otherwise. It is the
# right answer for a PR stacked on another, whose base is its parent branch. It
# names a branch on the remote, so it is read as `origin/<base>`, and only as a
# local branch of that name when no such remote-tracking ref exists. A missing
# `gh`, no PR, or no network all land on origin/HEAD.
#
# The tip is the working tree, untracked files included — the range reads
# "…worktree" when there is uncommitted work, a short SHA when there isn't. With
# --of it is the named branch as committed: it is not checked out here, so it has
# no working tree of its own.
#
# The headline total is the whole diff, counted the way GitHub counts a PR — put
# it next to the "+1,401 −47" on the PR page and it is the same two numbers.
# Everything below it is filtered; the total is not, because a total that agrees
# with neither GitHub nor the buckets under it is the one number a reader cannot
# place.
#
# The breakdown excludes everything that isn't hand-written product/tooling code
# — lockfiles, prose, vendored and generated trees, assets and fixtures. The
# defaults are in DEFAULT_EXCLUDES below; a repo adds its own in
# `branchstat.json` at its root:
#
#   { "exclude": ["packages/www/public/", "src/generated/", "*.snap"] }
#
# A pattern ending in `/` is a directory, matched at any depth; anything else is
# a file pattern where `*` stands for a run of characters. There is no negation:
# a repo that needs one file back out of an excluded tree excludes the tree more
# narrowly instead.
#
# Test and config code are not excluded but bucketed apart, so the source net
# answers "how much product code did this branch add" without hiding their cost.
#
# Each bucket also carries a net net: its net with the new modules left out — a
# dot-scoped family none of whose files existed at the merge base. It answers
# how much the code already there grew, apart from what the branch created. A
# rename to a new family reads as a new module plus a removal from the old one.
#
# Inside a bucket the files roll up by module, read off dot-scoped naming:
# Plane, Plane.tile, Plane.tile.label are one family, and the report says which
# of them took the charge before it says which file did. A branch whose weight
# sits in one module is a different branch from one that spreads the same lines
# over eight — that is the number worth reading first, and it is the one a
# per-file list buries.
set -euo pipefail

# Git reads GIT_DIR and friends out of the environment and lets them win over
# `cwd` — and over `-C`, so no git call below can defend itself against one. A git hook exports them,
# which is how a local /branchstat run inherits one, and then `ROOT_DIR`, the
# base and the range are all read out of the hook's repository instead of the
# one the caller stands in. It fails silently: a report on the wrong repo looks
# exactly like a report, so drop them here, before anything resolves a repo.
# shellcheck disable=SC2046  # intentional word-splitting of the var-name list
unset $(git rev-parse --local-env-vars)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_TS="$SCRIPT_DIR/branchstat.report.mts"

# Bucketing, the module rollup and both renderings live in the TypeScript half;
# this file stays the one that talks to git and cloc.
#
# It is run without a build step, and the script cannot assume the repo it is
# invoked in has any toolchain of its own — it is not even one of that repo's
# files: Node strips the types itself from 22.6, and an npx `tsx` covers
# anything older.
node_strips_types=""

# Whether this machine can run the report at all: Node that strips types, or a
# `tsx` to hand it to.
have_node() {
  command -v node > /dev/null || command -v npx > /dev/null
}

report_ts() {
  if [ -z "$node_strips_types" ]; then
    if node --disable-warning=ExperimentalWarning --experimental-strip-types \
      -e '' > /dev/null 2>&1; then
      node_strips_types=yes
    else
      node_strips_types=no
    fi
  fi
  if [ "$node_strips_types" = yes ]; then
    node --disable-warning=ExperimentalWarning --experimental-strip-types \
      "$REPORT_TS" "$@"
  else
    npx --yes tsx "$REPORT_TS" "$@"
  fi
}

# Append the footer a PR comment carries: what the numbers describe, and how to
# get them again. Under GitHub Actions the commit and the run become links; run
# locally, the short SHA stands on its own.
#
#   $1 — the markdown file to append to
#   $2 — the command that reproduces this run locally
#   $3 — what the numbers describe when it is not a commit at all. branchstat
#        can measure the working tree, so claiming the data belongs to a commit
#        would attribute uncommitted lines to one that lacks them.
#   $4 — the commit the numbers belong to, when it is not HEAD.
emit_footer() {
  local comment_file="$1" repro_cmd="$2" rev_label="$3" subject_rev="${4:-HEAD}"
  [ -f "$comment_file" ] || return 0

  local sha_short sha_full sha_md run_md=""
  sha_short="$(git rev-parse --short "$subject_rev")"
  sha_full="$(git rev-parse "$subject_rev")"
  sha_md="\`${sha_short}\`"
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    sha_md="[\`${sha_short}\`](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${sha_full})"
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
      run_md=" — [view run](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
    fi
  fi

  {
    echo ""
    echo "---"
    echo ""
    echo "<sub>Reproduce locally with \`${repro_cmd}\`.</sub>"
    echo ""
    if [ -z "$rev_label" ] || [ "$rev_label" = "$sha_short" ]; then
      echo "<sub>Data for ${sha_md}${run_md}.</sub>"
    else
      echo "<sub>Data for \`${rev_label}\`, on top of ${sha_md}${run_md}.</sub>"
    fi
  } >> "$comment_file"
}

render=text
tip_rev=""
base_arg=""
classify=0
# How deep the rollup may go, and so the most stops its grey ramp could need.
# The ramp itself spans the depth the diff actually reaches, clamped to this.
# This is the only place it is written: the report takes it as a required flag
# rather than carrying a default of its own that could drift from this one.
maxdepth=5
while [ $# -gt 0 ]; do
  case "$1" in
    --md) render=md ;;
    --classify) classify=1 ;;
    --of)
      shift
      tip_rev="${1:-}"
      [ -n "$tip_rev" ] || { echo "branchstat: --of needs a branch" >&2; exit 2; }
      ;;
    --of=*) tip_rev="${1#--of=}" ;;
    --depth)
      shift
      maxdepth="${1:-}"
      ;;
    --depth=*) maxdepth="${1#--depth=}" ;;
    -*) echo "branchstat: unknown option $1" >&2; exit 2 ;;
    *) base_arg="$1" ;;
  esac
  shift
done

if [ -n "$tip_rev" ] && ! git rev-parse --verify --quiet "$tip_rev" > /dev/null; then
  echo "branchstat: unknown revision $tip_rev" >&2
  exit 2
fi

case "$maxdepth" in
  '' | *[!0-9]*) echo "branchstat: --depth wants a whole number" >&2; exit 2 ;;
esac
[ "$maxdepth" -ge 1 ] || { echo "branchstat: --depth wants at least 1" >&2; exit 2; }

# --classify exposes the bucketing on its own: it is the only real logic there,
# it drifts silently when a naming convention changes, and it answers "why is
# this file counted as source?" without re-reading the regexes. It reads paths
# instead of measuring a range, so it answers alone and ignores the rest — but it
# is parsed like every other flag, in whatever position the caller puts it.
if [ "$classify" = 1 ]; then
  if ! have_node; then
    echo "branchstat: --classify needs node" >&2
    exit 2
  fi
  report_ts --classify
  exit 0
fi

title='## Branch size — net diff by bucket'

# Everything below reads the repo as a whole: the `-- .` pathspec and cloc's
# scan only agree at the top level, and the footer has to resolve HEAD in the
# same repo the tip came from. Run from there, wherever the caller stood — which
# is the repo containing the cwd, not the one containing this file.
ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# One trap for every scratch file the run creates.
scratch=()
cleanup() {
  [ ${#scratch[@]} -gt 0 ] && rm -f "${scratch[@]}"
  return 0
}
trap cleanup EXIT

# Colour only when a human is watching: a pipe, a CI log or NO_COLOR gets none.
# 256 colours buy a grey ramp with one shade per rollup level; 8 or 16 buy two
# steps, bold then dim, because that is all the base attributes distinguish.
colour=0
if [ "$render" = text ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  colour=16
  [ "$(tput colors 2> /dev/null || echo 0)" -ge 256 ] && colour=256
fi

base_branch() {
  if [ -n "$base_arg" ]; then
    echo "$base_arg"
    return
  fi
  # The meaningful base is the PR's own base branch, not main: a PR stacked on
  # another targets its parent branch. `gh pr view` answers for the checked-out
  # branch when no rev is named, and for the branch named with --of otherwise. A
  # missing gh, no PR, or no network all land on the same empty answer and the
  # fallbacks below.
  local parent cand
  if [ -n "$tip_rev" ]; then
    parent="$(gh pr view "$tip_rev" --json baseRefName --jq .baseRefName 2>/dev/null || true)"
  else
    parent="$(gh pr view --json baseRefName --jq .baseRefName 2>/dev/null || true)"
  fi
  if [ -n "$parent" ]; then
    # `baseRefName` is a fact about the remote, so the remote-tracking ref is its
    # correct reading. A local branch of the same name is only a branch sharing
    # the name, and nothing keeps it current: from a worktree it is the main
    # checkout's `main`, arbitrarily far behind. Preferring it measured the
    # branch against commits it already contains — silently, since a report on
    # the wrong base looks exactly like a report.
    #
    # The local ref stays the fallback, for a base that has no remote-tracking
    # ref: a PR stacked on a parent branch not pushed yet, or a repo with no
    # remote at all.
    for cand in "origin/$parent" "$parent"; do
      if git rev-parse --verify --quiet "$cand" > /dev/null; then
        echo "$cand"
        return
      fi
    done
  fi
  git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null && return
  echo main
}

base="$(base_branch)"
merge_base="$(git merge-base "$base" "${tip_rev:-HEAD}")"

# The tip includes the working tree — uncommitted work is still work, and a
# branch is read mid-flight far more often than right after a commit. Both git
# and cloc want a rev, so the working tree is snapshotted into a throwaway commit
# through a scratch index: the real index and the real HEAD are never touched.
# `git add -A` there also picks up untracked files (a whole new module would
# otherwise read as nothing) while still honouring .gitignore. The agent's own
# worktrees are left out of it: a repo that does not ignore `.claude/worktrees`
# would otherwise have every branch it has ever checked out land in the total,
# as gitlinks nothing will ever commit.
#
# A branch named with --of is read as it is committed: it is not the checked-out
# one, so there is no working tree of its own to fold in.
tip=HEAD
tip_label="$(git rev-parse --short HEAD)"
if [ -n "$tip_rev" ]; then
  tip="$tip_rev"
  tip_label="$tip_rev"
elif [ -n "$(git status --porcelain)" ]; then
  scratch_index="$(mktemp)"
  scratch+=("$scratch_index")
  GIT_INDEX_FILE="$scratch_index" git read-tree HEAD
  GIT_INDEX_FILE="$scratch_index" git -c advice.addEmbeddedRepo=false \
    add -A ":(top)" ":(exclude).claude/worktrees"
  tip="$(git commit-tree "$(GIT_INDEX_FILE="$scratch_index" git write-tree)" \
    -p HEAD -m 'branchstat: working tree snapshot')"
  tip_label=worktree
fi

# What the breakdown leaves out. Generic enough to be right in a repo that says
# nothing; a repo that needs more says so in branchstat.json at its root, and
# its patterns are added to these rather than replacing them — the defaults are
# the ones nobody would want back. The file sits at the root and not under
# `.claude/`, because it is committed repo config — what this repo does not
# consider product code — read by a bash script that runs with or without
# Claude in the loop, not per-user agent state.
DEFAULT_EXCLUDES=(
  '*-lock.yaml' '*-lock.json' 'yarn.lock' 'bun.lockb'
  '*.md' '*.mdx' 'docs/' '.changeset/'
  'node_modules/' 'dist/' 'build/' 'coverage/' '.next/' 'vendor/'
  'components/ui/'
  'public/' 'assets/' 'fixtures/' '__snapshots__/'
  '.claude/worktrees/'
)

excludes=("${DEFAULT_EXCLUDES[@]}")
if [ -f "$ROOT_DIR/branchstat.json" ]; then
  while IFS= read -r pattern; do
    [ -n "$pattern" ] && excludes+=("$pattern")
  done < <(node -e '
    const fs = require("node:fs");
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    for (const p of cfg.exclude ?? []) console.log(p);
  ' "$ROOT_DIR/branchstat.json")
fi

# The same list in the two dialects that have to agree on it: git pathspecs for
# the emptiness check below, cloc regexes for the breakdown itself. Written once
# and translated, because a pattern that reaches one and not the other is a file
# the total counts and the buckets silently drop.
#
# git pathspec wildcards cross `/`, so `*/docs/*` reaches a nested directory
# while `mydocs/` stays out of it; the bare `docs` catches the top-level one,
# contents included. The magic is spelled long — `:!__snapshots__` reads its
# own leading underscore as a magic word and dies.
# One pattern, in the regex dialect cloc reads. Everything outside a small safe
# set is escaped, so no character class here has to be kept in sync with the
# patterns a repo might write; `*`, the one glob the patterns take, widens to a
# run of anything but a slash. Written in bash rather than piped through sed:
# the character class this needs is exactly the one that reads differently in
# BSD and GNU sed.
to_regex() {
  local p="$1" out="" c i
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    case "$c" in
      '*') out+='[^/]*' ;;
      [A-Za-z0-9_/-]) out+="$c" ;;
      *) out+="\\$c" ;;
    esac
  done
  printf '%s' "$out"
}

pathspecs=()
cloc_dirs=()
cloc_files=()
for pattern in "${excludes[@]}"; do
  case "$pattern" in
    */)
      dir="${pattern%/}"
      pathspecs+=(":(exclude)$dir" ":(exclude)*/$dir/*")
      cloc_dirs+=("$(to_regex "$dir")")
      ;;
    *)
      pathspecs+=(":(exclude)$pattern")
      case "$pattern" in
        */*) ;;                       # already anchored by its own directory
        *) pathspecs+=(":(exclude)*/$pattern") ;;
      esac
      cloc_files+=("(^|/)$(to_regex "$pattern")\$")
      ;;
  esac
done

join_alt() { local IFS='|'; printf '%s' "$*"; }
not_match_d="(^|/)($(join_alt "${cloc_dirs[@]}"))(/|\$)"
not_match_f="$(join_alt "${cloc_files[@]}")"

range="$(git rev-parse --short "$merge_base")…$tip_label"

# The total, plain: every file, whitespace included, no histogram — git's own
# defaults, which is what GitHub reports for a PR. Filtered with the exclusions
# below and -w it came out a few lines short of the PR page every time, and a
# headline that disagrees with the page it will be pasted under is worse than no
# headline. Rename detection is on by default in both, so it needs no flag.
#
# The note travels with the number rather than being written again at each of
# the three places that print it — the two fallbacks below included.
stat="$(git diff --shortstat "$merge_base".."$tip")"
stat="${stat# }"
if [ -n "$stat" ]; then
  stat="$stat · as GitHub counts it"
fi

# What the breakdown will count, read for its emptiness alone: a branch whose
# whole diff is a lockfile bump has a total and no buckets, which is a different
# answer from "no changes" and has to read as one.
counted="$(git diff --shortstat -w --ignore-blank-lines -M -C \
  --diff-algorithm=histogram "$merge_base".."$tip" -- . "${pathspecs[@]}")"

if [ -z "$stat" ]; then
  if [ "$render" = md ]; then
    printf '%s\n\n%s\n' "$title" "No changes against \`$base\`."
  else
    printf 'vs %s (%s)\n  no changes\n' "$base" "$range"
  fi
  exit 0
fi

if [ -z "$counted" ]; then
  # The total still prints: "3 files changed, 812 insertions" and nothing to
  # break down is the honest answer for a branch that only bumped a lockfile,
  # where a bare "no changes" would contradict the PR page.
  if [ "$render" = md ]; then
    printf '%s\n\n`%s` → `%s` · %s\n\n%s\n' "$title" "$base" "$tip_label" \
      "$stat" "_Nothing counted — every changed file is excluded from the breakdown._"
  else
    printf 'vs %s (%s)\n %s\n  nothing counted — every changed file is excluded\n' \
      "$base" "$range" "$stat"
  fi
  exit 0
fi

# The breakdown needs cloc to count code apart from comments and blanks, and the
# report needs node to lay it out. Neither is a hard requirement: the headline
# total is pure git, and it is the number a reader came for first. A missing tool
# costs the breakdown, says which tool and how to get it, and exits 0 — a CI job
# that only wanted the total should not go red over a runner's package list.
missing=""
command -v cloc > /dev/null || missing="cloc"
if [ -z "$missing" ] && ! have_node; then
  missing="node"
fi
if [ -n "$missing" ]; then
  install="brew install $missing"
  [ "$missing" = cloc ] && install="brew install cloc · apt-get install cloc · npx cloc"
  if [ "$render" = md ]; then
    printf '%s\n\n`%s` → `%s` · %s\n\n_%s is not installed — no bucket breakdown (`%s`)._\n' \
      "$title" "$base" "$tip_label" "$stat" "$missing" "$install"
  else
    printf 'vs %s (%s)\n %s\n(%s not installed — skipping the breakdown: %s)\n' \
      "$base" "$range" "$stat" "$missing" "$install"
  fi
  exit 0
fi

# A tool that is present can still buy nothing: cloc exits non-zero, or it
# exits 0 having printed something the report cannot parse. Under `set -e` one
# unguarded pipeline would die whole and take the headline with it — the one
# number that is pure git and already in hand by now. So when either staged
# step below fails, the run lands here instead: the headline prints, a note
# says which leg did not run and why, and the exit is 0 for the same reason as
# the missing-tool block above. Only the note on stdout is the contract — the
# tools' own stderr is left alone, so their diagnostics stay visible.
skip_breakdown() {
  local reason="$1"
  if [ "$render" = md ]; then
    printf '%s\n\n`%s` → `%s` · %s\n\n_%s — no bucket breakdown._\n' \
      "$title" "$base" "$tip_label" "$stat" "$reason"
  else
    printf 'vs %s (%s)\n %s\n(%s — skipping the breakdown)\n' \
      "$base" "$range" "$stat" "$reason"
  fi
  exit 0
}

# The one setting that differs between the two renderings. A terminal is read at
# a glance, so it keeps eight rows per level and says how many it dropped; a PR
# comment is folded away and scrolls, so it drops none.
limit=8
if [ "$render" = md ]; then
  limit=9999
fi

# Same exclusions, cloc dialect. --fullpath makes both regexes match the whole
# path (default is basename-only, which cannot express a nested directory).
# --by-file so each file can be bucketed; .SUM still carries the totals.
# The report is built into a scratch file so the footer can be appended to it.
# cloc's output goes through one too, rather than a pipe: a pipe reports one
# status for both halves, and the note above wants to name the half that broke.
report="$(mktemp)"
scratch+=("$report")
cloc_json="$(mktemp)"
scratch+=("$cloc_json")
cloc_status=0
cloc --git --diff "$merge_base" "$tip" --quiet --json --fullpath --by-file \
  --not-match-d="$not_match_d" --not-match-f="$not_match_f" \
  > "$cloc_json" || cloc_status=$?
if [ "$cloc_status" -ne 0 ]; then
  skip_breakdown "cloc failed (exit $cloc_status)"
fi

# What the merge base already held, so the report can tell a module the branch
# grew from one it created.
base_tree="$(mktemp)"
scratch+=("$base_tree")
git ls-tree -r --name-only "$merge_base" > "$base_tree"

# cloc can also fail without saying so: exit 0, and output that is not the JSON
# the report reads — or nothing at all. The report's own parse is the detector
# for both, so its failure reads as cloc's output being unusable.
if ! report_ts --render "$render" --title "$title" --base "$base" --range "$range" \
  --tip "$tip_label" --stat "$stat" --colour "$colour" \
  --limit "$limit" --maxdepth "$maxdepth" --base-tree "$base_tree" \
  < "$cloc_json" > "$report"; then
  skip_breakdown "cloc produced no parsable output"
fi

if [ "$render" = md ]; then
  # The repro line names the invocation that produced these numbers, base
  # included — it was resolved, and a reader re-running without it may land on a
  # different one once the stack moves. It names the skill, not the script: the
  # script lives in the caller's own harness, at a path that is theirs alone, and
  # printing it would leak a home directory into a comment nobody else can run.
  repro="/branchstat${tip_rev:+ --of $tip_rev} $base"
  # A caller that reaches the script some other way says what to write instead.
  repro="${BRANCHSTAT_REPRO:-$repro}"
  # A named branch is a commit, so it needs no label — the range line above
  # already carries its name, and the footer's job is to link the commit. Only
  # the working tree needs one, being no commit at all.
  footer_label="$tip_label"
  if [ -n "$tip_rev" ]; then
    footer_label=""
  fi
  emit_footer "$report" "$repro" "$footer_label" "${tip_rev:-HEAD}"
fi
cat "$report"
