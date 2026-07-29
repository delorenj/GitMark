#!/usr/bin/env bash
# Regression tests for git-checkpoint safety issues reported by a developer:
#   1. Commit failure after "git add -A" must restore the original index so
#      uncommitted work is not destroyed.
#   2. A repository with no index must restore that exact absence on rollback.
#   3. A built-in secret-guard rejection must restore the original index.
#   4. A routed checkpoint whose commit fails must return to its original branch.
#   5. Operational failures (fetch, submodule update, submodule foreach,
#      submodule-pointer add) must produce a non-zero exit (no false greens).
#   6. A failing "git rebase --abort" must be reported and handled.
#   4. GitMark-owned checkpoint branches must converge into main on success,
#      while a convergence failure preserves the checkpoint branch.
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

# --- Test 1b: missing index remains absent after a failed commit ---------------
test_commit_failure_restores_missing_index() {
  echo "── commit failure restores an originally missing index ──"
  local W="$ROOT/missing-index"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'first content\n' > first.txt
  [[ ! -e .git/index ]] || { no "test precondition: index should be absent"; return; }

  mkdir -p .git/hooks
  cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
exit 1
HOOK
  chmod +x .git/hooks/pre-commit

  local out="$ROOT/missing-index.out"
  "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] &&
    ok "checkpoint exits non-zero with an originally missing index" ||
    no "expected non-zero exit, got $RC"
  [[ ! -e .git/index ]] &&
    ok "index absence is restored exactly" ||
    no "checkpoint left a new index behind"
  [[ "$(git status --porcelain)" == "?? first.txt" ]] &&
    ok "first file remains untracked" ||
    no "first file state changed during rollback"
}

# --- Test 1c: secret-guard rejection restores the original index --------------
test_secret_guard_restores_index() {
  echo "── secret-guard rejection restores original index ──"
  local W="$ROOT/secret-guard"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'base\n' > tracked.txt
  q git add tracked.txt
  q git commit -qm init

  printf 'staged edit\n' > tracked.txt
  q git add tracked.txt
  local fake_secret
  fake_secret="ghp_$(printf 'A%.0s' $(seq 1 36))"
  printf '%s\n' "$fake_secret" > leaked.txt

  local out="$ROOT/secret-guard.out"
  "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] &&
    ok "secret-guard rejection exits non-zero" ||
    no "expected non-zero exit, got $RC"
  [[ "$(git diff --cached --name-only)" == "tracked.txt" ]] &&
    ok "pre-existing staged file remains staged" ||
    no "secret-guard changed the original staged set"
  [[ "$(git status --porcelain | grep '^??' | awk '{print $2}')" == "leaked.txt" ]] &&
    ok "rejected secret file remains untracked" ||
    no "secret-guard changed the rejected file state"
}

# --- Test 1d: a routed commit failure returns to the original branch ----------
test_routed_commit_failure_restores_branch() {
  echo "── routed commit failure returns to original branch ──"
  local W="$ROOT/routed-commit-failure" R="$ROOT/routed-commit-failure.git"
  local router="$ROOT/routed-commit-failure-router"
  make_routed_repo "$W" "$R"
  make_branch_router "$router"
  printf 'staged before checkpoint\n' > "$W/hourly.md"
  q git -C "$W" add hourly.md

  mkdir -p "$W/.git/hooks"
  cat > "$W/.git/hooks/pre-commit" <<'HOOK'
#!/bin/bash
exit 1
HOOK
  chmod +x "$W/.git/hooks/pre-commit"

  local out="$ROOT/routed-commit-failure.out"
  GITMARK_ROUTE=1 GITMARK_ROUTE_BIN="$router" \
    "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] &&
    ok "routed checkpoint reports commit failure" ||
    no "expected non-zero exit, got $RC"
  [[ "$("$REAL_GIT" -C "$W" branch --show-current)" == "main" ]] &&
    ok "original main branch is restored" ||
    no "checkpoint stranded work on a routed branch"
  [[ "$("$REAL_GIT" -C "$W" diff --cached --name-only)" == "hourly.md" ]] &&
    ok "original staged state survives routed rollback" ||
    no "routed rollback changed the staged state"
  ! "$REAL_GIT" --git-dir="$R" show wip/hourly-docs:hourly.md >/dev/null 2>&1 &&
    ok "failed checkpoint was not pushed" ||
    no "failed checkpoint unexpectedly reached the remote"
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

# --- Helpers for routed-checkpoint convergence tests --------------------------
make_routed_repo() {
  local W="$1" R="$2"
  mkdir -p "$W"; cd "$W"
  q git init -q
  printf 'base\n' > README.md
  q git add README.md; q git commit -qm init
  q git init -q --bare "$R"
  q git remote add origin "$R"
  q git push -u origin main
  q git --git-dir="$R" symbolic-ref HEAD refs/heads/main
}

make_branch_router() {
  local path="$1"
  cat > "$path" <<'ROUTER'
#!/bin/bash
printf '%s\n' '{"route":"branch","slug":"hourly-docs","reason":"test"}'
ROUTER
  chmod +x "$path"
}

# --- Test 5: a routed checkpoint merges to main and finishes on main ----------
test_routed_checkpoint_converges_to_main() {
  echo "── routed checkpoint converges to main ──"
  local W="$ROOT/route-success" R="$ROOT/route-success.git"
  local router="$ROOT/route-success-router"
  make_routed_repo "$W" "$R"
  make_branch_router "$router"
  printf 'hourly checkpoint\n' > "$W/hourly.md"

  local out="$ROOT/route-success.out"
  GITMARK_ROUTE=1 GITMARK_ROUTE_BIN="$router" \
    "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -eq 0 ]] && ok "routed checkpoint exits zero" || no "expected zero exit, got $RC"
  [[ "$("$REAL_GIT" -C "$W" branch --show-current)" == "main" ]] \
    && ok "main is checked out after success" || no "checkpoint did not finish on main"
  "$REAL_GIT" --git-dir="$R" show main:hourly.md >/dev/null 2>&1 \
    && ok "remote main contains checkpoint" || no "remote main is missing checkpoint"
  "$REAL_GIT" -C "$W" show-ref --verify --quiet refs/heads/wip/hourly-docs \
    && ok "local checkpoint branch is preserved" || no "local checkpoint branch missing"
  "$REAL_GIT" --git-dir="$R" show-ref --verify --quiet refs/heads/wip/hourly-docs \
    && ok "remote checkpoint branch is preserved" || no "remote checkpoint branch missing"
  [[ "$("$REAL_GIT" -C "$W" rev-parse main)" == "$("$REAL_GIT" -C "$W" rev-parse wip/hourly-docs)" ]] \
    && ok "main fast-forwarded to checkpoint tip" || no "main and checkpoint tip differ"
}

# --- Test 6: failed main checkout preserves the checkpoint branch -------------
test_routed_checkpoint_switch_failure_is_safe() {
  echo "── routed checkpoint switch failure preserves branch ──"
  local W="$ROOT/route-switch-failure" R="$ROOT/route-switch-failure.git"
  local router="$ROOT/route-failure-router"
  make_routed_repo "$W" "$R"
  make_branch_router "$router"
  printf 'hourly checkpoint\n' > "$W/hourly.md"

  local fake_git_dir="$ROOT/fake-git-switch"
  mkdir -p "$fake_git_dir"
  cat > "$fake_git_dir/git" <<FG
#!/bin/bash
if [[ "\$1" == "switch" && "\${2:-}" == "main" ]]; then
  exit 1
fi
if [[ "\$1" == "checkout" && "\${2:-}" == "main" ]]; then
  exit 1
fi
exec "$REAL_GIT" "\$@"
FG
  chmod +x "$fake_git_dir/git"

  local out="$ROOT/route-switch-failure.out"
  GITMARK_ROUTE=1 GITMARK_ROUTE_BIN="$router" PATH="$fake_git_dir:$PATH" \
    "$CHECKPOINT" "$W" >"$out" 2>&1; RC=$?

  [[ $RC -ne 0 ]] && ok "checkpoint exits non-zero when main checkout fails" || no "expected non-zero exit, got $RC"
  [[ "$("$REAL_GIT" -C "$W" branch --show-current)" == "wip/hourly-docs" ]] \
    && ok "checkpoint branch remains checked out" || no "checkpoint branch was not preserved"
  "$REAL_GIT" --git-dir="$R" show wip/hourly-docs:hourly.md >/dev/null 2>&1 \
    && ok "remote checkpoint branch retains commit" || no "remote checkpoint branch lost commit"
  ! "$REAL_GIT" --git-dir="$R" show main:hourly.md >/dev/null 2>&1 \
    && ok "remote main was not partially updated" || no "remote main changed despite convergence failure"
  grep -qi "preserv" "$out" \
    && ok "failure explains checkpoint preservation" || no "missing preservation diagnostic"
}

# --- Run ----------------------------------------------------------------------
echo "===== git-checkpoint safety regression ====="
test_commit_failure_restores_index
test_commit_failure_restores_missing_index
test_secret_guard_restores_index
test_routed_commit_failure_restores_branch
test_fetch_failure_nonzero
test_rebase_abort_failure
test_submodule_operations_failure
test_routed_checkpoint_converges_to_main
test_routed_checkpoint_switch_failure_is_safe

echo ""
echo "=== git-checkpoint safety tests: $PASS passed, $FAIL failed ==="
cd /
rm -rf "$ROOT"
[[ "$FAIL" -eq 0 ]]
