// The app's model: files being edited, saving, undo, the player and its queue, and the theme.
import { S, set, touch, api, setting, saveSetting, status, palette, PURPLE, AQUA, themeFromCover, coverURL, baseName, dirName } from './lib.js'

let nextId = 1

// ───────────── Files ─────────────

function makeFile(f) {
  return { id: nextId++, path: f.path, tag: f.tag, savedGain: f.tag.gainSteps, trimStart: 0, trimEnd: null,
    dirty: false, undo: [], redo: [], last: null, mtime: f.mtime }
}

export async function addPaths(paths, { quiet = false, select = true } = {}) {
  const loaded = await api.invoke('files:load', paths)
  const known = new Set(S.files.map(f => f.path.toLowerCase()))
  let added = 0
  for (const f of loaded) {
    if (known.has(f.path.toLowerCase())) continue
    S.files.push(makeFile(f)); known.add(f.path.toLowerCase()); added++
  }
  if (select && S.selection == null && S.files.length) S.selection = S.files[0].id
  if (!quiet) S.status = added ? `Added ${added} file${added === 1 ? '' : 's'}` : 'No new MP3 files found'
  touch()
  return added
}

export const selected = () => S.files.find(f => f.id === S.selection)
export const isDownloaded = p => S.downloadedPaths.has(p)
function persistDownloads() { saveSetting('downloadedFiles', [...S.downloadedPaths]) }

/** Loads the file (if needed), selects it and switches to Files. */
export async function openInEditor(path) {
  if (!S.files.some(f => f.path === path)) await addPaths([path], { quiet: true, select: false })
  const f = S.files.find(x => x.path === path)
  if (f) set({ selection: f.id, tab: 'files' })
}

export async function addDownloaded(path) {
  S.downloadedPaths.add(path); persistDownloads()
  await addPaths([path], { quiet: true })
  const f = S.files.find(x => x.path === path)
  if (f) { S.files = [f, ...S.files.filter(x => x !== f)]; touch() }
}

export function removeFromList(f) {
  S.files = S.files.filter(x => x !== f)
  if (S.downloadedPaths.delete(f.path)) persistDownloads()
  if (S.selection === f.id) S.selection = S.files[0]?.id ?? null
  touch()
}

// ───────────── Editing & undo (typing in one field within 2 s = one step) ─────────────

const snapshot = f => ({ tag: { ...f.tag }, trimStart: f.trimStart, trimEnd: f.trimEnd, dirty: f.dirty })
function restore(f, s) { f.tag = s.tag; f.trimStart = s.trimStart; f.trimEnd = s.trimEnd; f.dirty = s.dirty }

export function edit(f, what, mutate) {
  const now = Date.now()
  if (!(f.last && f.last.what === what && now - f.last.time < 2000 && what.startsWith('text:'))) {
    f.undo.push(snapshot(f)); if (f.undo.length > 200) f.undo.shift()
  }
  f.redo = []
  f.last = { what, time: now }
  mutate(f)
  f.dirty = true
  touch()
}
export function undo(f) { if (!f.undo.length) return; f.redo.push(snapshot(f)); restore(f, f.undo.pop()); f.last = null; touch() }
export function redo(f) { if (!f.redo.length) return; f.undo.push(snapshot(f)); restore(f, f.redo.pop()); f.last = null; touch() }

// ───────────── Saving ─────────────

/** "Artist - Title.mp3" from the tags, or null without a title. Windows-safe. */
export function tagFileName(tag) {
  const title = (tag.title || '').trim()
  if (!title) return null
  const artist = (tag.artist || '').trim()
  let name = artist ? `${artist} - ${title}` : title
  name = name.replace(/[<>:"/\\|?*\x00-\x1f]/g, '-').replace(/^[. ]+|[. ]+$/g, '')
  return name.slice(0, 180) + '.mp3'
}
export function nameMatches(path, name) {
  const file = path.split(/[\\/]/).pop(), base = name.slice(0, -4)
  if (file.toLowerCase() === name.toLowerCase()) return true
  return new RegExp('^' + base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ' \\d+\\.mp3$', 'i').test(file)
}

export async function renameFromTags(f, quiet = false) {
  const name = tagFileName(f.tag)
  if (!name) { if (!quiet) status('Add a title first'); return false }
  if (nameMatches(f.path, name)) return false
  let renamed
  const r = await player.release([f.path], async () => (renamed = await api.invoke('files:rename', f.path, name)), () => renamed?.path)
  if (r.error) { if (!quiet) status("Couldn't rename: " + r.error); return false }
  if (r.path === f.path) return false
  const old = f.path
  f.path = r.path
  if (S.downloadedPaths.delete(old)) { S.downloadedPaths.add(r.path); persistDownloads() }
  refreshHistory()
  if (!quiet) status('Renamed to ' + r.path.split(/[\\/]/).pop())
  touch()
  return true
}
export async function renameAllFromTags() {
  let n = 0
  for (const f of [...S.files]) if (await renameFromTags(f, true)) n++
  status(n ? `Renamed ${n} file${n === 1 ? '' : 's'} from their tags` : 'All file names already match their tags')
}

export async function save(f) {
  const dest = await api.invoke('files:saveDialog', f.path)
  if (!dest) return
  if (await write(f, dest)) status(dest === f.path ? 'Saved ' + baseName(dest) : 'Saved to ' + dest)
}

async function write(f, dest) {
  const trim = f.trimStart > 0 || f.trimEnd != null ? { start: f.trimStart, end: f.trimEnd } : null
  let saved
  const r = await player.release([f.path, dest], async () => (saved = await api.invoke('files:save', { source: f.path, dest, tag: f.tag, gainDelta: f.tag.gainSteps - f.savedGain, trim })),
    () => (saved && !saved.error && !trim ? dest : null))
  if (r.error) {
    status(`Failed to save ${baseName(dest)}: ${r.error}`)
    if (r.permission) {
      set({ sheet: { kind: 'alert', title: `Windows blocked MP3 Tagger from saving in “${dirName(dest).split(/[\\/]/).pop()}”`,
        message: 'The file may be read-only, open in another app, or in a folder protected by Windows Security (Controlled folder access). Close other apps using it, untick Read-only in the file\'s Properties, or save a copy to another folder like Music.',
        buttons: [{ label: 'Show File', action: () => api.invoke('shell:show', dest) }] } })
    }
    return false
  }
  if (trim && player.path && (player.path === f.path || player.path === dest)) player.stop()   // it was playing the old audio
  f.trimStart = 0; f.trimEnd = null
  f.savedGain = r.gainSteps; f.tag = { ...f.tag, gainSteps: r.gainSteps }
  f.undo = []; f.redo = []; f.last = null
  S.files = S.files.filter(x => x === f || x.path.toLowerCase() !== dest.toLowerCase())
  if (f.path !== dest && S.downloadedPaths.has(f.path)) {
    if (!(await api.invoke('files:exists', f.path))) S.downloadedPaths.delete(f.path)
    S.downloadedPaths.add(dest); persistDownloads()
  }
  f.path = dest; f.dirty = false; f.mtime = r.mtime
  refreshHistory()
  touch()
  return true
}

export async function saveAll() {
  const dirty = S.files.filter(f => f.dirty)
  if (!dirty.length) return status('Nothing to save')
  if (dirty.length === 1) return save(dirty[0])
  const folder = await api.invoke('files:chooseFolder', `Choose a folder for the ${dirty.length} changed songs (pick their current folder to update them in place)`, dirName(dirty[0].path))
  if (!folder) return
  const sep = folder.includes('\\') ? '\\' : '/'
  const plan = dirty.map(f => [f, folder + sep + f.path.split(/[\\/]/).pop()])
  const clashes = []
  for (const [f, dest] of plan) if (dest.toLowerCase() !== f.path.toLowerCase() && await api.invoke('files:exists', dest)) clashes.push(dest)
  const go = async () => {
    let n = 0
    for (const [f, dest] of plan) if (await write(f, dest)) n++
    if (n === plan.length) status(`Saved ${n} songs to ${folder}`)
  }
  if (clashes.length) {
    set({ sheet: { kind: 'alert', title: clashes.length === 1 ? `“${baseName(clashes[0])}.mp3” already exists in that folder.` : `${clashes.length} of these songs already exist in that folder.`,
      message: 'Replacing them overwrites the existing files.', buttons: [{ label: 'Replace', prominent: true, action: go }] } })
  } else go()
}

/** Copies album, album artist, year, genre and cover from `src` to every other file. */
export function applyAlbumToAll(src) {
  for (const f of S.files) {
    if (f === src) continue
    edit(f, 'album-all', x => { x.tag = { ...x.tag, album: src.tag.album, albumArtist: src.tag.albumArtist, year: src.tag.year, genre: src.tag.genre, cover: src.tag.cover, coverMime: src.tag.coverMime } })
  }
  status(`Copied album info & cover to ${S.files.length - 1} file(s) — click Save All`)
}

// ───────────── History ─────────────

export async function refreshHistory() { set({ history: await api.invoke('history:list') }) }

// ───────────── Player ─────────────

const audio = new Audio()
audio.preload = 'auto'
export const player = {
  audio, path: null, playing: false, title: '', artist: '', cover: null, source: 'files', spectrum: null,
  get current() { return audio.currentTime || 0 },
  get duration() { return isFinite(audio.duration) ? audio.duration : 0 },
  volume: 0.8, lastVolume: 0.8,
  mute: false,

  isPlaying(p) { return this.playing && this.path === p },

  /**
   * Windows won't replace or rename a file that's open, and the player keeps the current song open. Lets go of
   * `path` while `work` runs, then picks the song up again (at `newPath` if it moved) where it was.
   */
  async release(paths, work, newPath) {
    if (!this.path || !paths.includes(this.path)) return work()
    const at = this.current, wasPlaying = this.playing
    audio.pause(); audio.removeAttribute('src'); audio.load()
    try { return await work() } finally {
      const p = newPath?.() || this.path
      this.path = p
      audio.src = api.fileURL(p)
      audio.volume = this.mute ? 0 : this.volume
      await new Promise(r => { audio.addEventListener('loadedmetadata', r, { once: true }); audio.addEventListener('error', r, { once: true }) })
      audio.currentTime = at
      if (wasPlaying) audio.play().catch(() => {})
    }
  },

  async toggle(path, source) {
    if (source) this.source = source
    if (this.path === path) return this.playPause()
    // song info from the list it came from, or from the file itself
    let info = S.files.find(f => f.path === path)?.tag
    if (!info) {
      const loaded = await api.invoke('files:load', [path])
      if (!loaded.length) return status("Couldn't play this file")
      info = loaded[0].tag
    }
    this.path = path
    this.title = info.title || baseName(path)
    this.artist = info.artist
    this.cover = info.cover ? { bytes: info.cover, mime: info.coverMime } : null
    this.spectrum = null
    audio.src = api.fileURL(path)
    audio.volume = this.mute ? 0 : this.volume
    try { await audio.play() } catch (e) { status("Couldn't play this file"); return this.stop() }
    this.loadSpectrum(path)
    this.updateSession()
    theme.playbackChanged()
    touch()
  },
  playPause() {
    if (!this.path) return
    if (audio.paused) audio.play().catch(() => {}); else audio.pause()
  },
  stop() {
    audio.pause(); audio.removeAttribute('src'); audio.load()
    this.path = null; this.playing = false; this.spectrum = null
    navigator.mediaSession.metadata = null
    theme.playbackChanged()
    touch()
  },
  seek(t) { if (this.path) audio.currentTime = Math.min(Math.max(t, 0), Math.max(this.duration - 0.05, 0)) },
  setVolume(v) {
    this.volume = v; if (v > 0) this.lastVolume = v
    if (!this.mute) audio.volume = v
    saveSetting('volume', v)
    touch()
  },
  toggleMute() { this.setVolume(this.volume === 0 ? (this.lastVolume || 0.8) : 0) },

  queue() {
    if (this.source === 'history') return S.history.filter(e => e.exists).map(e => e.path)
    return S.files.map(f => f.path)
  },
  get hasNext() { const q = this.queue(), i = q.indexOf(this.path); return i >= 0 && i < q.length - 1 },
  next() {
    const q = this.queue(), i = q.indexOf(this.path)
    if (i >= 0 && i < q.length - 1) this.toggle(q[i + 1])
  },
  /** Restarts the song if it's past 3 s, else goes to the previous one. */
  previous() {
    if (this.current > 3) return this.seek(0)
    const q = this.queue(), i = q.indexOf(this.path)
    if (i > 0) this.toggle(q[i - 1]); else this.seek(0)
  },
  async loadSpectrum(path) {
    const s = await api.invoke('loud:spectrum', path)
    if (this.path === path && s) { this.spectrum = s; touch() }
  },
  /** Windows' media overlay and the keyboard's media keys. */
  updateSession() {
    const art = this.cover ? [{ src: coverURL(this.cover.bytes, this.cover.mime), sizes: '512x512', type: this.cover.mime }] : []
    navigator.mediaSession.metadata = new MediaMetadata({ title: this.title, artist: this.artist || '', artwork: art })
  },
}
audio.addEventListener('play', () => { player.playing = true; navigator.mediaSession.playbackState = 'playing'; touch() })
audio.addEventListener('pause', () => { player.playing = false; navigator.mediaSession.playbackState = 'paused'; touch() })
audio.addEventListener('ended', () => {
  player.playing = false
  if (player.hasNext) player.next(); else { audio.currentTime = 0; touch() }
})
navigator.mediaSession.setActionHandler('play', () => player.playPause())
navigator.mediaSession.setActionHandler('pause', () => player.playPause())
navigator.mediaSession.setActionHandler('nexttrack', () => player.next())
navigator.mediaSession.setActionHandler('previoustrack', () => player.previous())

// ───────────── Theme ─────────────

export const theme = {
  get base() {
    const h = setting('themeHue')
    return h === undefined ? { ...PURPLE } : { hue: h, saturation: setting('themeSat'), brightness: setting('themeBri') }
  },
  get tint() { return setting('themeTint', 1) },
  get style() { return setting('uiStyle', 'glass') },
  get glassTint() { return setting('glassTint', 0.3) },
  get disc() { return setting('discKind', 'vinyl') },
  get matchCover() { return !!setting('themeMatchCover', false) },
  /** What the app renders with: Mavericks uses Aqua blue; otherwise the chosen colour or the cover's. */
  get rendered() {
    if (this.style === 'mavericks') return AQUA
    return this.matchCover && S.coverTheme ? S.coverTheme : this.base
  },
  setBase(t) {
    saveSetting('themeMatchCover', false)
    saveSetting('themeHue', t.hue); saveSetting('themeSat', t.saturation); saveSetting('themeBri', t.brightness)
    this.apply()
  },
  set(key, v) { saveSetting(key, v); this.apply() },

  showingNoSong: false,
  coverKey: null,
  /** The cover of the song on screen changed (null = no cover). */
  follow(cover) { this.showingNoSong = false; this.useCover(cover) },
  /** No song on screen: the playing song's cover sets the colours. */
  followNothing() { this.showingNoSong = true; this.useCover(player.path ? player.cover?.bytes : null) },
  playbackChanged() { if (this.showingNoSong) this.useCover(player.path ? player.cover?.bytes : null) },
  cache: new WeakMap(),
  async useCover(bytes) {
    if (!bytes) { this.coverKey = null; if (S.coverTheme) { S.coverTheme = null; this.apply() }; return }
    if (bytes === this.coverKey) return
    this.coverKey = bytes
    let t = this.cache.get(bytes)
    if (!t) { t = await themeFromCover(coverURL(bytes)); if (t) this.cache.set(bytes, t) }
    if (this.coverKey !== bytes) return
    S.coverTheme = t
    this.apply()
  },

  apply() {
    const root = document.documentElement
    const p = palette(this.rendered)
    root.style.setProperty('--purple', p.purple)
    root.style.setProperty('--indigo', p.indigo)
    root.style.setProperty('--pink', p.pink)
    root.style.setProperty('--accent', p.accent)
    root.style.setProperty('--gt', this.glassTint)
    root.style.setProperty('--tint-k', this.tint)
    root.classList.toggle('mav', this.style === 'mavericks')
    const dark = this.style !== 'mavericks' && matchMedia('(prefers-color-scheme: dark)').matches
    api.invoke('app:titleBar', '#00000000', dark ? '#ffffff' : '#222222')
    touch()
  },
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => theme.apply())
