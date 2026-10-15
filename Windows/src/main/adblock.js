// Built-in ad blocker for the in-app YouTube browser: blocks ad/tracker requests, hides ad slots, skips video ads.
const { app } = require('electron')
const { settings } = require('./store')

const blockedHosts = [
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'google-analytics.com', 'googletagservices.com',
  'googletagmanager.com', 'adservice.google.', 'ads.youtube.com', 'scorecardresearch.com', 'amazon-adsystem.com',
  'adnxs.com', 'taboola.com', 'outbrain.com', 'criteo.com', 'moatads.com',
]
const blockedPaths = [/youtube\.com\/api\/stats\/ads/, /youtube\.com\/pagead\//, /youtube\.com\/ptracking/, /youtube\.com\/get_midroll_/, /youtube\.com\/api\/stats\/qoe\?.*adformat/]
const hidden = [
  'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-display-ad-renderer', 'ytd-promoted-sparkles-web-renderer',
  'ytd-promoted-video-renderer', 'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer', 'ytd-companion-slot-renderer',
  'ytd-player-legacy-desktop-watch-ads-renderer', '#masthead-ad', '#player-ads', '.ytp-ad-overlay-container',
  'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)', 'ytd-merch-shelf-renderer', 'ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]',
]
const skipScript = `(function () {
  if (window.__mp3taggerSkip) return; window.__mp3taggerSkip = true;
  setInterval(() => {
    const player = document.querySelector('.html5-video-player');
    if (!player || !player.classList.contains('ad-showing')) return;
    const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
    if (skip) { skip.click(); return; }
    const v = document.querySelector('video');
    if (v && isFinite(v.duration) && v.duration > 0) { v.muted = true; v.currentTime = v.duration; }
  }, 400);
})();`

const enabled = () => settings.get('adBlock', true)

function setup(ses) {
  ses.webRequest.onBeforeRequest((details, cb) => {
    if (!enabled()) return cb({})
    let host = ''
    try { host = new URL(details.url).hostname } catch {}
    const block = blockedHosts.some(h => host === h || host.endsWith('.' + h) || (h.endsWith('.') && host.includes(h)))
      || blockedPaths.some(r => r.test(details.url))
    cb({ cancel: block })
  })
  app.on('web-contents-created', (_e, contents) => {
    if (contents.getType() !== 'webview' || contents.session !== ses) return
    contents.on('dom-ready', () => {
      if (!enabled() || !/youtube\.com/.test(contents.getURL())) return
      contents.insertCSS(hidden.join(', ') + ' { display: none !important; }').catch(() => {})
      contents.executeJavaScript(skipScript).catch(() => {})
    })
  })
}

module.exports = { setup }
