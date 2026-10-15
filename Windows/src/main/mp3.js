// MP3 frame-level tools, ported from the Mac app (Loudness.applyGain and MP3Trim):
// lossless volume change (MP3Gain-style global_gain edits) and lossless trimming.
const BR1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
const BR2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
const SR = { 3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000] }
const SILENCE_FLOOR = 64

/** Frame header at `i`, or null. Only trusts a header followed by another matching one (or the end). */
function frameAt(b, i) {
  const n = b.length
  if (i + 4 > n || b[i] !== 0xff || (b[i + 1] & 0xe0) !== 0xe0) return null
  const ver = (b[i + 1] >> 3) & 3, layer = (b[i + 1] >> 1) & 3, crc = (b[i + 1] & 1) === 0
  const brIdx = b[i + 2] >> 4, srIdx = (b[i + 2] >> 2) & 3, pad = (b[i + 2] >> 1) & 1
  const mono = b[i + 3] >> 6 === 3
  if (ver === 1 || layer !== 1 || brIdx === 0 || brIdx === 15 || srIdx === 3 || !SR[ver]) return null
  const mpeg1 = ver === 3
  const rate = SR[ver][srIdx]
  const len = Math.floor((mpeg1 ? 144 : 72) * (mpeg1 ? BR1 : BR2)[brIdx] * 1000 / rate) + pad
  const sideLen = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
  return { len, ver, mpeg1, mono, crc, rate, sideLen, si: i + 4 + (crc ? 2 : 0) }
}

function followedOK(b, i, len) {
  const next = i + len, n = b.length
  if (next + 4 > n) return true
  return b[next] === 0xff && (b[next + 1] & 0xe0) === 0xe0 && ((b[next + 1] >> 3) & 3) === ((b[i + 1] >> 3) & 3)
    && ((b[next + 1] >> 1) & 3) === 1 && ((b[next + 2] >> 2) & 3) === ((b[i + 2] >> 2) & 3)
}

const isInfoTag = (b, at) => at + 4 <= b.length && (b.toString('latin1', at, at + 4) === 'Xing' || b.toString('latin1', at, at + 4) === 'Info')

/** Walks the frames of `audio` (the data after the ID3v2 tag). */
function layout(audio) {
  const out = { frames: [], info: null, infoTagAt: 0, samplesPerFrame: 1152, sampleRate: 44100 }
  const b = audio, n = b.length
  let i = 0
  while (i + 4 <= n) {
    const f = frameAt(b, i)
    if (!f) { i++; continue }
    if (f.len <= 4 || i + f.len > n) break
    if (!followedOK(b, i, f.len)) { i++; continue }
    const tagAt = f.si + f.sideLen
    if (out.frames.length === 0 && !out.info && isInfoTag(b, tagAt)) {
      out.info = { offset: i, length: f.len }
      out.infoTagAt = tagAt
    } else {
      if (out.frames.length === 0) { out.samplesPerFrame = f.mpeg1 ? 1152 : 576; out.sampleRate = f.rate }
      out.frames.push({ offset: i, length: f.len })
    }
    i += f.len
  }
  out.seconds = out.frames.length * out.samplesPerFrame / out.sampleRate
  return out
}

function readBits(b, base, start, count) {
  let v = 0
  for (let k = 0; k < count; k++) {
    const pos = start + k
    v = (v << 1) | ((b[base + (pos >> 3)] >> (7 - (pos & 7))) & 1)
  }
  return v >>> 0
}

function writeBits(b, base, start, count, value) {
  for (let k = 0; k < count; k++) {
    const pos = start + k
    const bit = (value >> (count - 1 - k)) & 1
    const mask = 1 << (7 - (pos & 7))
    const at = base + (pos >> 3)
    b[at] = bit ? b[at] | mask : b[at] & ~mask
  }
}

/**
 * Changes every audible Layer III granule's global_gain by up to `steps` (×1.5 dB), in place, and returns the
 * steps applied. Silent granules are left alone and the change stays within 64…255, so the opposite change
 * restores the file byte for byte.
 */
function applyGain(b, steps) {
  if (!steps) return 0
  const frames = []
  let minGain = 255, maxGain = 0
  const n = b.length
  let i = 0
  while (i + 4 <= n) {
    const f = frameAt(b, i)
    if (!f) { i++; continue }
    if (f.len <= 4 || i + f.len > n || f.si + f.sideLen > n) break
    if (!followedOK(b, i, f.len)) { i++; continue }
    if (!isInfoTag(b, f.si + f.sideLen)) {
      const nch = f.mono ? 1 : 2
      const offsets = []
      if (f.mpeg1) {
        const start = 9 + (f.mono ? 5 : 3) + 4 * nch
        for (let gr = 0; gr < 2; gr++) for (let ch = 0; ch < nch; ch++) offsets.push(start + (gr * nch + ch) * 59 + 21)
      } else {
        const start = 8 + (f.mono ? 1 : 2)
        for (let ch = 0; ch < nch; ch++) offsets.push(start + ch * 63 + 21)
      }
      const audible = offsets.filter(o => readBits(b, f.si, o - 21, 12) > 0 && readBits(b, f.si, o, 8) >= SILENCE_FLOOR)
      for (const o of audible) {
        const g = readBits(b, f.si, o, 8)
        minGain = Math.min(minGain, g); maxGain = Math.max(maxGain, g)
      }
      if (audible.length) frames.push({ header: i, si: f.si, sideLen: f.sideLen, crc: f.crc, bits: audible })
    }
    i += f.len
  }
  if (!frames.length) return 0
  const applied = steps < 0 ? Math.max(steps, Math.min(0, SILENCE_FLOOR - minGain)) : Math.min(steps, Math.max(0, 255 - maxGain))
  if (!applied) return 0
  for (const f of frames) {
    for (const o of f.bits) writeBits(b, f.si, o, 8, readBits(b, f.si, o, 8) + applied)
    if (!f.crc) continue
    // CRC-16 covers header bytes 2–3 and the side info
    let c = 0xffff
    const feed = byte => {
      for (let k = 7; k >= 0; k--) {
        const bitIn = (byte >> k) & 1, top = (c >> 15) & 1
        c = (c << 1) & 0xffff
        if (top ^ bitIn) c ^= 0x8005
      }
    }
    feed(b[f.header + 2]); feed(b[f.header + 3])
    for (let k = 0; k < f.sideLen; k++) feed(b[f.si + k])
    b[f.header + 4] = c >> 8; b[f.header + 5] = c & 0xff
  }
  return applied
}

/** CRC-16/ARC, the one LAME uses for its tag and music checksums. */
function crc16(d, start = 0, end = d.length) {
  let c = 0
  for (let i = start; i < end; i++) {
    c ^= d[i]
    for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xa001 : c >>> 1
  }
  return c
}

/** Keeps the audio from `start` to `end` seconds (null = to the end). Returns new MP3 data. */
function cut(audio, start, end) {
  const l = layout(audio)
  if (!l.frames.length) return audio
  const perSecond = l.sampleRate / l.samplesPerFrame
  const first = Math.min(Math.max(0, Math.floor(start * perSecond)), l.frames.length - 1)
  const last = Math.min(l.frames.length, Math.max(first + 1, end == null ? l.frames.length : Math.ceil(end * perSecond)))
  if (first === 0 && last === l.frames.length) return audio

  const kept = l.frames.slice(first, last)
  const music = Buffer.concat(kept.map(f => audio.subarray(f.offset, f.offset + f.length)))
  const lastF = l.frames[l.frames.length - 1]
  const tailStart = lastF.offset + lastF.length
  const tail = last === l.frames.length && tailStart < audio.length ? audio.subarray(tailStart) : Buffer.alloc(0)
  if (!l.info) return Buffer.concat([music, tail])

  const h = Buffer.from(audio.subarray(l.info.offset, l.info.offset + l.info.length))
  rewriteInfo(h, l.infoTagAt - l.info.offset, l.frames, first, last, music, first > 0, last < l.frames.length)
  return Buffer.concat([h, music, tail])
}

/** Updates the Xing/Info frame (frames, bytes, seek table) and the LAME tag (delay/padding, length, CRCs). */
function rewriteInfo(h, x, oldFrames, first, last, music, trimmedStart, trimmedEnd) {
  if (x + 8 > h.length) return
  const u32 = at => h.readUInt32BE(at)
  const put32 = (at, v) => h.writeUInt32BE(v >>> 0, at)
  const flags = u32(x + 4)
  let p = x + 8
  const removedFrames = oldFrames.length - (last - first)
  const removedBytes = oldFrames.reduce((s, f) => s + f.length, 0) - music.length
  if ((flags & 1) && p + 4 <= h.length) { put32(p, Math.max(1, u32(p) - removedFrames)); p += 4 }
  if ((flags & 2) && p + 4 <= h.length) { put32(p, Math.max(h.length, u32(p) - removedBytes)); p += 4 }
  if ((flags & 4) && p + 100 <= h.length) {
    const total = h.length + music.length
    const starts = []
    let pos = h.length
    for (let k = first; k < last; k++) { starts.push(pos); pos += oldFrames[k].length }
    for (let i = 0; i < 100; i++) {
      const idx = Math.min(starts.length - 1, Math.floor(i / 100 * starts.length))
      h[p + i] = Math.min(255, Math.floor(starts[idx] / total * 256))
    }
    p += 100
  }
  if (flags & 8) p += 4

  if (p + 36 > h.length) return
  for (let k = 0; k < 4; k++) { const c = h[p + k]; if (!((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a))) return }
  let delay = (h[p + 21] << 4) | (h[p + 22] >> 4)
  let padding = ((h[p + 22] & 0x0f) << 8) | h[p + 23]
  if (trimmedStart) delay = 0
  if (trimmedEnd) padding = 0
  h[p + 21] = delay >> 4; h[p + 22] = ((delay & 0x0f) << 4) | (padding >> 8); h[p + 23] = padding & 0xff
  put32(p + 28, h.length + music.length)
  const musicCRC = crc16(music)
  h[p + 32] = musicCRC >> 8; h[p + 33] = musicCRC & 0xff
  const tagCRC = crc16(h, 0, p + 34)
  h[p + 34] = tagCRC >> 8; h[p + 35] = tagCRC & 0xff
}

module.exports = { layout, applyGain, cut, crc16 }
