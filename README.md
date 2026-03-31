# gittyup

AI-powered git checkpoint and conflict resolution.

## What it does

- **git-checkpoint** - Stages, commits, rebases onto main, and pushes. Handles submodules. Automatically resolves conflicts using the AI resolver.
- **git-ai-resolver** - Analyzes git conflicts using an LLM (via OpenAI-compatible API) and resolves them autonomously. Falls back to heuristics when AI is unavailable.

## Install

```sh
git clone https://github.com/hellosubconscious/gittyup.git ~/code/gittyup
cd ~/code/gittyup
make install
```

This will:
- Symlink `git-checkpoint` and `git-ai-resolver` into `~/.local/bin/`
- Create `~/.config/gittyup/config.toml` with defaults (if it doesn't exist)

## Uninstall

```sh
cd ~/code/gittyup
make uninstall
```

## Config

`~/.config/gittyup/config.toml`

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

Override config path with `GITTYUP_CONFIG` env var.

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
