#!/usr/bin/env bash
# Regression tests for git-checkpoint safety issues reported by a developer:
#   1. Commit failure after "git add -A" must restore the original index so
#      uncommitted work is not destroyed.
#   2. Operational failures (fetch, submodule update, submodule foreach,
#      submodule-pointer add) must produce a non-zero exit (no false greens).
#   3. A failing "git rebase --abort" must be reported and handled.
#
# Run: bash tests/git-checkpoint-safety.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)"
CHECKPOINT="$BIN/git-checkpoint"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gm-safety.XXXXXX")"
REAL_GIT="$(command -v git)"

export NO_COLOR=1
export HOME="$ROOT/home"; mkdir -p "$HOME"
export GITMARK_NARRATE=0
export GITMARK_ROUTE=0
export GIT_TERMINAL_PROMPTS=0
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
q(){ "$@" >/dev/null 2>&1; }

# --- Test 1: commit failure restores the original index -----------------------
test_commit_failure_restores_index() {
  echo "── commit failure restores the original index ──"
  local W="$ROOT/commit-failure"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'base\n' > file.txt
  q git add file.txt; q git commit -qm init

  # Staged change to tracked file + an unstaged untracked file.
  printf 'staged change\n' > file.txt
  q git add file.txt
  printf 'untracked content\n' > untracked.txt

  # Pre-commit hook that always fails.
  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
echo "pre-commit blocking intentionally"
exit 1
HOOK
  chmod +x .git/hooks/pre-commit

  local out="$ROOT/commit-failure.out"
  "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] && ok "checkpoint exits non-zero on commit failure" || no "expected non-zero exit, got $RC"

  # After a failed commit, the original index must be restored: file.txt staged,
  # untracked.txt still untracked.
  local staged untracked
  staged="$(git diff --cached --name-only | sort)"
  untracked="$(git status --porcelain | grep '^??' | awk '{print $2}' | sort)"

  [[ "$staged" == "file.txt" ]] && ok "tracked file remains staged" || no "unexpected staged files: '$staged'"
  [[ "$untracked" == "untracked.txt" ]] && ok "untracked file remains untracked" || no "unexpected untracked files: '$untracked'"

  grep -q "Nothing was checkpointed" "$out" && ok "user is told nothing was checkpointed" || no "missing 'Nothing was checkpointed' message"
}

# --- Test 2: fetch failure produces a non-zero exit ---------------------------
test_fetch_failure_nonzero() {
  echo "── fetch failure produces a non-zero exit ──"
  local W="$ROOT/fetch-failure"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'init\n' > file.txt
  q git add file.txt; q git commit -qm init
  # Point origin at a path that does not exist so fetch fails deterministically.
  q git remote add origin "/nonexistent/repo-$(date +%s%N)"
  printf 'change\n' >> file.txt

  local out="$ROOT/fetch-failure.out"
  "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] && ok "checkpoint exits non-zero on fetch failure" || no "expected non-zero exit, got $RC"
  grep -qi "fetch failed" "$out" && ok "fetch failure is reported" || no "fetch failure not reported"
}

# --- Helpers for test 3 -------------------------------------------------------
make_conflict_repo() {
  local W="$1"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'base\n' > file.txt
  q git add file.txt; q git commit -qm init

  q git checkout -q -b feature
  printf 'base\nfeature line\n' > file.txt
  q git add file.txt; q git commit -qm feature

  q git checkout -q main
  printf 'base\nmain line\n' > file.txt
  q git add file.txt; q git commit -qm main
}

# Test 3: rebase abort failure is reported and non-zero.
# We force the abort path by making the AI resolver fail, then intercept
# "git rebase --abort" with a fake git wrapper so it cannot succeed.
test_rebase_abort_failure() {
  echo "── rebase abort failure is reported ──"
  local W="$ROOT/rebase-abort"
  make_conflict_repo "$W"

  # Set up a real remote with main so the rebase target exists.
  q git init -q --bare "$W/remote.git"
  q git push "$W/remote.git" main

  # Fake AI resolver that always fails -> git-checkpoint tries to abort.
  local fake_resolver="$ROOT/fake-ai-resolver"
  cat > "$fake_resolver" <<'FAKE'
#!/bin/bash
exit 1
FAKE
  chmod +x "$fake_resolver"

  # Fake git wrapper: every command delegates to the real git except
  # "git rebase --abort", which fails loudly.
  local fake_git_dir="$ROOT/fake-git"
  mkdir -p "$fake_git_dir"
  cat > "$fake_git_dir/git" <<FG
#!/bin/bash
if [[ "\$1" == "rebase" && "\$2" == "--abort" ]]; then
  echo "fatal: could not abort rebase" >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
FG
  chmod +x "$fake_git_dir/git"

  cd "$W"
  q git checkout -q feature
  # Point origin to the bare repo so the rebase is attempted.
  q git remote add origin "$W/remote.git"

  local out="$ROOT/rebase-abort.out"
  GITMARK_AI_RESOLVER="$fake_resolver" \
    PATH="$fake_git_dir:$PATH" \
    "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] && ok "checkpoint exits non-zero when rebase abort fails" || no "expected non-zero exit, got $RC"
  grep -qi "could not abort rebase" "$out" && ok "abort failure is reported to the user" || no "abort failure not reported"
}

# --- Test 4: operational submodule/foreach failures produce non-zero exit -----
# We use a fake git wrapper that fails on "git submodule update --init --recursive"
# and "git submodule foreach" so the script records the failure.
test_submodule_operations_failure() {
  echo "── submodule operations failure produces a non-zero exit ──"
  local W="$ROOT/submodule-ops"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'init\n' > file.txt
  q git add file.txt; q git commit -qm init

  # Pretend we have submodules so the script enters the submodule block.
  cat > .gitmodules <<'GITMODULES'
[submodule "fake"]
	path = fake
	url = https://example.com/fake.git
GITMODULES
  q git add .gitmodules; q git commit -qm "add gitmodules"

  # Fake git wrapper fails submodule update and foreach deterministically.
  local fake_git_dir="$ROOT/fake-git-sub"
  mkdir -p "$fake_git_dir"
  cat > "$fake_git_dir/git" <<'FG'
#!/bin/bash
if [[ "$1" == "submodule" && "$2" == "update" && "$3" == "--init" ]]; then
  echo "fatal: submodule update failed" >&2
  exit 1
fi
if [[ "$1" == "submodule" && "$2" == "foreach" ]]; then
  echo "fatal: submodule foreach failed" >&2
  exit 1
fi
exec /usr/bin/git "$@"
FG
  chmod +x "$fake_git_dir/git"

  local out="$ROOT/submodule-ops.out"
  PATH="$fake_git_dir:$PATH" "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] && ok "checkpoint exits non-zero on submodule operation failure" || no "expected non-zero exit, got $RC"
  grep -qi "submodule" "$out" && ok "submodule failure is reported" || no "submodule failure not reported"
}

# --- Run ----------------------------------------------------------------------
echo "===== git-checkpoint safety regression ====="
test_commit_failure_restores_index
test_fetch_failure_nonzero
test_rebase_abort_failure
test_submodule_operations_failure

echo ""
echo "=== git-checkpoint safety tests: $PASS passed, $FAIL failed ==="
cd /
rm -rf "$ROOT"
[[ "$FAIL" -eq 0 ]]
