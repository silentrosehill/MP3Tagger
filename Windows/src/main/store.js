// Settings and History, saved as JSON in the app's data folder (%APPDATA%\MP3 Tagger).
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { app, nativeImage } = require('electron')

const dataDir = () => app.getPath('userData')

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return fallback }
}
function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = file + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(value))
  fs.renameSync(tmp, file)
}

const settings = {
  file: () => path.join(dataDir(), 'settings.json'),
  cache: null,
  all() { return this.cache || (this.cache = readJSON(this.file(), {})) },
  get(key, fallback) { const v = this.all()[key]; return v === undefined ? fallback : v },
  set(key, value) {
    this.all()[key] = value
    clearTimeout(this.timer)
    this.timer = setTimeout(() => writeJSON(this.file(), this.cache), 150)
  },
  flush() { if (this.cache) { clearTimeout(this.timer); writeJSON(this.file(), this.cache) } },
}

/** Songs you've saved (not just opened), newest first. */
const history = {
  file: () => process.env.MP3TAGGER_HISTORY || path.join(dataDir(), 'history.json'),
  entries: null,
  list() {
    if (!this.entries) this.entries = readJSON(this.file(), [])
    return this.entries.map(e => ({ ...e, exists: fs.existsSync(e.path) }))
  },
  record(file, tag) {
    this.list()
    let e = this.entries.find(x => x.path === file)
      || { id: crypto.randomUUID(), path: file, saveCount: 0 }
    e.title = tag.title; e.artist = tag.artist; e.album = tag.album
    e.lastSaved = Date.now(); e.saveCount++
    e.thumb = null
    if (tag.cover) {
      const img = nativeImage.createFromBuffer(Buffer.from(tag.cover))
      if (!img.isEmpty()) e.thumb = img.resize({ width: 96, height: 96, quality: 'best' }).toJPEG(85).toString('base64')
    }
    this.entries = [e, ...this.entries.filter(x => x.path !== file)]
    this.save()
  },
  moved(from, to) { this.list(); const e = this.entries.find(x => x.path === from); if (e) { e.path = to; this.save() } },
  remove(id) { this.list(); this.entries = this.entries.filter(x => x.id !== id); this.save() },
  clear() { this.entries = []; this.save() },
  save() { writeJSON(this.file(), this.entries) },
}

module.exports = { settings, history, dataDir }
