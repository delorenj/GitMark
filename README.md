# GitMark

AI-powered git checkpoint and conflict resolution.

## What it does

- **git-checkpoint** - Stages, commits, integrates with main, and pushes. Handles submodules. Automatically resolves conflicts using the AI resolver. Commit messages are AI-narrated (see below). Router-created `wip/*` and `checkpoint/*` safety branches are always merged back into the default branch after a successful checkpoint, and the command finishes with that default branch checked out.
- **git-checkpoint-hook** - Runs the same checkpoint flow in unattended hook mode, where external conflict-resolution calls are disabled unless explicitly opted in.
- **gitmark-route** - When git-checkpoint is about to auto-commit from the default branch, this makes a quick LLM judgment call: create a recoverable `wip/<topic>` safety branch for substantial work, or checkpoint a tiny/safe change directly. A successful safety branch is pushed, fast-forwarded into the default branch, and left available as a recovery ref. Falls back to a `checkpoint/<date>` branch if the LLM is unavailable, so routing never blocks. Disable with `GITMARK_ROUTE=0`.
- **git-ai-resolver** - Analyzes git conflicts using an LLM (via OpenAI-compatible API) and resolves them autonomously. Falls back to heuristics when AI is unavailable.
- **gitmark-narrate** - Derives the checkpoint commit message from the agent session's prompts + tool calls (bloodbank events via candystore) blended with the staged diff. Best-effort and time-bounded; falls back to a deterministic diff-summary when the event store or LLM is unavailable.

## Install

```sh
git clone https://github.com/delorenj/GitMark.git
cd GitMark
make install
```

This will:

- Symlink all five commands (`git-checkpoint`, `git-checkpoint-hook`, `git-ai-resolver`, `gitmark-narrate`, and `gitmark-route`) into `~/.local/bin/`
- Create `~/.config/GitMark/config.toml` with defaults (if it doesn't exist)
- Install lefthook pre-commit hooks (if lefthook is installed)

### Installing lefthook (optional, for pre-commit hooks)

```sh
# macOS
brew install lefthook

# npm
npm install -g @evilmartians/lefthook
```

Then run `lefthook install` in the repo to enable pre-commit hooks.

## Uninstall

```sh
make uninstall
```

## Config

`~/.config/GitMark/config.toml`

```toml
provider = "ollama"
model = "qwen3.5:35b"
```

### Supported providers

| Provider          | Config value | API key env var                                | Endpoint                              |
| ----------------- | ------------ | ---------------------------------------------- | ------------------------------------- |
| Ollama            | `ollama`     | none (uses `OLLAMA_HOST` or `localhost:11434`) | `localhost:11434/v1`                  |
| OpenAI            | `openai`     | `OPENAI_API_KEY`                               | `api.openai.com/v1`                   |
| OpenRouter        | `openrouter` | `OPENROUTER_API_KEY`                           | `openrouter.ai/api/v1`                |
| Kimi for Coding   | `kimi`       | `KIMI_API_KEY`                                 | `api.kimi.com/coding/v1`              |

All providers use the OpenAI-compatible chat-completions schema. Override the
config path with the `GITMARK_CONFIG` env var.

#### Examples

Kimi for Coding (Moonshot AI). The `kimi-for-coding` model id is stable — the
backend transparently maps it to the latest coding model:

```toml
provider = "kimi"
model = "kimi-for-coding"
```

DeepSeek via OpenRouter (no separate provider needed — OpenRouter exposes it):

```toml
provider = "openrouter"
model = "deepseek/deepseek-v4-flash"
```

## Usage

```sh
# Checkpoint current repo (stage, commit, rebase, push)
git-checkpoint

# Checkpoint a specific repo
git-checkpoint ~/code/myproject

# Resolve conflicts in current repo
git-ai-resolver

# Resolve merge conflicts specifically
git-ai-resolver merge
```

## Commit narration

Instead of a generic `checkpoint: <timestamp> auto-commit`, `git-checkpoint`
asks `gitmark-narrate` for a message that actually tells the story of the work.
It blends two sources:

1. **Intent — bloodbank events.** The universal agent hooks publish every user
   prompt and tool call to [candystore](https://github.com/…/candystore). Narrate
   queries that HTTP API for this repo's events since the last commit
   (`GET /events?project=<repo>&from=<last-commit>&to=<now>`), giving the *why*
   and the decision chain — often a more accurate account than the diff alone.
2. **Ground truth — the staged diff.** `git diff --stat`, a truncated diff, and
   untracked files give the exact *what*.

Both are **redacted** for secret material, then a fast LLM (the same
`config.toml` provider/model and OpenAI-compatible path as `git-ai-resolver`)
produces a Conventional-Commits message (subject + short body + a
`Checkpoint: <ts> (gitmark)` trailer).

It is strictly **best-effort and time-bounded** — the checkpoint is never
blocked or failed by narration:

- candystore down / no events → narrate uses the diff only;
- LLM unreachable, out of quota, or slower than the timeout → deterministic
  diff-summary message;
- narration disabled or times out entirely → plain timestamp message.

| Knob | Default | Effect |
| ---- | ------- | ------ |
| `GITMARK_FAST=1` / `--fast` | off | Skip narration (fast timestamp/diff message) |
| `GITMARK_NARRATE=0` | on | Disable narration entirely |
| `GITMARK_NARRATE_TIMEOUT` | `45` | Seconds `git-checkpoint` allows for narration |
| `GITMARK_NARRATE_PROVIDER` / `_MODEL` | config | Override just for narration (`none` = off) |
| `GITMARK_CANDYSTORE_URL` | `http://127.0.0.1:8683` | candystore query API |

> **Note:** narration needs a *fast* provider to fit the timeout. Large local
> reasoning models (e.g. ollama `qwen3.x`) frequently exceed it and trigger the
> deterministic fallback — configure a fast cloud model (Kimi/OpenRouter) for
> real narratives, and make sure its API key is present in the cron/hook
> environment, not just your interactive shell.

## Privacy and external LLMs

`git-ai-resolver` can ask an LLM to choose a resolution strategy or to resolve
conflict markers. To do that it must send the conflicted file content, diffs,
and conflict markers to the configured provider's API (Kimi, OpenRouter,
OpenAI, or a local Ollama instance).

- **Local-only mode:** set `GITMARK_AI_RESOLVER_OFFLINE=1` to disable external
  LLM calls entirely. Submodule conflicts are still resolved structurally;
  text conflicts fall back to heuristics or abort.
- **Secret redaction:** conflict content is run through the same redaction
  rules used by `gitmark-route` and `gitmark-narrate` before it leaves the
  machine. High-signal patterns (tokens, keys, passwords, private keys,
  `Bearer …`) are scrubbed, but redaction is best-effort — do not rely on it
  as a guarantee.
- **Disclosure:** when an external LLM is about to be consulted, the resolver
  prints a warning naming the file and pointing to the offline toggle.

Use `GITMARK_AI_RESOLVER_OFFLINE=1` for sensitive repositories, air-gapped
environments, or whenever you do not want conflicted file contents sent to a
third-party API.

## Dependencies

- bash, git, curl, jq

## Secret Detection (Pre-commit Hooks)

This repository uses [lefthook](https://github.com/evilmartians/lefthook) to run pre-commit hooks that detect potential secrets:

- **API keys** (generic patterns, AWS keys, GitHub tokens, Slack tokens, etc.)
- **Private keys** (RSA, DSA, EC, PGP)
- **Environment files** (`.env`, `.local`, etc.)
- **Credential files** (`.aws/credentials`, `.ssh/id_*`, etc.)
- **Passwords and tokens** in config files

If a secret is detected, the commit will be blocked with instructions on how to proceed.

### Bypassing the check (NOT RECOMMENDED)

```sh
git commit --no-verify
```

### Adding exceptions

Edit `.lefthook-ignore` to add file patterns that should be skipped:

```
# Example: Skip test fixtures with mock secrets
test/fixtures/*

# Example: Skip specific config files
*.config.json
```
