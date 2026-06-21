/* =============================================================================
   AuroraOS site — boot-sequence typewriter, scroll reveal, mobile nav
   ============================================================================= */
(function () {
  'use strict';

  // ---- Year ----
  var y = document.getElementById('year');
  if (y) y.textContent = '© ' + new Date().getFullYear() + ' · BUILT ON DEBIAN · OPEN SOURCE';

  // ---- Download availability + authoritative version/checksum ----
  // The ISO is hosted on R2 behind the download Worker. We:
  //   1. HEAD the ISO to confirm it exists (show "building" if not, honest UI).
  //   2. Fetch the Worker's .sha256 endpoint, which returns the AUTHORITATIVE
  //      hash + save-filename (the Worker derives the filename from the R2
  //      object's version metadata). We parse both so the version chip and the
  //      displayed SHA256 always match whatever is actually in the bucket — no
  //      per-release HTML edit, and no stale/incorrect hash ever shown.
  var dlBtn = document.getElementById('dlBtn');
  var dlBox = document.getElementById('dlBox');
  var dlBtnText = document.getElementById('dlBtnText');
  var dlSha = document.getElementById('dlSha');
  var dlVer = document.getElementById('dlVer');
  var shaUrl = 'https://auroraos-download.rob74752.workers.dev/auroraos-0.1-amd64.iso.sha256';

  // Pull hash + version from the .sha256 endpoint (text: "<sha>  auroraos-<ver>-amd64.iso").
  fetch(shaUrl)
    .then(function (r) { return r.ok ? r.text() : Promise.reject(); })
    .then(function (txt) {
      var m = /^([0-9a-f]{64})\s+(?:.*\/)?auroraos-([0-9][0-9A-Za-z.-]*)-amd64\.iso\s*$/im.exec(txt);
      if (m) {
        if (dlSha) dlSha.textContent = m[1].slice(0, 12) + '…' + m[1].slice(-8);
        if (dlVer) dlVer.textContent = 'v' + m[2];
      } else if (dlSha) {
        dlSha.textContent = 'see checksum link';
      }
    })
    .catch(function () {
      if (dlSha) dlSha.textContent = 'see checksum link';
    });

  if (dlBtn && dlBox) {
    fetch(dlBtn.getAttribute('href'), { method: 'HEAD', redirect: 'follow' })
      .then(function (r) {
        if (!r.ok) throw new Error('not found');
        if (dlBtnText) dlBtnText.textContent = 'Download ISO';
      })
      .catch(function () {
        // ISO not uploaded yet — show "building" state.
        dlBox.classList.add('dl--pending');
        if (dlBtnText) dlBtnText.textContent = 'Build in progress…';
      });
  }

  // ---- Mobile nav ----
  var burger = document.getElementById('burger');
  var links = document.getElementById('navLinks');
  if (burger && links) {
    var setMenu = function (open) {
      var styles = open
        ? { display: 'flex', position: 'absolute', top: '60px', left: '0', right: '0',
            flexDirection: 'column', background: 'rgba(12,13,10,0.98)', padding: '16px 24px',
            borderBottom: '1px solid var(--line)', gap: '16px' }
        : { display: '', position: '', top: '', left: '', right: '', flexDirection: '',
            background: '', padding: '', borderBottom: '', gap: '' };
      Object.keys(styles).forEach(function (k) { links.style[k] = styles[k]; });
      burger.setAttribute('aria-expanded', open ? 'true' : 'false');
    };
    var isOpen = function () { return burger.getAttribute('aria-expanded') === 'true'; };
    burger.addEventListener('click', function () { setMenu(!isOpen()); });
    // Dismiss on Escape and when a link is followed.
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && isOpen()) { setMenu(false); burger.focus(); }
    });
    links.addEventListener('click', function (e) {
      if (e.target.tagName === 'A' && isOpen()) setMenu(false);
    });
  }

  // ---- Scroll reveal ----
  var reveals = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e, i) {
        if (e.isIntersecting) {
          // staggered for items sharing a reveal group
          setTimeout(function () { e.target.classList.add('in'); }, (i % 4) * 70);
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.12 });
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add('in'); });
  }

  // ---- Boot-sequence typewriter (the memorable element) ----
  // Modeled on a real AuroraOS boot; reinforces the product's authenticity.
  var log = document.getElementById('bootLog');
  if (!log) return;

  // Only animate when the terminal scrolls into view (so it feels live).
  var started = false;
  var bootLines = [
    { t: '[ <span class="t-ok">OK</span> ] Reached target Local File Systems.', c: '' },
    { t: '[ <span class="t-ok">OK</span> ] Starting AuroraOS boot mode selector...', c: '' },
    { t: '<span class="t-amber">[aurora]</span> reading kernel cmdline: <span class="t-dim">/proc/cmdline</span>', c: '' },
    { t: '<span class="t-amber">[aurora]</span> token detected: <span class="t-green">aurora.persistent</span>', c: '' },
    { t: '<span class="t-amber">[aurora]</span> token detected: <span class="t-green">aurora.tor</span>', c: '' },
    { t: '<span class="t-amber">[aurora]</span> Boot mode selected: <span class="t-green">persistent + tor</span>', c: '' },
    { t: '<span class="t-amber">[aurora]</span> locating AuroraPersistent volume...', c: '' },
    { t: '<span class="t-amber">[aurora]</span> opening LUKS container <span class="t-dim">/dev/sdb2</span>', c: '' },
    { t: '[ <span class="t-ok">OK</span> ] Unlocked aurora_persistent (ext4, 14.6 GiB)', c: '' },
    { t: '<span class="t-amber">[aurora]</span> bind-mount: ~/Documents ~/Downloads ~/.config', c: '' },
    { t: '<span class="t-amber">[aurora]</span> Persistent volume mounted.', c: '' },
    { t: '<span class="t-amber">[aurora]</span> applying Tor kill-switch: <span class="t-green">fail-closed</span>', c: '' },
    { t: '<span class="t-amber">[aurora]</span> Tor circuit established. Boot mode setup complete.', c: '' },
    { t: '[ <span class="t-ok">OK</span> ] Started NetworkManager.', c: '' },
    { t: '[ <span class="t-ok">OK</span> ] Started GNOME Display Manager.', c: '' },
    { t: '<span class="t-green">welcome to auroraos — login: aurora</span>', c: '' }
  ];

  function typeLine(lineObj, done) {
    var div = document.createElement('div');
    div.className = 'ln';
    log.appendChild(div);

    // We type the raw text but render HTML at the end for the colored spans.
    // Simplest robust approach: write the HTML line, then a cursor, with a short delay.
    div.innerHTML = lineObj.t;
    var cursor = document.createElement('span');
    cursor.className = 'term__cursor';
    div.appendChild(cursor);
    log.scrollTop = log.scrollHeight;
    setTimeout(function () {
      done();
    }, 220 + Math.random() * 180);
  }

  function runBoot(i) {
    if (i >= bootLines.length) return;
    typeLine(bootLines[i], function () { runBoot(i + 1); });
  }

  if ('IntersectionObserver' in window) {
    var tio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting && !started) {
          started = true;
          runBoot(0);
          tio.unobserve(e.target);
        }
      });
    }, { threshold: 0.4 });
    tio.observe(log);
  } else {
    runBoot(0);
  }
})();
