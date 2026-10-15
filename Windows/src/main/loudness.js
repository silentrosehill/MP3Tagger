// Loudness: measuring (in a worker thread), the lossless target maths, and the limiter boost for quiet
// songs whose peaks leave no room. Port of Loudness.swift.
const fs = require('fs')
const path = require('path')
const os = require('os')
const crypto = require('crypto')
const { spawn } = require('child_process')
const { Worker } = require('worker_threads')
const id3 = require('./id3')
const mp3 = require('./mp3')
const tools = require('./tools')
const { settings, dataDir } = require('./store')

const SPOTIFY = -14
const STEP_DB = 1.5
const PEAK_CEILING_DB = -0.5
const LIMITER_CEILING = 0.85   // ≈ −1.4 dBFS: Spotify leaves 1 dB for lossy files, plus encoder overshoot margin

const target = () => settings.get('loudnessTarget', SPOTIFY)

let worker, nextId = 0
const pending = new Map()
function ask(kind, file) {
  if (!worker) {
    // inside the packaged app the worker runs from the unpacked copy (a worker can't start from inside app.asar)
    worker = new Worker(path.join(__dirname, 'audioWorker.js').replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`))
    worker.on('message', ({ id, result, error }) => {
      const p = pending.get(id); pending.delete(id)
      if (p) error ? p.reject(new Error(error)) : p.resolve(result)
    })
    worker.on('error', e => { for (const p of pending.values()) p.reject(e); pending.clear(); worker = null })
  }
  return new Promise((resolve, reject) => { const id = ++nextId; pending.set(id, { resolve, reject }); worker.postMessage({ id, kind, file }) })
}

// results are remembered per file version (path + size + modified time)
const cache = new Map()
const key = file => { try { const s = fs.statSync(file); return `${file}|${s.size}|${s.mtimeMs}` } catch { return null } }

async function measure(file, { cached = true } = {}) {
  const k = cached && key(file)
  if (k && cache.has(k)) return cache.get(k)
  const r = await ask('measure', file)
  const result = { lufs: r.lufs, peak: r.peak, peakDB: r.peak > 0 ? 20 * Math.log10(r.peak) : -120 }
  if (k) cache.set(k, result)
  return result
}

const spectrum = file => ask('spectrum', file)

/** Gain steps (1.5 dB each) that bring `r` to the target, capped so peaks stay below the ceiling. */
function recommendedSteps(r, t = target()) {
  const wanted = Math.round((t - r.lufs) / STEP_DB)
  if (wanted <= 0) return { steps: wanted, limited: false }
  const headroom = Math.max(Math.floor((PEAK_CEILING_DB - r.peakDB) / STEP_DB), 0)
  return wanted > headroom ? { steps: headroom, limited: true } : { steps: wanted, limited: false }
}
const losslessReach = r => r.lufs + recommendedSteps(r).steps * STEP_DB

const backupsDir = () => process.env.MP3TAGGER_BACKUPS || path.join(dataDir(), 'Originals')

function runFFmpeg(ffmpeg, args) {
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, args, { windowsHide: true })
    let err = ''
    p.stderr.on('data', d => { err += d })
    p.on('error', reject)
    p.on('close', code => (code === 0 ? resolve() : reject(new Error('ffmpeg failed: ' + err.trim()))))
  })
}

/**
 * Raises a quiet song to the target like Spotify's Loud mode: apply the gain and let a limiter hold back only
 * the loudest peaks. Re-encodes once at 320 kbps, always from the untouched original (kept in backupsDir and
 * linked in the tags, so Reset can restore it exactly). Returns the tag now in the file.
 */
async function limiterBoost(file, t = target()) {
  const ffmpeg = tools.find('ffmpeg')
  if (!ffmpeg) throw new Error('Needs ffmpeg — set it up in the Download tab')
  const tag = id3.read(file)
  const hasBackup = !!tag.originalBackup && fs.existsSync(tag.originalBackup)
  const source = hasBackup ? tag.originalBackup : file
  const before = await measure(source)
  if (before.lufs >= t - 0.3) return hasBackup ? restoreOriginal(file, tag) : tag
  if (!hasBackup) {
    fs.mkdirSync(backupsDir(), { recursive: true })
    const backup = path.join(backupsDir(), crypto.randomUUID() + '.mp3')
    fs.copyFileSync(file, backup)
    tag.originalBackup = backup
  }
  // limit at 4× the sample rate so peaks between samples are caught too, then back to the song's own rate
  const sr = mp3.layout(id3.audioOf(fs.readFileSync(source))).sampleRate || 44100
  const tmp = path.join(os.tmpdir(), `mp3tagger-boost-${crypto.randomUUID()}.mp3`)
  try {
    let gain = t - before.lufs
    for (let attempt = 0; attempt < 3; attempt++) {
      const chain = `aresample=${sr * 4},volume=${gain.toFixed(2)}dB,alimiter=limit=${LIMITER_CEILING.toFixed(3)}:attack=5:release=80:level=0,aresample=${sr}`
      await runFFmpeg(ffmpeg, ['-y', '-hide_banner', '-loglevel', 'error', '-i', source, '-map', '0:a:0', '-map_metadata', '-1',
        '-af', chain, '-c:a', 'libmp3lame', '-b:a', '320k', '-ar', String(sr), '-id3v2_version', '0', '-write_id3v1', '0', tmp])
      const miss = t - (await measure(tmp, { cached: false })).lufs
      if (Math.abs(miss) <= 0.3 || attempt === 2) break
      gain += miss   // the limiter shaved some loudness off; add it back
    }
    tag.limiterDB = Math.round(gain * 10) / 10
    tag.gainSteps = 0
    id3.write(tag, tmp, file)
  } finally {
    fs.rmSync(tmp, { force: true })
  }
  return tag
}

/** Undoes a limiter boost: the kept original audio comes back under the song's current tags. */
function restoreOriginal(file, current) {
  const backup = current.originalBackup
  if (!backup || !fs.existsSync(backup)) throw new Error("The original copy of this song is missing, so it can't be restored.")
  const original = id3.read(backup)
  const tag = { ...current, limiterDB: 0, originalBackup: '', gainSteps: original.gainSteps }
  id3.write(tag, backup, file)
  fs.rmSync(backup, { force: true })
  return tag
}

module.exports = { measure, spectrum, recommendedSteps, losslessReach, limiterBoost, restoreOriginal, target, SPOTIFY, STEP_DB, PEAK_CEILING_DB }
