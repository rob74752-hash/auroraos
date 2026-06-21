# AuroraOS — Website Deployment

The AuroraOS marketing site lives in `website/` and is a static site (no build step).
Deploy to **Cloudflare Pages** with one command — but you need to authenticate first.

---

## Step 1 — Authenticate (one-time)

Pick **one** of these:

### Option A — Interactive login (easiest)
```bash
cd website
npx wrangler login
```
A browser opens → approve with your Cloudflare account → done. The session persists.

### Option B — API token (for automation / headless)
1. Go to https://dash.cloudflare.com/profile/api-tokens
2. **Create Token** → use the **"Edit Cloudflare Workers"** template (it includes Pages), or create a custom token with the **Cloudflare Pages → Edit** permission.
3. Set it in your shell:
   ```bash
   set CLOUDFLARE_API_TOKEN=your_token_here      # Windows cmd
   $env:CLOUDFLARE_API_TOKEN="your_token_here"   # PowerShell
   export CLOUDFLARE_API_TOKEN=your_token_here   # bash/WSL
   ```

---

## Step 2 — Deploy

```bash
cd website
./deploy.sh
```
(or directly: `npx wrangler pages deploy . --project-name=auroraos`)

First deploy creates the `auroraos` project automatically. Your site goes live at:

```
https://auroraos.pages.dev
```

---

## Step 3 (optional) — Custom domain

In the Cloudflare dashboard → **Workers & Pages** → your `auroraos` project →
**Custom domains** → add your domain (e.g. `auroraos.com`). Cloudflare handles DNS + SSL.

---

## Local preview

No server needed — just open `website/index.html` in a browser. For hot-reload during editing:

```bash
cd website
npx wrangler pages dev .
# → http://localhost:8788
```

---

## Notes
- The site is **plain HTML/CSS/JS** — no framework, no build, no dependencies. Deploys are instant.
- `_headers` sets security headers + caching. Cloudflare Pages reads it automatically.
- `wrangler.jsonc` declares the project name + compatibility date.
