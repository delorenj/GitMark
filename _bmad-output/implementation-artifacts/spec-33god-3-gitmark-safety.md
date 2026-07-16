---
title: 'Harden GitMark checkpoint safety and resolver privacy'
type: 'bugfix'
created: '2026-07-16'
status: 'in-progress'
context:
  - 'AGENTS.md'
  - 'kimi-export-session_-20260716-160437.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Automated GitMark checkpoints can alter a caller's staged/unstaged boundary, report success after operational failures, and leave a failed rebase requiring manual surgery. Resolver and routing LLM calls can also disclose conflicted source material or provider credentials during unattended execution.

**Approach:** Make unattended checkpoints transactional and truthful, default hook-driven conflict resolution to local-only behavior, and keep external-provider credentials out of process arguments. Preserve the existing structural submodule resolver, bounded narration fallback, and opt-in manual LLM workflow.

## Boundaries & Constraints

**Always:** Preserve the caller's original index and branch when a checkpoint does not commit; return non-zero for fetch, submodule, push, commit, and cleanup failures; keep clean submodules pinned unless `GITMARK_SUBMODULE_SYNC=1`; keep hook mode offline unless explicitly opted in; redact outbound context; keep all provider credentials out of child-process argv; retain time-bounded deterministic fallbacks.

**Ask First:** Change the default behavior of an interactive resolver invocation; mutate installed host hooks, cron, or systemd configuration; publish, push, or merge the ticket branch; rotate or replace provider secrets.

**Never:** Print or persist plaintext provider keys; claim a rebase was aborted when abort failed; discard untracked work; silently turn a failed operational step green; absorb unrelated `.agents/` or session-export WIP into the implementation commit.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Unattended conflict | `GITMARK_HOOK=1`, conflicted text file | Resolver uses structural/local heuristics and sends no HTTP request | Abort unresolved text conflicts without data egress |
| Manual provider call | Explicit interactive provider configuration | Redacted context may be sent after disclosure; auth is not visible in argv | Provider failure falls back or returns non-zero according to caller contract |
| Commit blocked | Mixed staged, unstaged, and untracked work; hook rejects commit | Original index and branch are restored byte-for-byte | Exit non-zero and state that nothing was checkpointed |
| Missing index | New or unusual repository without an index file | Checkpoint can stage normally; failed commit restores index absence | Exit non-zero without a failed backup copy masking the real error |
| Rebase cleanup fails | Resolver fails and `git rebase --abort` fails | Repository remains honestly marked unsafe | Exit non-zero with actionable cleanup diagnostic |
| Clean submodule | Parent references a pinned clean submodule | Pinned commit remains unchanged by default | Sync only when explicit opt-in is set |

</frozen-after-approval>

## Code Map

- `bin/git-checkpoint` -- checkpoint transaction, routing, failure aggregation, rebase cleanup, and submodule orchestration.
- `bin/git-checkpoint-hook` -- unattended hook-mode entrypoint.
- `bin/git-ai-resolver` -- conflict inspection, outbound redaction, provider call, and structural resolution.
- `bin/gitmark-route` -- optional provider-backed branch routing; shares the credential-handling risk.
- `bin/gitmark-narrate` -- provider call and deterministic narration fallback.
- `tests/git-checkpoint-safety.sh` -- destructive-state and false-green regressions.
- `tests/ai-resolver-privacy.sh` -- outbound-data, hook-mode, and credential-privacy regressions.
- `tests/submodule-conflict.sh` and `tests/narrate.sh` -- established compatibility suites.

## Tasks & Acceptance

**Execution:**
- [ ] `bin/git-checkpoint` and `bin/git-checkpoint-hook` -- make staging, branch routing, and rebase cleanup transactional across success, failure, and interruption paths.
- [ ] `bin/git-ai-resolver`, `bin/gitmark-route`, and `bin/gitmark-narrate` -- pass auth without argv exposure; preserve hook-offline, disclosure, redaction, and bounded fallback behavior.
- [ ] `tests/git-checkpoint-safety.sh` -- cover missing-index restoration, routed-branch rollback, operational failures, and abort-failure truthfulness.
- [ ] `tests/ai-resolver-privacy.sh` and `tests/narrate.sh` -- prove hook mode emits no request and provider tokens cannot be recovered from live curl argv.
- [ ] `README.md` and `Makefile` -- document/install the supported entrypoints and expose a repeatable aggregate test target.

**Acceptance Criteria:**
- Given a blocked or interrupted checkpoint, when GitMark exits, then the original branch, staged set, unstaged set, and untracked files are preserved and the exit code is non-zero.
- Given any recorded fetch, submodule, push, commit, or cleanup failure, when the command completes, then it cannot report a successful zero exit.
- Given hook mode with an HTTP endpoint available, when a text conflict is processed, then the endpoint receives no request unless the operator explicitly opts in.
- Given a live provider call, when process argv is inspected, then no configured API key or Bearer value is present.
- Given all compatibility suites, when verification runs, then checkpoint safety, privacy, narration, and submodule resolution remain green.

## Spec Change Log

## Design Notes

Treat the index as a transaction with two valid starting states: present (restore exact bytes) or absent (remove any newly created index on rollback). Treat a router-created branch as part of the same transaction until the commit succeeds. Credential transport must use a protected input channel supported by curl rather than interpolating the key into command arguments.

## Verification

**Commands:**
- `bash -n bin/git-checkpoint bin/git-checkpoint-hook bin/git-ai-resolver bin/gitmark-route bin/gitmark-narrate tests/*.sh` -- expected: no syntax errors.
- `bash tests/git-checkpoint-safety.sh` -- expected: all safety assertions pass.
- `bash tests/ai-resolver-privacy.sh` -- expected: all privacy and argv assertions pass without real external calls.
- `bash tests/submodule-conflict.sh` -- expected: all structural and integration assertions pass.
- `bash tests/narrate.sh` -- expected: fallback, service-down, redaction, and provider-path assertions pass.
