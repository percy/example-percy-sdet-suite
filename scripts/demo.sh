#!/usr/bin/env bash
# Sandbox driver for the Percy QA-triage demo.
#
#   ./scripts/demo.sh setup            fork + clone the app repo, install deps, check your Percy token
#   ./scripts/demo.sh nightly          "deploy" the app's main branch locally and run the nightly Percy build
#   ./scripts/demo.sh approve-baseline approve the latest nightly build (needs PERCY_USERNAME / PERCY_ACCESS_KEY)
#   ./scripts/demo.sh morning          seed a mixed morning: merge 2 app PRs + a bad deploy, then run the nightly
#   ./scripts/demo.sh fix-deploy       undo the bad deploy, then run the nightly (the "day 2" run)
#   ./scripts/demo.sh reset            put the app repo back to its baseline and clear demo state
#
# Secrets live in .percy/.env (gitignored): PERCY_TOKEN=..., optionally PERCY_USERNAME / PERCY_ACCESS_KEY.
# Nothing here sends data anywhere except GitHub (your app repo) and Percy (your project).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_DIR="${APP_DIR:-$ROOT/../example-percy-sdet-app}"
PORT="${APP_PORT:-5500}"
STATE="$ROOT/.demo-state"
UPSTREAM_APP="percy/example-percy-sdet-app"
UA="example-percy-sdet-suite/1.0 curl/8.7.1"
mkdir -p "$STATE"

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()  { printf '\n✖ %s\n' "$*" >&2; exit 1; }
load_env() { if [ -f .percy/.env ]; then set -a; . ./.percy/.env; set +a; fi; }
app_repo() { sed -n 's/^app_repos: *\[\([^],]*\).*/\1/p' .percy/config.yml | tr -d ' "'"'"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }

cmd_setup() {
  need node "install Node.js 18+ (https://nodejs.org)"
  need git  "install git"
  need gh   "install the GitHub CLI (https://cli.github.com) and run: gh auth login"
  gh auth status >/dev/null 2>&1 || die "GitHub CLI not logged in — run: gh auth login"
  local me repo; me="$(gh api user -q .login)"
  repo="$(app_repo)"
  if [ "${NO_FORK:-}" = "1" ]; then
    say "Using $repo directly (NO_FORK=1)"
  elif [ "$repo" = "$UPSTREAM_APP" ]; then
    say "Forking $UPSTREAM_APP into $me (your copy — the demo merges PRs there)"
    gh repo fork "$UPSTREAM_APP" --clone=false >/dev/null 2>&1 || true
    repo="$me/example-percy-sdet-app"
    for i in 1 2 3 4 5 6; do gh repo view "$repo" >/dev/null 2>&1 && break; sleep 5; done
    gh repo view "$repo" >/dev/null 2>&1 || die "fork $repo not visible yet — re-run setup in a minute"
    sed -i.bak "s#^app_repos: .*#app_repos: [$repo]   # your fork — the triage reads PRs merged here#" .percy/config.yml && rm -f .percy/config.yml.bak
  fi
  if [ ! -d "$APP_DIR/.git" ]; then
    say "Cloning $repo → $APP_DIR"
    gh repo clone "$repo" "$APP_DIR" -- -q
  fi
  git -C "$APP_DIR" fetch -q --tags origin
  say "Installing dependencies"
  npm install --silent --no-fund --no-audit
  (cd "$APP_DIR" && npm install --silent --no-fund --no-audit)
  if [ -z "${PW_CHANNEL:-}" ]; then ./node_modules/.bin/playwright install chromium >/dev/null; fi
  load_env
  if [ -z "${PERCY_TOKEN:-}" ]; then
    printf 'PERCY_TOKEN=\n# PERCY_USERNAME=\n# PERCY_ACCESS_KEY=\n' > .percy/.env
    die "Add your Percy project token to .percy/.env (open the file in your editor; never paste it into chat). Percy → your project → Project settings → Project token (the full-access one)."
  fi
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" -H "Authorization: Token token=\"$PERCY_TOKEN\"" 'https://percy.io/api/v1/builds?page%5Blimit%5D=1')"
  [ "$code" = "200" ] || die "Percy token check failed (HTTP $code). Use the project's full-access token, not a write-only one."
  say "Setup done. App repo: $repo · app checkout: $APP_DIR · Percy token: OK"
  echo "Next: ./scripts/demo.sh nightly   then approve that first build as the baseline."
}

deploy() {
  say "Deploying the app's main branch (as merged on GitHub) to .deploy/"
  git -C "$APP_DIR" fetch -q origin main
  rm -rf .deploy && mkdir .deploy
  git -C "$APP_DIR" archive origin/main | tar -x -C .deploy
  if [ -f "$STATE/bad-deploy" ]; then
    # A hotfix that went out without a PR: product prices render white-on-white.
    sed -i.bak 's#</head>#<style>.product-price{color:\#fff !important}</style></head>#' .deploy/products.html && rm -f .deploy/products.html.bak
    echo "  (includes the un-reviewed hotfix: prices on the Shop page are invisible)"
  fi
}

cmd_nightly() {
  load_env; [ -n "${PERCY_TOKEN:-}" ] || die "no PERCY_TOKEN in .percy/.env — run setup first"
  if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    die "port $PORT is already in use — stop whatever is serving there (or set APP_PORT and APP_URL), or the suite would snapshot the wrong app"
  fi
  deploy
  ./node_modules/.bin/http-server .deploy -p "$PORT" -s & local srv=$!
  trap 'kill $srv 2>/dev/null || true' EXIT
  sleep 1
  say "Running the nightly regression suite with Percy (branch: nightly)"
  PERCY_BRANCH=nightly PERCY_TARGET_BRANCH=nightly env -u ELECTRON_RUN_AS_NODE \
    ./node_modules/.bin/percy exec -- ./node_modules/.bin/playwright test --workers=2 2>&1 | tee "$STATE/last-nightly.log" | grep -E 'Finalized build|passed|failed|Error' || true
  kill $srv 2>/dev/null || true; trap - EXIT
  grep -q 'Finalized build' "$STATE/last-nightly.log" || die "the Percy build didn't finalize — see $STATE/last-nightly.log"
}

cmd_approve_baseline() {
  load_env
  [ -n "${PERCY_USERNAME:-}" ] && [ -n "${PERCY_ACCESS_KEY:-}" ] || die "set PERCY_USERNAME / PERCY_ACCESS_KEY in .percy/.env (BrowserStack → Account → Access key), or approve the build in the Percy dashboard instead"
  local bid; bid="$(curl -sS -A "$UA" -H "Authorization: Token token=\"$PERCY_TOKEN\"" 'https://percy.io/api/v1/builds?filter%5Bbranch%5D=nightly&page%5Blimit%5D=1' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const b=JSON.parse(s).data[0];console.log(b?b.id:"")})')"
  [ -n "$bid" ] || die "no nightly build yet — run: ./scripts/demo.sh nightly"
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$PERCY_USERNAME:$PERCY_ACCESS_KEY" -A "$UA" -H 'Content-Type: application/vnd.api+json' -X POST https://percy.io/api/v1/reviews \
    -d "{\"data\":{\"type\":\"reviews\",\"attributes\":{\"action\":\"approve\"},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$bid\"}}}}}")"
  case "$code" in 201) say "Approved build $bid as the baseline";; 409) die "build $bid isn't finished processing yet — wait a minute and retry";; *) die "approve failed (HTTP $code)";; esac
}

open_and_merge() { # <branch> <title> <body-file>
  local repo="$1" branch="$2" title="$3" body="$4" n
  git -C "$APP_DIR" push -q origin "$branch"
  n="$(gh pr create -R "$repo" --base main --head "$branch" --title "$title" --body-file "$body" | sed -n 's#.*/pull/\([0-9]*\).*#\1#p')"
  gh pr merge "$n" -R "$repo" --squash --delete-branch >/dev/null
  echo "  merged $repo#$n — $title"
}

cmd_merge_prs() {
  local repo; repo="$(app_repo)"
  say "Merging two app PRs into $repo (what the dev team shipped yesterday)"
  git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" checkout -q main && git -C "$APP_DIR" reset -q --hard origin/main
  # PR 1 — brand refresh, written with the plugin: carries a Percy Visual Intent section.
  git -C "$APP_DIR" checkout -q -B demo/teal-ctas
  sed -i.bak 's#--color-cta: \#1B2B4B;#--color-cta: \#0F766E;#' "$APP_DIR/assets/site.css" && rm -f "$APP_DIR/assets/site.css.bak"
  git -C "$APP_DIR" commit -qam "Brand refresh: teal primary buttons"
  cat > "$STATE/pr1.md" <<'EOF'
Switches the primary call-to-action colour to the new teal brand accent.

## Percy Visual Intent
<!-- percy-visual-intent: start -->
**Intended changes**
- Primary buttons (hero CTA, "Add to cart", checkout) change from navy to teal (#0F766E) on every page.

**Should stay the same**
- Layout, typography, button sizes and labels; navigation; footer.
<!-- percy-visual-intent: end -->
EOF
  open_and_merge "$repo" demo/teal-ctas "Brand refresh: teal primary buttons" "$STATE/pr1.md"
  # PR 2 — a copy tweak from a team that doesn't use the plugin: no intent section (weak intent).
  git -C "$APP_DIR" checkout -q main && git -C "$APP_DIR" pull -q origin main
  git -C "$APP_DIR" checkout -q -B demo/footer-tagline
  for f in "$APP_DIR"/*.html; do sed -i.bak 's#Considered objects for the modern home, designed in Copenhagen.#Considered objects for the modern home, made to last.#' "$f" && rm -f "$f.bak"; done
  git -C "$APP_DIR" commit -qam "Footer: refresh brand tagline"
  printf 'Updates the footer tagline copy on all pages.\n' > "$STATE/pr2.md"
  open_and_merge "$repo" demo/footer-tagline "Footer: refresh brand tagline" "$STATE/pr2.md"
  git -C "$APP_DIR" checkout -q main && git -C "$APP_DIR" pull -q origin main
}

cmd_morning() {
  cmd_merge_prs
  say "Shipping an un-reviewed hotfix straight to the deployed app (no PR)"
  touch "$STATE/bad-deploy"
  cmd_nightly
  echo
  echo "Mixed morning ready. Open your agent in this repo and ask it to triage last night's run (Claude Code or Copilot: /percy-gate)."
}

cmd_fix_deploy() { rm -f "$STATE/bad-deploy"; say "Hotfix rolled back"; cmd_nightly; }

cmd_reset() {
  local repo; repo="$(app_repo)"
  say "Resetting $repo main to the baseline tag (force push — this is your demo copy)"
  for n in $(gh pr list -R "$repo" --state open --json number,headRefName -q '.[] | select(.headRefName|startswith("demo/")) | .number'); do gh pr close "$n" -R "$repo" --delete-branch >/dev/null; done
  git -C "$APP_DIR" fetch -q --tags origin
  git -C "$APP_DIR" checkout -q main && git -C "$APP_DIR" reset -q --hard baseline
  git -C "$APP_DIR" push -q --force origin main
  rm -rf "$STATE" .deploy .percy/triage
  echo "Done. Percy's baseline still reflects the last approved build: run 'nightly' and approve it to re-baseline."
}

case "${1:-}" in
  setup) cmd_setup ;;
  nightly) cmd_nightly ;;
  approve-baseline) cmd_approve_baseline ;;
  merge-prs) cmd_merge_prs ;;
  morning) cmd_morning ;;
  fix-deploy) cmd_fix_deploy ;;
  reset) cmd_reset ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
