// =============================================================================
// AuroraOS — download proxy Worker
// =============================================================================
// Serves the AuroraOS ISO from the R2 bucket over a public workers.dev URL.
// R2 buckets are private by default and the dashboard "public dev URL" is
// rate-limited; this Worker is a clean, unlimited public download endpoint that
// reads directly from R2 via a binding.
//
// Routes:
//   /                              -> info page (version + checksum + link)
//   /auroraos-0.1-amd64.iso        -> the ISO stream (Range + conditional GET)
//   /auroraos-0.1-amd64.iso.sha256 -> the checksum (read from R2 metadata)
// =============================================================================

const ISO_KEY = 'auroraos-0.1-amd64.iso';
const SHA_KEY = 'auroraos-0.1-amd64.iso.sha256';
// Fallback only — the authoritative checksum is the `sha256` custom-metadata on
// the R2 object (written at upload time), so the published hash always matches
// the bytes actually stored even after a re-upload.
const FALLBACK_SHA256 = 'dae0f9a81080d9969b58572ce7f92c2e8ddceed898d1c27e5e557a750bab7d32';

// Only reflect CORS for our own site origins (apex + Pages preview deploys).
// Avoids wildcard `*` letting arbitrary third-party JS read the bytes/checksum,
// while still letting the site's availability check (a cross-origin HEAD) work.
function allowOrigin(request) {
  const origin = request.headers.get('Origin');
  if (!origin) return null;
  try {
    const host = new URL(origin).host;
    if (host === 'auroraos.pages.dev' || host.endsWith('.auroraos.pages.dev')) {
      return origin;
    }
  } catch (_) { /* malformed Origin */ }
  return null;
}

function withCors(headers, request) {
  const o = allowOrigin(request);
  if (o) {
    headers.set('Access-Control-Allow-Origin', o);
    headers.set('Vary', 'Origin');
  }
  return headers;
}

async function readChecksum(env) {
  try {
    const head = await env.ISO_BUCKET.head(ISO_KEY);
    const sha = head && head.customMetadata && head.customMetadata.sha256;
    if (sha && /^[0-9a-f]{64}$/.test(sha)) return sha;
  } catch (_) { /* fall through */ }
  return FALLBACK_SHA256;
}

async function readVersion(env) {
  try {
    const head = await env.ISO_BUCKET.head(ISO_KEY);
    const v = head && head.customMetadata && head.customMetadata.version;
    if (v && /^[0-9][0-9.]{0,11}$/.test(v)) return v;
  } catch (_) { /* fall through */ }
  return '';
}

// The filename the browser SAVES the ISO as. Derived from the version metadata
// (written at upload) so the download always matches the actual release — the
// R2 key itself is a fixed internal name and is NOT shown to the user.
function isoFilename(version) {
  return version ? `auroraos-${version}-amd64.iso` : 'auroraos-amd64.iso';
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      return await handle(path, request, env);
    } catch (err) {
      return new Response(
        `Worker error: ${err && err.message ? err.message : String(err)}`,
        { status: 500, headers: { 'Content-Type': 'text/plain' } }
      );
    }
  },
};

async function handle(path, request, env) {
  // ---- ISO download ----------------------------------------------------------
  if (path === '/' + ISO_KEY) {
    // HEAD: answer from metadata only (no body fetch).
    if (request.method === 'HEAD') {
      const head = await env.ISO_BUCKET.head(ISO_KEY);
      if (head === null) return new Response('ISO not found in bucket', { status: 404 });
      const headers = withCors(new Headers(), request);
      headers.set('Content-Type', 'application/octet-stream');
      headers.set('Content-Disposition',
        `attachment; filename="${isoFilename(head.customMetadata && head.customMetadata.version)}"`);
      headers.set('Accept-Ranges', 'bytes');
      headers.set('ETag', head.httpEtag);
      headers.set('Content-Length', String(head.size));
      headers.set('X-Content-Type-Options', 'nosniff');
      return new Response(null, { status: 200, headers });
    }

    // Pass the request Headers (not a raw string) to R2 so it parses Range /
    // If-None-Match itself. A raw "bytes=..." string throws (error 1101).
    const obj = await env.ISO_BUCKET.get(ISO_KEY, {
      range: request.headers,
      onlyIf: request.headers,
    });
    if (obj === null) return new Response('ISO not found in bucket', { status: 404 });

    const headers = withCors(new Headers(), request);
    headers.set('ETag', obj.httpEtag);
    headers.set('Accept-Ranges', 'bytes');

    // Conditional GET matched -> 304 with no body and no body-describing headers.
    if (!obj.body) {
      return new Response(null, { status: 304, headers });
    }

    headers.set('Content-Type', 'application/octet-stream');
    headers.set('Content-Disposition',
      `attachment; filename="${isoFilename(obj.customMetadata && obj.customMetadata.version)}"`);
    headers.set('X-Content-Type-Options', 'nosniff');

    const hasRange = request.headers.has('Range') && obj.range;
    if (hasRange) {
      const offset = obj.range.offset ?? 0;
      const end = obj.range.end ??
        (obj.range.length !== undefined ? offset + obj.range.length - 1 : obj.size - 1);
      headers.set('Content-Range', `bytes ${offset}-${end}/${obj.size}`);
      headers.set('Content-Length', String(end - offset + 1));
      return new Response(obj.body, { status: 206, headers });
    }

    headers.set('Content-Length', String(obj.size));
    return new Response(obj.body, { status: 200, headers });
  }

  // ---- Update channel: serve signed manifests + artifacts from R2 -----------
  // Paths like /updates/stable/manifest.json(.minisig) and
  // /updates/<version>/filesystem.squashfs(.minisig). Read-only passthrough to
  // R2 with Range support (the squashfs is large) and content-type by suffix.
  if (path.startsWith('/updates/')) {
    const key = decodeURIComponent(path.slice(1)); // drop leading '/'
    // Defense-in-depth: no traversal, no absolute keys.
    if (key.includes('..') || key.includes('//')) {
      return new Response('Bad request', { status: 400 });
    }
    const ctype = key.endsWith('.json') ? 'application/json; charset=utf-8'
      : key.endsWith('.minisig') ? 'text/plain; charset=utf-8'
      : 'application/octet-stream';

    if (request.method === 'HEAD') {
      const head = await env.ISO_BUCKET.head(key);
      if (head === null) return new Response('Not found', { status: 404 });
      const h = withCors(new Headers(), request);
      h.set('Content-Type', ctype);
      h.set('Accept-Ranges', 'bytes');
      h.set('ETag', head.httpEtag);
      h.set('Content-Length', String(head.size));
      h.set('X-Content-Type-Options', 'nosniff');
      return new Response(null, { status: 200, headers: h });
    }

    const obj = await env.ISO_BUCKET.get(key, { range: request.headers, onlyIf: request.headers });
    if (obj === null) return new Response('Not found', { status: 404 });
    const h = withCors(new Headers(), request);
    h.set('ETag', obj.httpEtag);
    h.set('Accept-Ranges', 'bytes');
    h.set('X-Content-Type-Options', 'nosniff');
    // Manifests change per release; don't let a stale copy hide an update.
    h.set('Cache-Control', key.endsWith('manifest.json') ? 'no-cache' : 'public, max-age=86400');
    if (!obj.body) return new Response(null, { status: 304, headers: h });
    h.set('Content-Type', ctype);
    const hasRange = request.headers.has('Range') && obj.range;
    if (hasRange) {
      const offset = obj.range.offset ?? 0;
      const end = obj.range.end ??
        (obj.range.length !== undefined ? offset + obj.range.length - 1 : obj.size - 1);
      h.set('Content-Range', `bytes ${offset}-${end}/${obj.size}`);
      h.set('Content-Length', String(end - offset + 1));
      return new Response(obj.body, { status: 206, headers: h });
    }
    h.set('Content-Length', String(obj.size));
    return new Response(obj.body, { status: 200, headers: h });
  }

  // ---- SHA256 checksum (authoritative: from R2 metadata) ---------------------
  if (path === '/' + SHA_KEY) {
    const sha = await readChecksum(env);
    const ver = await readVersion(env);
    const headers = withCors(new Headers(), request);
    headers.set('Content-Type', 'text/plain; charset=utf-8');
    headers.set('X-Content-Type-Options', 'nosniff');
    return new Response(`${sha}  ${isoFilename(ver)}\n`, { headers });
  }

  // ---- Info page -------------------------------------------------------------
  if (path === '/' || path === '') {
    const sha = await readChecksum(env);
    const ver = await readVersion(env);
    const html = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AuroraOS Downloads</title>
<style>
body{font:15px/1.6 ui-monospace,monospace;background:#0c0d0a;color:#d8d4c4;margin:0;padding:48px 24px}
.wrap{max-width:640px;margin:0 auto}
h1{font-weight:400;font-size:1.6rem;margin:0 0 4px}
a{color:#818cf8}
.meta{color:#8a8676;font-size:.85rem;margin-bottom:24px;word-break:break-all}
.card{border:1px solid #333347;border-left:3px solid #818cf8;padding:20px;background:#111210;margin-bottom:16px}
.k{color:#8a8676;font-size:.8rem;text-transform:uppercase;letter-spacing:.08em}
.v{font-weight:600}
.btn{display:inline-block;background:#818cf8;color:#0c0d0a;padding:12px 22px;text-decoration:none;font-weight:600;margin-top:12px;border-radius:2px}
code{background:#1a1a22;padding:2px 6px;border-radius:2px;color:#a5b4fc}
</style></head><body><div class="wrap">
<h1>AuroraOS Downloads</h1>
<div class="meta">served via Workers + R2</div>
<div class="card">
<div class="k">Latest release</div>
<div class="v">AuroraOS v${ver || '0.4'} (amd64 ISO)</div>
<div class="meta">Size: 2.38 GiB · SHA256: <code>${sha}</code></div>
<a class="btn" href="/${ISO_KEY}">Download ISO</a><br>
<a href="/${SHA_KEY}">checksum (.sha256)</a>
</div>
<div class="meta">See <a href="https://auroraos.pages.dev">auroraos.pages.dev</a> for full instructions.</div>
</div></body></html>`;
    return new Response(html, {
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy':
          "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'",
      },
    });
  }

  return new Response('Not found', { status: 404 });
}
