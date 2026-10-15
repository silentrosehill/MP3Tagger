// Minimal ID3 tag reader (v2.2/2.3/2.4 + v1) and writer (always v2.3, the version Spotify's
// local-files importer handles best). Port of the Mac app's ID3.swift.
const fs = require('fs')
const path = require('path')
const os = require('os')
const crypto = require('crypto')
const mp3 = require('./mp3')

const EDITED = new Set(['TIT2', 'TPE1', 'TALB', 'TPE2', 'TYER', 'TDRC', 'TRCK', 'TCON', 'APIC'])
const V22 = { TT2: 'TIT2', TP1: 'TPE1', TAL: 'TALB', TP2: 'TPE2', TYE: 'TYER', TRK: 'TRCK', TCO: 'TCON', PIC: 'PIC' }

function emptyTag() {
  return {
    title: '', artist: '', album: '', albumArtist: '', year: '', track: '', genre: '',
    cover: null,              // Buffer (JPEG or PNG)
    coverMime: 'image/jpeg',
    gainSteps: 0,             // lossless volume change in 1.5 dB steps (TXXX MP3TAGGER_GAIN)
    limiterDB: 0,             // limiter boost in dB (TXXX MP3TAGGER_LIMITER)
    originalBackup: '',       // untouched original kept for Reset (TXXX MP3TAGGER_ORIGINAL)
    otherFrames: [],          // [{id, body}] from a v2.3 tag, kept as-is
  }
}

const syncsafe = (d, o) => ((d[o] & 0x7f) << 21) | ((d[o + 1] & 0x7f) << 14) | ((d[o + 2] & 0x7f) << 7) | (d[o + 3] & 0x7f)
const be32 = (d, o) => ((d[o] << 24) >>> 0) + (d[o + 1] << 16) + (d[o + 2] << 8) + d[o + 3]

function header(d) {
  if (d.length < 10 || d[0] !== 0x49 || d[1] !== 0x44 || d[2] !== 0x33) return null
  return { major: d[3], flags: d[5], size: syncsafe(d, 6) }
}

function deunsync(d) {
  const out = Buffer.alloc(d.length)
  let n = 0, prevFF = false
  for (const b of d) {
    if (prevFF && b === 0) { prevFF = false; continue }
    out[n++] = b
    prevFF = b === 0xff
  }
  return out.subarray(0, n)
}

function decodeString(enc, raw) {
  switch (enc) {
    case 0: return raw.toString('latin1')
    case 1: {
      if (raw.length >= 2 && raw[0] === 0xfe && raw[1] === 0xff) return new TextDecoder('utf-16be').decode(raw.subarray(2))
      if (raw.length >= 2 && raw[0] === 0xff && raw[1] === 0xfe) return new TextDecoder('utf-16le').decode(raw.subarray(2))
      return new TextDecoder('utf-16le').decode(raw)
    }
    case 2: return new TextDecoder('utf-16be').decode(raw)
    default: return raw.toString('utf8')
  }
}

function text(f) {
  if (!f.length) return ''
  // multiple values are NUL separated (and UTF-16 strings may carry a BOM per value)
  const s = decodeString(f[0], f.subarray(1)).replace(/﻿/g, '')
  return s.split('\0').find(x => x.length) || ''
}

function txxx(f) {
  if (!f.length) return null
  const parts = decodeString(f[0], f.subarray(1)).replace(/﻿/g, '').split('\0')
  return parts.length >= 2 ? [parts[0], parts[1]] : null
}

function cleanGenre(g) {
  const m = /^\(\d+\)(.+)$/.exec(g)
  return m ? m[1] : g
}

function picture(f, v22) {
  if (f.length <= 4) return null
  const enc = f[0]
  let i = 1, mime = 'image/jpeg'
  if (v22) {
    if (f.toString('latin1', 1, 4).toUpperCase() === 'PNG') mime = 'image/png'
    i = 4
  } else {
    const z = f.indexOf(0, i)
    if (z < 0) return null
    if (f.toString('latin1', i, z).toLowerCase().includes('png')) mime = 'image/png'
    i = z + 1
  }
  if (i >= f.length) return null
  const type = f[i++]
  if (enc === 1 || enc === 2) {
    while (i + 1 < f.length && !(f[i] === 0 && f[i + 1] === 0)) i += 2
    i += 2
  } else {
    while (i < f.length && f[i] !== 0) i++
    i++
  }
  if (i >= f.length) return null
  return { mime, img: Buffer.from(f.subarray(i)), type }
}

function readV1(d, tag) {
  if (d.length < 128) return
  const t = d.subarray(d.length - 128)
  if (t.toString('latin1', 0, 3) !== 'TAG') return
  const field = (o, l) => { const b = t.subarray(o, o + l); const z = b.indexOf(0); return b.subarray(0, z < 0 ? l : z).toString('latin1').trim() }
  tag.title = field(3, 30); tag.artist = field(33, 30); tag.album = field(63, 30); tag.year = field(93, 4)
}

function parse(data) {
  const tag = emptyTag()
  const h = header(data)
  if (!h) { readV1(data, tag); return tag }
  const { major, flags, size } = h
  let body = data.subarray(10, Math.min(10 + size, data.length))
  if ((flags & 0x80) && major < 4) body = deunsync(body)
  let pos = 0
  if ((flags & 0x40) && major === 3 && body.length >= 4) pos = be32(body, 0) + 4
  else if ((flags & 0x40) && major === 4 && body.length >= 4) pos = syncsafe(body, 0)

  const idLen = major === 2 ? 3 : 4, hdrLen = major === 2 ? 6 : 10
  while (pos + hdrLen <= body.length) {
    const idBytes = body.subarray(pos, pos + idLen)
    if (!idBytes.every(b => (b >= 0x41 && b <= 0x5a) || (b >= 0x30 && b <= 0x39))) break
    const id = idBytes.toString('latin1')
    const fsize = major === 2 ? (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5]
      : major === 3 ? be32(body, pos + 4) : syncsafe(body, pos + 4)
    const start = pos + hdrLen
    if (fsize <= 0 || start + fsize > body.length) break
    let fbody = body.subarray(start, start + fsize)
    if (major === 4 && (body[pos + 9] & 0x02)) fbody = deunsync(fbody)
    pos = start + fsize

    const key = major === 2 ? (V22[id] || id) : id
    switch (key) {
      case 'TIT2': tag.title = text(fbody); break
      case 'TPE1': tag.artist = text(fbody); break
      case 'TALB': tag.album = text(fbody); break
      case 'TPE2': tag.albumArtist = text(fbody); break
      case 'TYER': case 'TDRC': if (!tag.year) tag.year = text(fbody); break
      case 'TRCK': tag.track = text(fbody); break
      case 'TCON': tag.genre = cleanGenre(text(fbody)); break
      case 'APIC': case 'PIC': {
        const p = picture(fbody, major === 2)
        if (p && (!tag.cover || p.type === 3)) { tag.cover = p.img; tag.coverMime = p.mime }
        break
      }
      default: {
        const x = key === 'TXXX' ? txxx(fbody) : null
        if (x && x[0] === 'MP3TAGGER_GAIN') tag.gainSteps = parseInt(x[1], 10) || 0
        else if (x && x[0] === 'MP3TAGGER_LIMITER') tag.limiterDB = parseFloat(x[1]) || 0
        else if (x && x[0] === 'MP3TAGGER_ORIGINAL') tag.originalBackup = x[1]
        else if (major === 3) tag.otherFrames.push({ id, body: Buffer.from(fbody) })
      }
    }
  }
  return tag
}

function read(file) { return parse(fs.readFileSync(file)) }

/** The MP3 audio of `data`, without the ID3v2 tag in front or an ID3v1 tag at the end. */
function audioOf(data) {
  let audio = data
  const h = header(data)
  if (h) {
    const end = Math.min(10 + h.size + (h.flags & 0x10 ? 10 : 0), data.length)
    audio = data.subarray(end)
  }
  if (audio.length >= 128 && audio.toString('latin1', audio.length - 128, audio.length - 125) === 'TAG') {
    audio = audio.subarray(0, audio.length - 128)
  }
  return audio
}

function frame(id, body) {
  const h = Buffer.alloc(10)
  h.write(id, 0, 'latin1')
  h.writeUInt32BE(body.length, 4)
  return Buffer.concat([h, body])
}

/** Latin-1 when possible (most compatible), otherwise UTF-16 with BOM. */
function encodeText(s) {
  if ([...s].every(c => c.codePointAt(0) <= 0xff)) return Buffer.concat([Buffer.from([0]), Buffer.from(s, 'latin1')])
  return Buffer.concat([Buffer.from([1, 0xff, 0xfe]), Buffer.from(s, 'utf16le')])
}

/**
 * Writes `tag` onto the audio of `source`, saving at `destination` (via a temp file, so an existing file is
 * only replaced once the new one is complete). `gainDelta` changes the volume losslessly (1.5 dB steps);
 * `trim` = {start, end|null} cuts whole frames. Returns the total gain now recorded in the file.
 */
function write(tag, source, destination, { gainDelta = 0, trim = null } = {}) {
  const data = fs.readFileSync(source)
  let audio = Buffer.from(audioOf(data))   // copy: gain edits happen in place
  const applied = mp3.applyGain(audio, gainDelta)
  if (trim) audio = mp3.cut(audio, trim.start, trim.end)
  const gainSteps = tag.gainSteps + applied - gainDelta

  const frames = []
  const addText = (id, v) => { v = (v || '').trim(); if (v) frames.push(frame(id, encodeText(v))) }
  addText('TIT2', tag.title); addText('TPE1', tag.artist); addText('TALB', tag.album)
  addText('TPE2', tag.albumArtist); addText('TYER', tag.year); addText('TRCK', tag.track); addText('TCON', tag.genre)
  const addTXXX = (desc, value) => frames.push(frame('TXXX', Buffer.concat([Buffer.from([3]), Buffer.from(desc, 'utf8'), Buffer.from([0]), Buffer.from(value, 'utf8')])))
  if (gainSteps !== 0) addTXXX('MP3TAGGER_GAIN', String(gainSteps))
  if (tag.limiterDB) addTXXX('MP3TAGGER_LIMITER', tag.limiterDB.toFixed(1))
  if (tag.originalBackup) addTXXX('MP3TAGGER_ORIGINAL', tag.originalBackup)
  if (tag.cover && tag.cover.length) {
    frames.push(frame('APIC', Buffer.concat([Buffer.from([0]), Buffer.from(tag.coverMime || 'image/jpeg', 'latin1'),
      Buffer.from([0, 3, 0]), Buffer.from(tag.cover)])))
  }
  for (const f of tag.otherFrames || []) if (!EDITED.has(f.id)) frames.push(frame(f.id, Buffer.from(f.body)))

  const framesBuf = Buffer.concat(frames)
  const padding = 1024, n = framesBuf.length + padding
  const head = Buffer.from([0x49, 0x44, 0x33, 3, 0, 0, (n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f])
  writeSafely(Buffer.concat([head, framesBuf, Buffer.alloc(padding), audio]), destination)
  return gainSteps
}

/** Temp file + rename; if the folder doesn't allow that, rewrite in place keeping a backup until it succeeds. */
function writeSafely(buf, dest) {
  const tmp = path.join(path.dirname(dest), `.${path.basename(dest)}.${crypto.randomBytes(4).toString('hex')}.tmp`)
  try {
    fs.writeFileSync(tmp, buf)
    fs.renameSync(tmp, dest)
    return
  } catch (e) {
    try { fs.unlinkSync(tmp) } catch {}
    if (!fs.existsSync(dest)) { fs.writeFileSync(dest, buf); return }
  }
  const original = fs.readFileSync(dest)
  const backup = path.join(os.tmpdir(), `MP3Tagger-backup-${crypto.randomUUID()}.mp3`)
  fs.writeFileSync(backup, original)
  try {
    fs.writeFileSync(dest, buf)
  } catch (e) {
    try { fs.writeFileSync(dest, original) } catch {}
    throw e
  }
  try { fs.unlinkSync(backup) } catch {}
}

module.exports = { read, parse, write, audioOf, emptyTag }
