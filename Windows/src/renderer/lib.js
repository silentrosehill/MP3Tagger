// Shared bits for the interface: Preact (via htm, no build step), the app store, theme colours and helpers.
export { html, render, useState, useEffect, useRef, useMemo, useCallback, useLayoutEffect } from '../../node_modules/htm/preact/standalone.module.js'
import { useState, useEffect } from '../../node_modules/htm/preact/standalone.module.js'

export const api = window.api

// ───────────── Store: one object, components re-render when it changes ─────────────

const listeners = new Set()
export const S = {
  files: [],            // TrackFile objects (see files.js)
  selection: null,      // file id
  tab: 'files',         // files | history | find | download | changelog
  status: '',
  history: [],
  historySelection: null,
  settings: {},
  info: { version: '', changelog: '' },
  popover: null,        // 'theme' | 'info'
  sheet: null,          // { kind, ... }
  sidebarCollapsed: false,
  downloadedPaths: new Set(),
  coverTheme: null,     // theme taken from the cover on screen ("Match album cover")
}
let queued = false
export function touch() {
  if (queued) return
  queued = true
  queueMicrotask(() => { queued = false; listeners.forEach(f => f()) })
}
export function set(patch) { Object.assign(S, patch); touch() }
export function useStore() {
  const [, force] = useState(0)
  useEffect(() => { const f = () => force(n => n + 1); listeners.add(f); return () => listeners.delete(f) }, [])
  return S
}
export function setting(key, fallback) { const v = S.settings[key]; return v === undefined ? fallback : v }
export function saveSetting(key, value) { S.settings[key] = value; api.invoke('settings:set', key, value); touch() }

export function status(text) {
  set({ status: text })
}

// ───────────── Theme colours (same maths as the Mac app's AppTheme) ─────────────

export function hsb(h, s, b) {
  h = ((h % 1) + 1) % 1; s = Math.min(Math.max(s, 0), 1); b = Math.min(Math.max(b, 0), 1)
  const i = Math.floor(h * 6), f = h * 6 - i, p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
  const [r, g, bl] = [[b, t, p], [q, b, p], [p, b, t], [p, q, b], [t, p, b], [b, p, q]][i % 6]
  return '#' + [r, g, bl].map(v => Math.round(v * 255).toString(16).padStart(2, '0')).join('')
}
export function fromHex(hex) {
  const n = parseInt(hex.replace('#', ''), 16)
  const r = (n >> 16 & 255) / 255, g = (n >> 8 & 255) / 255, b = (n & 255) / 255
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
  let h = 0
  if (d) {
    if (mx === r) h = ((g - b) / d) % 6
    else if (mx === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h = ((h / 6) + 1) % 1
  }
  return { hue: h, saturation: mx ? d / mx : 0, brightness: mx }
}
export function palette(t) {
  const c = (dh, s, b) => hsb(t.hue + dh, s, b)
  let toPink = 0.966 - t.hue
  toPink -= Math.round(toPink)   // shortest way round the hue wheel
  return {
    purple: c(0, t.saturation, t.brightness),
    indigo: c(-0.07, t.saturation + 0.08, t.brightness * 0.77),
    pink: c(Math.min(Math.max(toPink, -0.185), 0.185), t.saturation * 0.77, 1),
    accent: c(-0.03, t.saturation * 0.87, Math.min(t.brightness + 0.03, 0.96)),
  }
}
export const PURPLE = fromHex('#B23AEE')
export const AQUA = fromHex('#3F83F2')
export const PRESETS = [
  ['Purple', PURPLE], ['Pink', fromHex('#EE3A9A')], ['Red', fromHex('#E5484D')], ['Orange', fromHex('#F07B2A')],
  ['Gold', fromHex('#D9A521')], ['Green', fromHex('#2FBF71')], ['Teal', fromHex('#1FB5B0')], ['Blue', fromHex('#3A7BEE')],
  ['Graphite', { hue: 0.7, saturation: 0.08, brightness: 0.62 }],
]
export const sameColor = (a, b) => Math.abs(a.hue - b.hue) < 0.005 && Math.abs(a.saturation - b.saturation) < 0.01 && Math.abs(a.brightness - b.brightness) < 0.01

/** The most prominent vivid colour of a cover. Mostly-grey covers give a graphite theme. */
export async function themeFromCover(url) {
  try {
    const img = await loadImage(url)
    const n = 32, cv = new OffscreenCanvas(n, n), ctx = cv.getContext('2d')
    ctx.drawImage(img, 0, 0, n, n)
    const px = ctx.getImageData(0, 0, n, n).data
    const B = 36
    const score = new Array(B).fill(0), sx = new Array(B).fill(0), sy = new Array(B).fill(0), ss = new Array(B).fill(0), sv = new Array(B).fill(0)
    let greyV = 0, gx = 0, gy = 0
    for (let i = 0; i < px.length; i += 4) {
      const r = px[i] / 255, g = px[i + 1] / 255, b = px[i + 2] / 255
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
      const v = mx, s = mx ? d / mx : 0
      let h = 0
      if (d > 0) {
        if (mx === r) h = ((g - b) / d) % 6; else if (mx === g) h = (b - r) / d + 2; else h = (r - g) / d + 4
        h = ((h / 6) + 1) % 1
      }
      greyV += v
      const w = s * s * (v < 0.18 ? 0.05 : v)
      if (w <= 0) continue
      const k = Math.min(Math.floor(h * B), B - 1)
      score[k] += w; sx[k] += Math.cos(h * 2 * Math.PI) * w; sy[k] += Math.sin(h * 2 * Math.PI) * w; ss[k] += s * w; sv[k] += v * w
      gx += Math.cos(h * 2 * Math.PI) * d; gy += Math.sin(h * 2 * Math.PI) * d
    }
    const pixels = n * n
    let best = 0, bestScore = -1
    for (let k = 0; k < B; k++) {
      const s3 = score[k] + score[(k + 1) % B] + score[(k + B - 1) % B]
      if (s3 > bestScore) { bestScore = s3; best = k }
    }
    if (bestScore / pixels < 0.03) {
      return { hue: ((Math.atan2(gy, gx) / (2 * Math.PI)) + 1) % 1, saturation: 0.08, brightness: Math.min(Math.max(greyV / pixels + 0.2, 0.5), 0.75) }
    }
    let x = 0, y = 0, s2 = 0, v2 = 0, w = 0
    for (const k of [(best + B - 1) % B, best, (best + 1) % B]) { x += sx[k]; y += sy[k]; s2 += ss[k]; v2 += sv[k]; w += score[k] }
    return { hue: ((Math.atan2(y, x) / (2 * Math.PI)) + 1) % 1, saturation: Math.min(Math.max(s2 / w, 0.45), 0.85), brightness: Math.min(Math.max(v2 / w, 0.62), 0.95) }
  } catch { return null }
}

// ───────────── Images ─────────────

const urlCache = new WeakMap()
/** Object URL for cover bytes (cached per buffer). */
export function coverURL(bytes, mime = 'image/jpeg') {
  if (!bytes || !bytes.length) return null
  let u = urlCache.get(bytes)
  if (!u) { u = URL.createObjectURL(new Blob([bytes], { type: mime })); urlCache.set(bytes, u) }
  return u
}
export function loadImage(url) {
  return new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = url })
}
/** Any image bytes → centred square JPEG, at most 1000 px (what Spotify shows reliably). */
export async function jpegCover(bytes, maxSide = 1000) {
  const bmp = await createImageBitmap(new Blob([bytes]))
  const side = Math.min(bmp.width, bmp.height), out = Math.min(side, maxSide)
  const cv = new OffscreenCanvas(out, out), ctx = cv.getContext('2d')
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, out, out)
  const blob = await cv.convertToBlob({ type: 'image/jpeg', quality: 0.9 })
  return { bytes: new Uint8Array(await blob.arrayBuffer()), width: side }
}

// ───────────── Formatting ─────────────

export function fmtTime(s) {
  s = Math.max(0, Math.round(s || 0))
  return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
    : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}
export const minus = v => (v < 0 ? '−' : '') + Math.abs(v).toFixed(1)
export function relTime(ms) {
  const d = (Date.now() - ms) / 1000
  if (d < 60) return 'Just now'
  if (d < 3600) { const m = Math.floor(d / 60); return `${m} minute${m === 1 ? '' : 's'} ago` }
  if (d < 86400) { const h = Math.floor(d / 3600); return `${h} hour${h === 1 ? '' : 's'} ago` }
  if (d < 86400 * 2) return 'Yesterday'
  if (d < 86400 * 7) return `${Math.floor(d / 86400)} days ago`
  return new Date(ms).toLocaleDateString()
}
export const baseName = p => p.split(/[\\/]/).pop().replace(/\.mp3$/i, '')
export const dirName = p => p.slice(0, Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\')))
export const cls = (...a) => a.filter(Boolean).join(' ')
/** Sets a range input's filled part. */
export const rangeStyle = (v, min, max) => `--p:${((v - min) / (max - min || 1)) * 100}%`
