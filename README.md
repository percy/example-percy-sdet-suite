# Lumina nightly regression suite: Percy QA-triage sandbox

A small **QA-owned regression suite** (Playwright + Percy) for the [Lumina Home storefront](https://github.com/percy/example-percy-sdet-app), which lives in its own repo. Use it to try the **[Percy Visual Testing Agent](https://github.com/percy/percy-visual-testing-agent)'s QA workflow** in your coding agent (Claude Code, GitHub Copilot, Cursor, Codex, Gemini):

> 9am. Last night's regression run has changes. Two app PRs merged yesterday, and someone also pushed a hotfix without a PR. The agent sorts every diff:
> - **explained** by a merged PR (cited)
> - **noise** (a rotating promo strip)
> - **unexplained or broken** (the hotfix)
>
> Then it approves the explained ones, flags the rest and offers to file the bug, with your confirmation at every step.

## Quick start

Follow **[BOOTSTRAP.md](BOOTSTRAP.md)**. It's written so you can hand it to your coding agent ("read BOOTSTRAP.md and set this up"). In short:

```bash
gh repo clone percy/example-percy-sdet-suite && cd example-percy-sdet-suite
./scripts/demo.sh setup             # forks + clones the app, installs deps, checks your Percy token
./scripts/demo.sh fresh             # first nightly run, approved as the baseline (needs PERCY_USERNAME/ACCESS_KEY, or approve it in Percy)
./scripts/demo.sh morning           # merge 2 app PRs + a bad deploy, run the nightly
# then, in your agent: triage last night's run (Claude Code or Copilot: /percy-gate)
```

What you need:
- Node 18+
- the GitHub CLI, logged in
- a Percy account and a web project (free works; Percy AI needs a paid plan or trial, so without it the agent runs in its no-AI mode)

For GitHub Copilot specifics, see [COPILOT.md](COPILOT.md).

## What's in here

| Path | What |
|---|---|
| `tests/` | The nightly suite: Home, Shop, Product Detail, Cart, plus Journal with a rotating promo strip (dynamic content by design) |
| `.percy/config.yml` | Tells the agent this is a QA suite: regression branch `nightly`, and which repo the app code lives in |
| `AGENTS.md` | Agent instructions: morning triage |
| `scripts/demo.sh` | Sandbox driver: setup, nightly, morning, fix-deploy, reset |
