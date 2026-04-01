# GitMark

AI-powered git checkpoint and conflict resolution.

## What it does

- **git-checkpoint** - Stages, commits, rebases onto main, and pushes. Handles submodules. Automatically resolves conflicts using the AI resolver.
- **git-ai-resolver** - Analyzes git conflicts using an LLM (via OpenAI-compatible API) and resolves them autonomously. Falls back to heuristics when AI is unavailable.

## Install

```sh
git clone https://github.com/hellosubconscious/GitMark.git ~/code/GitMark
cd ~/code/GitMark
make install
```

This will:
- Symlink `git-checkpoint` and `git-ai-resolver` into `~/.local/bin/`
- Create `~/.config/GitMark/config.toml` with defaults (if it doesn't exist)
- Install lefthook pre-commit hooks (if lefthook is installed)

### Installing lefthook (optional, for pre-commit hooks)

```sh
# macOS
brew install lefthook

# Debian/Ubuntu
curl -1sLf 'https://dl.cloudsmith.io/public/evilmartians/lefthook/setup.deb.sh' | sudo -E bash
sudo apt install lefthook

# npm
npm install -g @evilmartians/lefthook
```

Then run `lefthook install` in the repo to enable pre-commit hooks.

## Uninstall

```sh
cd ~/code/GitMark
make uninstall
```

## Config

`~/.config/GitMark/config.toml`

```toml
provider = "ollama"
model = "qwen3.5:35b"
```

### Supported providers

| Provider | Config value | API key env var |
|----------|-------------|-----------------|
| Ollama | `ollama` | none (uses `OLLAMA_HOST` or `localhost:11434`) |
| OpenAI | `openai` | `OPENAI_API_KEY` |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` |

Override config path with `GITMARK_CONFIG` env var.

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
