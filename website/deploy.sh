#!/bin/bash
# =============================================================================
# AuroraOS website — deploy to Cloudflare Pages
# =============================================================================
# Usage:  ./deploy.sh
#
# Requires authentication. Either:
#   A) Interactive:  npx wrangler login   (opens browser, one-time)
#   B) Token:        set CLOUDFLARE_API_TOKEN env var (create a token with the
#                    "Cloudflare Pages — Edit" permission at
#                    https://dash.cloudflare.com/profile/api-tokens)
#
# This script runs from the website/ directory. It deploys the static files
# directly (no build step needed — the site is plain HTML/CSS/JS).
# =============================================================================

set -e
cd "$(dirname "$0")"

PROJECT="auroraos"

echo "[aurora-web] Deploying to Cloudflare Pages as project: $PROJECT"
echo "[aurora-web] Files: $(ls -1 | tr '\n' ' ')"
echo ""

# Direct upload of the static site. If the project doesn't exist yet, wrangler
# creates it on first deploy.
#
# --branch=main is REQUIRED to publish to the PRODUCTION URL (auroraos.pages.dev).
# Without it, wrangler infers the branch from git; any non-production branch
# (e.g. a fixes/* working branch) deploys to a *preview* URL instead, so the
# real site silently doesn't update. Pin it to main so a deploy always ships.
npx wrangler pages deploy . --project-name="$PROJECT" --branch=main

echo ""
echo "[aurora-web] Deploy complete."
echo "[aurora-web] Your site will be live at: https://$PROJECT.pages.dev"
echo "[aurora-web] (first deploy may take ~60s to propagate)"
