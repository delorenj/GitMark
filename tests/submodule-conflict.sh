#!/usr/bin/env bash
# Regression test for git-ai-resolver's submodule (gitlink) conflict handling.
#
# Reproduces the production failure where an auto-checkpointed submodule pointer
# DIVERGES from the remote ("Recursive merging with submodules currently only
# supports trivial cases" / "commits don't follow merge-base") during a
# pull --rebase, and asserts the resolver now auto-resolves it deterministically.
#
# Two layers:
#   UNIT        - drive git-ai-resolver directly against a manufactured gitlink
#                 conflict; verify newest/ours/theirs selection + push.
#   INTEGRATION - run the REAL git-checkpoint end-to-end and verify it completes.
#
# Needs no network or AI: gitlink conflicts are resolved structurally.
# Run:  bash tests/submodule-conflict.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)"
RESOLVER="$BIN/git-ai-resolver"
CHECKPOINT="$BIN/git-checkpoint"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gm-subtest.XXXXXX")"

export NO_COLOR=1
# Isolated HOME: set protocol.file.allow + identity without touching real config.
# Point the resolver at the real GitMark config if present (only the AI path
# needs it; submodule resolution does not).
export HOME="$ROOT/home"; mkdir -p "$HOME"
[[ -f "$HERE/../config/config.toml" ]] && export GITMARK_CONFIG="$HERE/../config/config.toml"
[[ -f "/home/$(id -un)/.config/GitMark/config.toml" ]] && export GITMARK_CONFIG="/home/$(id -un)/.config/GitMark/config.toml"
git config --global protocol.file.allow always
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
git config --global advice.detachedHead false

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
q(){ "$@" >/dev/null 2>&1; }
in_rebase(){ local gd; gd="$(git rev-parse --git-dir)"; [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]]; }

# Build a world with a submodule whose pointer has DIVERGED from an ahead remote.
# $1=newer side (local|remote)  $2=workdir. Echoes "BASE X Y" (X local, Y remote).
build_world() {
  local newer="$1" W="$2" xdate ydate
  if [[ "$newer" == "local" ]]; then xdate=2026-03-01T00:00:00; ydate=2026-02-01T00:00:00
  else                                xdate=2026-02-01T00:00:00; ydate=2026-03-01T00:00:00; fi
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
  q git init --bare super.git; q git init --bare sub.git

  # Submodule: BASE with two divergent children X and Y (neither an ancestor).
  q git clone sub.git subseed
  ( cd subseed
    echo base>f; GIT_COMMITTER_DATE=2026-01-01T00:00:00 GIT_AUTHOR_DATE=2026-01-01T00:00:00 git add . \
      && GIT_COMMITTER_DATE=2026-01-01T00:00:00 git commit -qm base
    git checkout -qb x; echo x>f; GIT_COMMITTER_DATE=$xdate GIT_AUTHOR_DATE=$xdate git add . \
      && GIT_COMMITTER_DATE=$xdate git commit -qm X
    git checkout -q main; echo y>f; GIT_COMMITTER_DATE=$ydate GIT_AUTHOR_DATE=$ydate git add . \
      && GIT_COMMITTER_DATE=$ydate git commit -qm Y
    q git push origin main; q git push origin x )
  local BASE X Y
  BASE=$(git -C subseed rev-parse main~1); X=$(git -C subseed rev-parse x); Y=$(git -C subseed rev-parse main)

  # Super C0: sub=BASE.
  q git clone super.git superseed
  ( cd superseed
    git -c protocol.file.allow=always submodule add -q ../sub.git sub
    ( cd sub && q git checkout "$BASE" )
    q git add .; git commit -qm "C0: sub=BASE"; q git push origin HEAD:main )

  # Our clone (at C0) points sub at X; remote later moves to Y on a divergent line.
  q git clone super.git work
  ( cd work
    q git -c protocol.file.allow=always submodule update --init
    ( cd sub && q git fetch origin && q git checkout "$X" )
    q git add sub; git commit -qm "C1_local: sub=X" )
  q git clone super.git remoteclone
  ( cd remoteclone
    q git -c protocol.file.allow=always submodule update --init
    ( cd sub && q git fetch origin && q git checkout "$Y" )
    q git add sub; git commit -qm "C1_remote: sub=Y"; q git push origin HEAD:main )

  echo "$BASE $X $Y"
}

unit_case() {
  local label="$1" newer="$2" mode="${3:-}" W="$ROOT/unit-$1"
  echo "── UNIT: $label (newer=$newer mode=${mode:-newest}) ──"
  read -r _ X Y <<<"$(build_world "$newer" "$W")"
  cd "$W/work" || { no setup; return; }
  q git -c protocol.file.allow=always pull --rebase origin main
  in_rebase || { no "expected a rebase conflict"; return; }
  git diff --name-only --diff-filter=U | grep -qx sub || { no "expected gitlink 'sub' conflicted"; return; }
  ok "reproduced submodule gitlink conflict during rebase"

  if [[ -n "$mode" ]]; then export GITMARK_SUBMODULE_CONFLICT="$mode"; else unset GITMARK_SUBMODULE_CONFLICT; fi
  GIT_EDITOR=true "$RESOLVER" rebase >/dev/null 2>&1 && ok "resolver exited 0" || no "resolver exited non-zero"
  in_rebase && no "rebase still in progress" || ok "rebase completed"
  git diff --name-only --diff-filter=U | grep -q . && no "unmerged entries remain" || ok "no unmerged entries"

  local expect got
  case "${mode:-newest}" in
    ours)   expect="$Y" ;;                                   # rebase: stage2(ours)=remote=Y
    theirs) expect="$X" ;;                                   # rebase: stage3(theirs)=local=X
    *)      [[ "$newer" == local ]] && expect="$X" || expect="$Y" ;;
  esac
  got="$(git ls-files -s sub | awk '{print $2}')"
  [[ "$got" == "$expect" ]] && ok "submodule pointer = expected (${expect:0:9})" || no "pointer ${got:0:9} != ${expect:0:9}"
  q git -c protocol.file.allow=always push origin HEAD:main && ok "push succeeds" || no "push fails"
}

integration_case() {
  echo "── INTEGRATION: real git-checkpoint, newest wins ──"
  unset GITMARK_SUBMODULE_CONFLICT   # default behavior (newest); don't inherit a unit-case override
  local W="$ROOT/integration"
  read -r _ _ Y <<<"$(build_world remote "$W")"   # remote(Y) is newer -> expected winner
  cd "$W/work" || { no setup; return; }
  if "$CHECKPOINT" "$PWD" >/tmp/gm-subtest-int.out 2>&1; then ok "git-checkpoint exited 0"; else no "git-checkpoint exited non-zero"; sed 's/^/      /' /tmp/gm-subtest-int.out; fi
  grep -q "CONFLICT (submodule)" /tmp/gm-subtest-int.out && ok "exercised the submodule-conflict path" || no "did not hit the submodule conflict (test no longer reproduces)"
  in_rebase && no "rebase left in progress" || ok "no rebase left in progress"
  q git fetch origin
  [[ "$(git ls-tree origin/main sub | awk '{print $3}')" == "$Y" ]] && ok "remote submodule pointer = newest (Y)" || no "remote pointer != Y"
  git merge-base --is-ancestor origin/main HEAD 2>/dev/null && ok "local HEAD contains remote history" || no "local HEAD missing remote history"
}

echo "===== git-ai-resolver submodule-conflict regression ====="
unit_case newest-local-wins  local
unit_case newest-remote-wins remote
unit_case force-ours         local  ours
unit_case force-theirs       remote theirs
integration_case
echo
echo "===== RESULT: $PASS passed, $FAIL failed ====="
cd /; rm -rf "$ROOT"
[[ "$FAIL" -eq 0 ]]
