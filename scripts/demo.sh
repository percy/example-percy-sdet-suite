#!/usr/bin/env bash
# Sandbox driver for the Percy QA-triage demo.
#
#   ./scripts/demo.sh setup            fork + clone the app repo, install deps, check your Percy token
#   ./scripts/demo.sh fresh            clean slate: app back to baseline, run a nightly, approve it as the baseline
#   ./scripts/demo.sh morning          seed a mixed morning: merge 2 app PRs + a bad deploy, then run the nightly
#   ./scripts/demo.sh fix-deploy       undo the bad deploy, then run the nightly (the "day 2" run)
#   ./scripts/demo.sh nightly          just run a nightly build (waits until Percy has finished processing it)
#   ./scripts/demo.sh approve-baseline approve the latest nightly build (needs BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY)
#   ./scripts/demo.sh reset            put the app repo back to its baseline (use 'fresh' to also re-baseline Percy)
#   ./scripts/demo.sh mode no-access   pretend QA can't read the app's code (central QA team): Percy AI + release notes only
#   ./scripts/demo.sh mode percy-only  no code access AND no release notes: Percy's AI and snapshot history only
#   ./scripts/demo.sh unsetup          remove only the plugin's setup (its config + AGENTS.md section) so /percy-setup can be
#                                      shown live; Percy's own integration is untouched. Undo: git checkout .percy/config.yml AGENTS.md
#   ./scripts/demo.sh mode repos       back to normal: the triage reads the app's merged PRs
#
# Secrets live in .percy/.env (gitignored): PERCY_TOKEN=... plus your BrowserStack credentials
# BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY (BrowserStack → Account → Profile) for approving / flagging.
# Nothing here sends data anywhere except GitHub (your app repo) and Percy (your project).
set -euo pipefail

SHELL_BS_USER="${BROWSERSTACK_USERNAME:-}"; SHELL_BS_KEY="${BROWSERSTACK_ACCESS_KEY:-}"
SHELL_PERCY_USER="${PERCY_USERNAME:-}"; SHELL_PERCY_KEY="${PERCY_ACCESS_KEY:-}"
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
load_env() {
  if [ -f .percy/.env ]; then set -a; . ./.percy/.env; set +a; fi
  # older names still accepted
  BROWSERSTACK_USERNAME="${BROWSERSTACK_USERNAME:-${PERCY_USERNAME:-}}"; BROWSERSTACK_ACCESS_KEY="${BROWSERSTACK_ACCESS_KEY:-${PERCY_ACCESS_KEY:-}}"
}
# Approving / flagging needs a BrowserStack username + access key that can see THIS Percy project (people often
# have several BrowserStack accounts). Try the pair in .percy/.env, then the shell's BROWSERSTACK_* and PERCY_*
# pairs; keep the first that can read the project's latest build, and save it to .percy/.env (gitignored).
can_see_project() { # <user> <key>
  local bid; bid="$(api '/builds?page%5Blimit%5D=1' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const b=JSON.parse(s).data[0];console.log(b?b.id:"")})')"
  [ -n "$bid" ] || return 0   # no builds yet: nothing to check against
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -u "$1:$2" -A "$UA" "https://percy.io/api/v1/builds/$bid")" = "200" ]
}
save_bs_creds() {
  local fu fk; fu="$(sed -n 's/^BROWSERSTACK_USERNAME=//p' .percy/.env 2>/dev/null)"; fk="$(sed -n 's/^BROWSERSTACK_ACCESS_KEY=//p' .percy/.env 2>/dev/null)"
  if [ -n "$fu" ] && [ -n "$fk" ] && can_see_project "$fu" "$fk"; then echo "  BrowserStack credentials in .percy/.env: OK for this Percy project"; return 0; fi
  local u k pair
  for pair in "${SHELL_BS_USER:-}|${SHELL_BS_KEY:-}" "${SHELL_PERCY_USER:-}|${SHELL_PERCY_KEY:-}"; do
    u="${pair%%|*}"; k="${pair#*|}"
    [ -n "$u" ] && [ -n "$k" ] || continue
    if can_see_project "$u" "$k"; then
      sed -i.bak '/^#* *BROWSERSTACK_USERNAME=/d;/^#* *BROWSERSTACK_ACCESS_KEY=/d;/^#* *PERCY_USERNAME=/d;/^#* *PERCY_ACCESS_KEY=/d' .percy/.env && rm -f .percy/.env.bak
      printf 'BROWSERSTACK_USERNAME=%s\nBROWSERSTACK_ACCESS_KEY=%s\n' "$u" "$k" >> .percy/.env
      echo "  saved BrowserStack credentials that can see this Percy project to .percy/.env (gitignored)"
      return 0
    fi
  done
  die "none of your BrowserStack credentials can see this Percy project, so approving/flagging would fail. Put the username + access key of an account in the project's Percy organization into .percy/.env as BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY."
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }
# The app repo the demo merges PRs into. In 'no-access' mode the config hides it from the agent, so remember it here.
app_repo() {
  local r; r="$(sed -n 's/^app_repos: *\[\([^],]*\).*/\1/p' .percy/config.yml | tr -d ' "'"'")"
  if [ -n "$r" ]; then echo "$r"; elif [ -f .demo-app-repo ]; then cat .demo-app-repo; else echo "$UPSTREAM_APP"; fi
}
api() { curl -sS -A "$UA" -H "Authorization: Token token=\"$PERCY_TOKEN\"" "https://percy.io/api/v1$1"; }
# Prints "<id> <state> <review-state> <ai-ready> <web-url>" for a build JSON on stdin (ai-ready = all AI jobs done; the cluster summary can lag and is not needed).
build_fields() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j=JSON.parse(s).data;if(Array.isArray(j))j=j[0];if(!j){console.log("");return}const a=j.attributes,ai=a["ai-details"]||{};const ready=ai["all-ai-jobs-completed"]===true||a["total-comparisons-diff"]===0;console.log([j.id,a.state,a["review-state"],ready,a["web-url"]].join(" "))})'; }
latest_nightly() { api '/builds?filter%5Bbranch%5D=nightly&page%5Blimit%5D=1' | build_fields; }
wait_finished() { # <build id> — Percy must finish processing (incl. AI) before anything reviews or builds on top of it
  local f i
  for i in $(seq 1 60); do
    f="$(api "/builds/$1" | build_fields)"
    set -- $f
    case "$2" in failed|expired) die "build $1 $2 — see Percy";; esac
    if [ "$2" = "finished" ] && [ "$4" = "true" ]; then echo "  build $1 finished processing"; return 0; fi
    [ "$i" = 1 ] && printf '  waiting for Percy to finish processing build %s' "$1"; printf '.'; sleep 10
  done
  echo; die "build $1 still processing after 10 minutes — check Percy"
}

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
    # Forks start with Issues turned off — the triage files its bug report as an issue here.
    gh repo edit "$repo" --enable-issues >/dev/null 2>&1 || echo "  note: couldn't enable Issues on $repo — turn them on in its Settings to let the agent file bugs there"
  fi
  gh label create visual-regression -R "$repo" --color D93F0B --description "Filed by the Percy Visual Testing Agent's QA triage" >/dev/null 2>&1 || true
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
    printf 'PERCY_TOKEN=\n# BROWSERSTACK_USERNAME=\n# BROWSERSTACK_ACCESS_KEY=\n' > .percy/.env
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
  local bid; bid="$(sed -n 's#.*Finalized build \#[0-9]*: .*/builds/\([0-9]*\).*#\1#p' "$STATE/last-nightly.log" | tail -1)"
  echo "$bid" > "$STATE/last-build-id"
  wait_finished "$bid"
}

cmd_approve_baseline() {
  load_env
  [ -n "${BROWSERSTACK_USERNAME:-}" ] && [ -n "${BROWSERSTACK_ACCESS_KEY:-}" ] || die "add BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY (BrowserStack → Account → Profile) to .percy/.env, or approve the build in the Percy dashboard instead"
  local f bid; f="$(latest_nightly)"; bid="${f%% *}"
  [ -n "$bid" ] || die "no nightly build yet — run: ./scripts/demo.sh nightly"
  wait_finished "$bid"
  set -- $(api "/builds/$bid" | build_fields)
  if [ "${3:-}" = "approved" ]; then say "Build $bid is already approved (Percy auto-approves a run with no changes) — it's the baseline"; return 0; fi
  local code i
  for i in 1 2 3 4 5 6 7 8 9; do   # Percy briefly answers 409 "Can only review finished builds" right after a build finishes
    code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" -A "$UA" -H 'Content-Type: application/vnd.api+json' -X POST https://percy.io/api/v1/reviews \
      -d "{\"data\":{\"type\":\"reviews\",\"attributes\":{\"action\":\"approve\"},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$bid\"}}}}}")"
    [ "$code" = "409" ] || break
    set -- $(api "/builds/$bid" | build_fields); [ "${3:-}" = "approved" ] && { code=201; break; }
    sleep 10
  done
  case "$code" in
    201) say "Approved build $bid as the baseline";;
    401|403) die "approve refused (HTTP $code): these BrowserStack credentials can't review this Percy project — check BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY in .percy/.env";;
    409) die "Percy still won't accept a review for build $bid (HTTP 409) — approve it in the Percy dashboard";;
    *) die "approve failed (HTTP $code)";;
  esac
}

open_and_merge() { # <branch> <title> <body-file>
  local repo="$1" branch="$2" title="$3" body="$4" n
  git -C "$APP_DIR" push -q origin "$branch" 2>/dev/null
  n="$(gh pr create -R "$repo" --base main --head "$branch" --title "$title" --body-file "$body" | sed -n 's#.*/pull/\([0-9]*\).*#\1#p')"
  gh pr merge "$n" -R "$repo" --squash --delete-branch >/dev/null
  echo "  merged $repo#$n — $title"
  echo "https://github.com/$repo/pull/$n|$title" >> "$STATE/merged-prs"
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
  load_env
  local f; f="$(latest_nightly)"; set -- $f
  [ -n "${1:-}" ] || die "no nightly baseline yet — run: ./scripts/demo.sh fresh"
  [ "$3" = "approved" ] || die "the latest nightly build ($1) is '$3', not approved — tonight's run would diff against an unreviewed build. Run: ./scripts/demo.sh fresh"
  rm -f "$STATE/merged-prs"
  cmd_merge_prs
  # What the vendor's release notes say about yesterday's release (used in no-access mode). The hotfix isn't in them.
  cat > "$STATE/release-notes.md" <<'EOF'
# Lumina Home — release notes (vendor)

- **Brand refresh:** primary buttons — the hero call to action, "Add to cart" and checkout — now use the new teal brand colour.
- **Footer:** updated brand tagline ("made to last").
EOF
  say "Shipping an un-reviewed hotfix straight to the deployed app (no PR)"
  touch "$STATE/bad-deploy"
  cmd_nightly
  local repo bid; repo="$(app_repo)"; bid="$(cat "$STATE/last-build-id")"
  echo
  say "Mixed morning ready. Tabs to open for the demo:"
  echo "  Last night's run in Percy:  $(api "/builds/$bid" | build_fields | cut -d' ' -f5)"
  echo "  What the dev team merged:   https://github.com/$repo/pulls?q=is%3Apr+is%3Amerged"
  while IFS='|' read -r url title; do echo "    $title → $url/files"; done < "$STATE/merged-prs"
  echo "  (The invisible-prices hotfix is in no PR — that's the point.)"
  grep -q '^change_sources: \[release-notes' .percy/config.yml && echo "  No-access mode — the vendor's release notes: $STATE/release-notes.md"
  echo
  echo "Then, in your agent in this repo: /percy-gate"
}

cmd_fresh() {
  load_env; [ -n "${PERCY_TOKEN:-}" ] || die "no PERCY_TOKEN in .percy/.env — run setup first"
  save_bs_creds          # checked BEFORE anything is reset, so a bad pair can't leave a half-done state
  load_env
  cmd_reset
  cmd_nightly
  cmd_approve_baseline
  say "Clean slate: app at baseline, Percy baseline approved. Next: ./scripts/demo.sh morning"
}

cmd_mode() {
  case "${1:-}" in
    no-access)
      app_repo > .demo-app-repo
      sed -i.bak '/^change_context:/d;/^change_sources:/d;s|^app_repos: .*|app_repos: []   # this QA team cannot read the app code|' .percy/config.yml && rm -f .percy/config.yml.bak
      printf 'change_context: percy-only\nchange_sources: [release-notes]\n' >> .percy/config.yml
      say "No-access mode: the agent can't see the app's PRs. It triages from Percy's AI, history and the vendor's release notes."
      echo "  (the vendor's release notes for each morning are written to .demo-state/release-notes.md)";;
    percy-only)
      app_repo > .demo-app-repo
      sed -i.bak '/^change_context:/d;/^change_sources:/d;s|^app_repos: .*|app_repos: []   # this QA team cannot read the app code|' .percy/config.yml && rm -f .percy/config.yml.bak
      printf 'change_context: percy-only\nchange_sources: []   # no release notes or Jira either\n' >> .percy/config.yml
      say "Percy-only mode: no app code, no release notes. The agent triages from Percy's AI and snapshot history alone.";;
    repos)
      local r; r="$(app_repo)"
      sed -i.bak "/^change_context:/d;/^change_sources:/d;s|^app_repos: .*|app_repos: [$r]|" .percy/config.yml && rm -f .percy/config.yml.bak
      say "Repo mode: the triage reads PRs merged into $r";;
    *) die "usage: ./scripts/demo.sh mode repos|no-access|percy-only";;
  esac
}

cmd_unsetup() {
  [ -f .percy/config.yml ] && app_repo > .demo-app-repo && cp .percy/config.yml "$STATE/config.before-unsetup.yml"
  rm -f .percy/config.yml
  node -e 'const fs=require("fs");const f="AGENTS.md";const t=fs.readFileSync(f,"utf8");const i=t.indexOf("## Visual review (Percy)");if(i>=0)fs.writeFileSync(f,t.slice(0,i).trimEnd()+"\n")'
  say "Removed the plugin's setup (its .percy/config.yml and the AGENTS.md section). Percy itself is untouched."
  echo "  Now, in your agent: /percy-setup   (undo without the agent: git checkout .percy/config.yml AGENTS.md)"
}

cmd_fix_deploy() { rm -f "$STATE/bad-deploy"; say "Hotfix rolled back"; cmd_nightly; }

cmd_reset() {
  local repo; repo="$(app_repo)"
  say "Resetting $repo main to the baseline tag (force push — this is your demo copy)"
  for n in $(gh pr list -R "$repo" --state open --json number,headRefName -q '.[] | select(.headRefName|startswith("demo/")) | .number'); do gh pr close "$n" -R "$repo" --delete-branch >/dev/null; done
  for n in $(gh issue list -R "$repo" --state open --label visual-regression --json number -q '.[].number' 2>/dev/null); do gh issue close "$n" -R "$repo" --comment "Closed by demo reset." >/dev/null; done
  git -C "$APP_DIR" fetch -q --tags origin
  git -C "$APP_DIR" checkout -q main && git -C "$APP_DIR" reset -q --hard baseline
  git -C "$APP_DIR" push -q --force origin main
  rm -rf "$STATE" .deploy .percy/triage
  # forget the bug-reporting route the agent saved, so each take shows the first-run question again
  node -e 'const fs=require("fs");const f=".percy/config.yml";const t=fs.readFileSync(f,"utf8").split("\n");const o=[];let skip=false;for(const l of t){if(/^reporting:/.test(l)){skip=true;continue}if(skip&&/^\s/.test(l))continue;skip=false;o.push(l)}fs.writeFileSync(f,o.join("\n"))'

  mkdir -p "$STATE"
  echo "App reset. Percy's baseline still reflects the last approved build — use 'fresh' to reset and re-baseline in one go."
}

case "${1:-}" in
  setup) cmd_setup ;;
  nightly) cmd_nightly ;;
  approve-baseline) cmd_approve_baseline ;;
  fresh) cmd_fresh ;;
  mode) cmd_mode "${2:-}" ;;
  unsetup) cmd_unsetup ;;
  merge-prs) cmd_merge_prs ;;
  morning) cmd_morning ;;
  fix-deploy) cmd_fix_deploy ;;
  reset) cmd_reset ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
