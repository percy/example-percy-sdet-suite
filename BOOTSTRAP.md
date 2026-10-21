# Bootstrap: set up the QA-triage sandbox

> **For a coding agent:** if a person asked you to set this up, follow the steps below in order. Run the commands yourself, stop at each **👤** step and wait for the person, and never ask them to paste a token or key into the chat: they type secrets into `.percy/.env` in their editor.

Everything here uses **your own** accounts: your GitHub user (a fork of the app repo) and your own Percy project. Nothing else is needed.

## 0. Prerequisites (check, don't assume)

- `node -v` → 18 or newer
- `gh auth status` → logged in (otherwise 👤 run `gh auth login`)
- A Percy account. 👤 If you don't have one, sign up at percy.io (the free plan works).
  - **Percy AI (the visual review agent) needs a paid plan or a trial.** Without it, the triage still runs, in the agent's no-AI mode: it lists every change with links, but can't classify them.

## 1. Clone and set up

```bash
gh repo clone percy/example-percy-sdet-suite
cd example-percy-sdet-suite
./scripts/demo.sh setup
```

Setup does four things:
- forks `percy/example-percy-sdet-app` into your GitHub account, because the demo merges PRs there
- clones it next to this repo
- points `.percy/config.yml → app_repos` at your fork
- installs dependencies

The first run stops and creates `.percy/.env` with an empty `PERCY_TOKEN=`.

👤 **Create a Percy web project** (percy.io → New project → Web). Then open `.percy/.env` **in your editor** and paste the project's full-access token from Project settings → Project token. Optionally, add your BrowserStack username and access key (`PERCY_USERNAME=` / `PERCY_ACCESS_KEY=`, from BrowserStack → Account) so approvals can happen from the terminal and the agent. Then re-run:

```bash
./scripts/demo.sh setup
```

## 2. First nightly → baseline

```bash
./scripts/demo.sh fresh
```

`fresh` runs the first nightly, waits until Percy has finished processing it, and approves it as the baseline. Approving needs `PERCY_USERNAME` / `PERCY_ACCESS_KEY` in `.percy/.env`. Without them, approve that build in Percy yourself.

Run `fresh` again any time to start over. It puts the app back to its baseline, closes demo issues, and re-baselines.

## 3. Seed a "mixed morning"

```bash
./scripts/demo.sh morning
```

This simulates yesterday:
- **PR 1** (merged into your fork): teal primary buttons. Its description carries a `## Percy Visual Intent` section, as if written with the plugin.
- **PR 2** (merged into your fork): a footer tagline tweak. It has **no** intent section, as if from a team that doesn't use the plugin.
- **A hotfix pushed without a PR:** product prices on the Shop page turn invisible.
- **The nightly run**, plus Journal's promo strip rotating as usual.

## 4. Install the plugin for your agent and triage

**Claude Code**
```
/plugin marketplace add percy/percy-visual-testing-agent
/plugin install percy-visual-testing
```
then `/percy-gate`.

**GitHub Copilot** (VS Code, Agent mode): see [COPILOT.md](COPILOT.md).

**Cursor / Codex / Gemini / Antigravity**
```bash
curl -fsSL https://raw.githubusercontent.com/percy/percy-visual-testing-agent/main/install.sh | bash -s -- --qa
```
then ask: *"run the percy gate workflow on last night's run."*

**What a correct triage looks like:**

| Change | Expected bucket |
|---|---|
| Teal buttons | ✅ **Explained**, citing PR 1 |
| Footer tagline | ✅ **Explained (weak intent)**, citing PR 2 by its title |
| Journal promo strip | 🔁 **Noise** (dynamic) |
| Invisible Shop prices | 🛑 **Anomaly** (or ⚠️ unexplained): nothing merged explains it |

You confirm:
1. approve the explained + noise snapshots
2. flag the Shop snapshot (*changes requested*)
3. on the first run, tell it how your team reports bugs (or "don't report")

## 5. Day 2 (optional) and reset

```bash
./scripts/demo.sh fix-deploy   # hotfix rolled back → next nightly shows prices restored
./scripts/demo.sh nightly      # run again WITHOUT fixing → the agent should still list Shop as unresolved
./scripts/demo.sh fresh        # start over: app back to baseline + Percy re-baselined
```
