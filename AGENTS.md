# Lumina nightly regression suite — agent instructions

This repo is a QA regression suite: Playwright tests that snapshot the Lumina Home storefront with Percy every night. The app's code lives in a separate repo (see `app_repos` in `.percy/config.yml`).

## Visual review (Percy)
<!-- percy-hook v3 role=qa -->

This repo is a Percy regression/QA suite. Morning triage: run `/percy:gate` — it resolves the latest build on `nightly`, classifies every diff (merged app-PR intent / dynamic noise / anomaly), and one confirm approves an all-explained run.

Outside Claude Code, "/percy:X" means: read `.percy/skills/percy-X.md` and follow it.
