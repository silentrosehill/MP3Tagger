// Downloads (yt-dlp + ffmpeg), YouTube search for the Auto tab, and 30-second previews. Port of Downloader.swift
// and Find.swift. Jobs live here; the window gets every change through `send('job', job)`.
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { spawn } = require('child_process')
const { app } = require('electron')
const tools = require('./tools')
const id3 = require('./id3')
const mp3 = require('./mp3')
const loudness = require('./loudness')
const lookup = require('./lookup')
const { jpegCover } = require('./images')
const { settings } = require('./store')

const QUALITIES = { best: '0', k320: '320K', k192: '192K', k128: '128K' }
let send = () => {}
const jobs = new Map()

function folder() { return settings.get('dlFolder', app.getPath('music')) }

function publicJob(j) {
  const { process: _p, lastError: _e, cancelRequested: _c, ...rest } = j
  return rest
}
const update = (j, patch) => { Object.assign(j, patch); send('job', publicJob(j)) }

/** Splits streamed process output into lines. */
function lines(stream, onLine) {
  let buf = ''
  stream.on('data', d => {
    buf += d.toString('utf8')
    let i
    while ((i = buf.search(/\r?\n|\r/)) >= 0) {
      const line = buf.slice(0, i)
      buf = buf.slice(buf[i] === '\r' && buf[i + 1] === '\n' ? i + 2 : i + 1)
      onLine(line)
    }
  })
}

function start(link, { openWhenDone = false } = {}) {
  const text = (link || '').trim()
  let u
  try { u = new URL(text) } catch {}
  if (!u || !/^https?:$/.test(u.protocol) || !u.host) return { error: "That doesn't look like a link. Paste a full https:// address." }
  const ytdlp = tools.find('yt-dlp'), ffmpeg = tools.find('ffmpeg')
  if (!ytdlp || !ffmpeg) return { error: 'Set up yt-dlp and ffmpeg first.' }

  const job = { id: crypto.randomUUID(), link: text, title: text, thumbnail: null, progress: 0, phase: 'starting', file: null, openWhenDone, error: null }
  jobs.set(job.id, job)
  const quality = QUALITIES[settings.get('dlQuality', 'best')] || '0'
  const args = [
    '--no-playlist', '--no-mtime', '-x', '--audio-format', 'mp3', '--audio-quality', quality,
    '--embed-thumbnail', '--embed-metadata', '--ffmpeg-location', path.dirname(ffmpeg),
    '-P', folder(), '-o', '%(title).150B.%(ext)s',
    '--newline', '--progress', '--no-simulate', '--encoding', 'utf-8',
    '--progress-template', 'download:[dl] %(progress._percent_str)s',
    '--print', 'before_dl:[title]%(title)s', '--print', 'before_dl:[thumb]%(thumbnail)s',
    '--print', 'after_move:[file]%(filepath)s',
    '--', text,   // "--" so a link can never be read as an option
  ]
  const p = spawn(ytdlp, args, { env: tools.env(), windowsHide: true })
  job.process = p
  const onLine = raw => {
    const line = raw.trim()
    if (line.startsWith('[title]')) update(job, { title: line.slice(7) })
    else if (line.startsWith('[thumb]')) update(job, { thumbnail: line.slice(7) })
    else if (line.startsWith('[file]')) job.file = line.slice(6)
    else if (line.startsWith('[dl]')) {
      const v = parseFloat(line.slice(4).replace('%', ''))
      if (!isNaN(v)) update(job, { progress: Math.min(Math.max(v / 100, 0), 1), phase: v >= 100 ? 'converting' : 'downloading' })
    } else if (line.startsWith('ERROR:')) job.lastError = line.slice(6).trim()
  }
  lines(p.stdout, onLine); lines(p.stderr, onLine)
  p.on('error', e => update(job, { phase: 'failed', error: "Couldn't start yt-dlp: " + e.message }))
  p.on('close', code => finish(job, code))
  send('job', publicJob(job))
  return { job: publicJob(job) }
}

function friendly(e) {
  if (!e) return null
  const l = e.toLowerCase()
  if (l.includes('sign in to confirm') || l.includes('not a bot')) return "YouTube asked to confirm you're not a bot. Try again later, or click Update yt-dlp."
  if (l.includes('private video') || l.includes('unavailable')) return 'This video is private or unavailable.'
  if (l.includes('unsupported url')) return "That site or link isn't supported."
  if (l.includes('http error 403') || l.includes('nsig') || l.includes('signature')) return 'YouTube changed something. Click Update yt-dlp, then try again.'
  return e
}

async function finish(job, code) {
  job.process = null
  if (job.cancelRequested) return update(job, { phase: 'cancelled' })
  if (code !== 0 || !job.file) return update(job, { phase: 'failed', error: friendly(job.lastError) || `Download failed (yt-dlp exit code ${code}).` })
  update(job, { phase: 'tagging' })
  const file = job.file
  let title = null
  try { title = await polishTags(file, settings.get('dlMatchLoudness', true)) } catch {}
  if (settings.get('dlOfficialTags', true)) {
    let duration
    try { duration = mp3.layout(id3.audioOf(fs.readFileSync(file))).seconds } catch {}
    const t = await lookup.fillOfficialTags(file, duration)
    if (t) title = t
  }
  // the MP3 itself is fine even if tag clean-up failed
  update(job, { phase: 'done', title: title || job.title, file })
  send('downloadFinished', publicJob(job))
}

/**
 * Square cover, "Artist - Title (Official Video)" → artist + clean title, optional loudness match (lossless,
 * then the limiter if it's still quiet), ID3 v2.3 for Spotify.
 */
async function polishTags(file, matchLoudness) {
  const tag = id3.read(file)
  let title = tag.title || path.parse(file).name
  const noise = /\s*[([][^)\]]*\b(official|lyrics?|audio|video|visuali[sz]er|hd|hq|4k|mv|m\/v)\b[^)\]]*[)\]]/gi
  title = title.replace(noise, '')
  const dash = title.indexOf(' - ')
  if (dash > 0) {
    const left = title.slice(0, dash).trim(), right = title.slice(dash + 3).trim()
    if (left && right) { tag.artist = left; title = right }
  }
  tag.title = title.trim()
  if (tag.cover) { const j = jpegCover(tag.cover); if (j) { tag.cover = j; tag.coverMime = 'image/jpeg' } }
  let delta = 0
  if (matchLoudness) {
    try { delta = loudness.recommendedSteps(await loudness.measure(file, { cached: false })).steps; tag.gainSteps += delta } catch {}
  }
  id3.write(tag, file, file, { gainDelta: delta })
  if (matchLoudness && tools.find('ffmpeg')) {
    try {
      const r = await loudness.measure(file, { cached: false })
      if (r.lufs < loudness.target() - 1) await loudness.limiterBoost(file)
    } catch {}
  }
  return tag.title
}

function cancel(id) {
  const j = jobs.get(id)
  if (!j || !j.process) return
  j.cancelRequested = true
  j.process.kill()
}
function remove(id) { cancel(id); jobs.delete(id) }
function cancelAll() { for (const j of jobs.values()) if (j.process) j.process.kill() }

// MARK: Auto tab — YouTube search with yt-dlp ("ytsearch"), no API key needed

let searchProc = null
function searchYouTube(query) {
  const ytdlp = tools.find('yt-dlp')
  if (!ytdlp) return Promise.resolve({ error: 'yt-dlp is not set up' })
  if (searchProc) searchProc.kill()
  return new Promise(resolve => {
    const p = spawn(ytdlp, ['--flat-playlist', '--dump-json', '--no-warnings', '--encoding', 'utf-8', '--', `ytsearch8:${query}`], { env: tools.env(), windowsHide: true })
    searchProc = p
    let out = '', err = ''
    p.stdout.on('data', d => { out += d.toString('utf8') })
    p.stderr.on('data', d => { err += d })
    p.on('error', e => resolve({ error: "Couldn't start yt-dlp: " + e.message }))
    p.on('close', code => {
      if (searchProc === p) searchProc = null
      if (p.killed) return resolve({ cancelled: true })
      const results = []
      for (const line of out.split(/\r?\n/)) {
        try {
          const o = JSON.parse(line)
          if (o.id && o.title) results.push({ id: o.id, title: o.title, channel: o.channel || o.uploader || '', duration: o.duration || null, views: o.view_count || null })
        } catch {}
      }
      const failure = code === 0 ? null : (err.trim().split(/\r?\n/).pop() || 'Search failed.').replace('ERROR: ', '')
      resolve({ results, error: failure || (results.length ? null : 'No matches. Try other words.') })
    })
  })
}

let previewProc = null
/** A direct audio stream URL for a video (the player plays its first 30 s). */
function previewURL(link) {
  const ytdlp = tools.find('yt-dlp')
  if (!ytdlp) return Promise.resolve(null)
  if (previewProc) previewProc.kill()
  return new Promise(resolve => {
    const p = spawn(ytdlp, ['--no-warnings', '-f', 'bestaudio[ext=m4a]/bestaudio/best', '-g', '--', link], { env: tools.env(), windowsHide: true })
    previewProc = p
    let out = ''
    p.stdout.on('data', d => { out += d })
    p.on('error', () => resolve(null))
    p.on('close', () => {
      if (previewProc === p) previewProc = null
      resolve(p.killed ? null : (out.split(/\r?\n/).find(Boolean) || null))
    })
  })
}
function stopPreviewLookup() { if (previewProc) previewProc.kill() }

module.exports = {
  init: s => { send = s }, start, cancel, remove, cancelAll, polishTags, folder,
  searchYouTube, previewURL, stopPreviewLookup, list: () => [...jobs.values()].map(publicJob).reverse(),
}
