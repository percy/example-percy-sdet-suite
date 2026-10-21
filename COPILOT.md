# Running the QA triage in GitHub Copilot

Same workflow as Claude Code. Only the entry point differs.

## Install (in this repo)

```bash
curl -fsSL https://raw.githubusercontent.com/percy/percy-visual-testing-agent/main/install.sh | bash -s -- --copilot --qa
```

This adds:
- the Percy prompts to `.github/prompts/` (`/percy-gate`, `/percy-review`, …)
- the skills to `.percy/skills/`
- a Percy section to `AGENTS.md` (this repo already has one, so it's kept)

In a real team repo, commit these so every QA engineer gets the commands.

## Run

1. Open this folder in VS Code. Launch it from a terminal where `.percy/.env` is loaded (`set -a; . .percy/.env; set +a; code .`), or make sure Copilot's terminal can see `PERCY_TOKEN`.
2. Copilot Chat → switch to **Agent** mode. Ask and Edit modes can't run commands.
3. Pick a strong model in the model picker.
4. Type `/percy-gate`. In JetBrains, Visual Studio or the Copilot CLI, if `/percy-gate` isn't offered, ask: *"run the percy gate workflow on last night's run"*.

## Check while you run it

| Check | ✓ |
|---|---|
| `/percy-gate` shows up when you type `/` in Chat | |
| It resolves the latest build on `nightly` (not your checked-out branch) | |
| It finds the PRs merged into your fork since the last approved run, and cites them | |
| The triage matches the table in BOOTSTRAP.md §4 | |
| Approve / flag only happen after you say yes | |
| How many times Copilot asked to approve a terminal command (note the number) | |
| If you set up an Atlassian MCP server in VS Code: the first run proposes Jira and asks how your team files bugs | |

## Known differences from Claude Code

- **Command approvals:** Copilot asks before each terminal command. To cut the clicks, auto-approve `curl` calls to percy.io and `gh` in VS Code's terminal auto-approve settings.
- **No background watching:** irrelevant for QA triage, because the nightly has already finished.
- **Org admins** (Copilot Business/Enterprise) must allow Agent mode, the model you pick, and MCP servers if you want Jira filing through MCP.
