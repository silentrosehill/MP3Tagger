// MP3 Tagger for Windows — main process: the window, file access, and everything the interface asks for.
const { app, BrowserWindow, ipcMain, dialog, shell, Menu, nativeTheme, session, webContents, clipboard } = require('electron')
const fs = require('fs')
const path = require('path')
const os = require('os')
const id3 = require('./id3')
const mp3 = require('./mp3')
const loudness = require('./loudness')
const lookup = require('./lookup')
const tools = require('./tools')
const downloader = require('./downloader')
const updater = require('./updater')
const adblock = require('./adblock')
const { settings, history } = require('./store')

const isWin = process.platform === 'win32'
const isMac = process.platform === 'darwin'
let win = null

// Its own data folder: never the Mac app's (they share the name "MP3 Tagger"). MP3TAGGER_DATA overrides it for tests.
if (process.env.MP3TAGGER_DATA) app.setPath('userData', process.env.MP3TAGGER_DATA)
else if (!isWin) app.setPath('userData', path.join(app.getPath('appData'), 'MP3 Tagger for Windows'))

if (!app.requestSingleInstanceLock()) app.quit()

/** Windows 11 22H2+ can draw Mica behind the window; older Windows gets solid colours. */
const micaSupported = isWin && Number(os.release().split('.')[2] || 0) >= 22621

const send = (channel, data) => { if (win && !win.isDestroyed()) win.webContents.send(channel, data) }
downloader.init(send)

/** MP3 paths among command-line arguments (files opened with "Open with MP3 Tagger"). */
const argFiles = argv => argv.slice(1).filter(a => !a.startsWith('-') && /\.mp3$/i.test(a) && fs.existsSync(a))

function createWindow() {
  const bounds = settings.get('windowBounds', { width: 1120, height: 780 })
  win = new BrowserWindow({
    ...bounds,
    minWidth: 900, minHeight: 600,
    show: false,
    title: 'MP3 Tagger',
    icon: path.join(__dirname, '..', '..', 'build', 'icon.png'),
    titleBarStyle: 'hidden',
    ...(isWin ? { titleBarOverlay: { color: '#00000000', symbolColor: '#ffffff', height: 52 } } : {}),
    ...(isMac ? { trafficLightPosition: { x: 18, y: 18 }, vibrancy: 'under-window', visualEffectState: 'active', transparent: true } : {}),
    ...(micaSupported ? { backgroundMaterial: 'mica', backgroundColor: '#00000000' } : { backgroundColor: isMac ? '#00000000' : '#1c1b22' }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: false,
      webviewTag: true,
      spellcheck: false,
    },
  })
  if (settings.get('windowMaximized')) win.maximize()
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'))
  win.once('ready-to-show', () => win.show())
  if (process.env.MP3TAGGER_DEBUG) win.webContents.on('console-message', e => console.log(`[renderer] ${e.message} (${e.sourceId}:${e.lineNumber})`))
  const saveBounds = () => {
    if (win.isDestroyed()) return
    settings.set('windowMaximized', win.isMaximized())
    if (!win.isMaximized() && !win.isMinimized()) settings.set('windowBounds', win.getBounds())
  }
  win.on('resize', saveBounds); win.on('move', saveBounds)
  win.on('closed', () => { win = null })
  // links that try to open new windows go to the real browser
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' } })
}

app.on('second-instance', (_e, argv) => {
  if (!win) return
  if (win.isMinimized()) win.restore()
  win.focus()
  const files = argFiles(argv)
  if (files.length) send('openFiles', files)
})

app.whenReady().then(() => {
  // a plain Chrome user agent, so YouTube and image searches treat the in-app browsers like a normal browser
  app.userAgentFallback = app.userAgentFallback.replace(/\s(Electron|mp3-tagger|MP3 ?Tagger)\/\S+/gi, '')
  if (!isMac) Menu.setApplicationMenu(null)
  adblock.setup(session.fromPartition('persist:youtube'))
  createWindow()
})
app.on('window-all-closed', () => { downloader.cancelAll(); settings.flush(); app.quit() })

// Webviews (YouTube browser, web cover search): right-click an image → Use as Cover Art; links stay inside.
app.on('web-contents-created', (_e, contents) => {
  if (contents.getType() !== 'webview') return
  contents.setWindowOpenHandler(({ url }) => { contents.loadURL(url); return { action: 'deny' } })
  contents.on('context-menu', (_ev, params) => {
    const items = []
    if (params.mediaType === 'image' && params.srcURL) {
      items.push({ label: 'Use as Cover Art', click: () => send('cover:useImage', params.srcURL) })
      items.push({ type: 'separator' })
    }
    if (params.linkURL) items.push({ label: 'Copy Link', click: () => clipboard.writeText(params.linkURL) })
    if (params.isEditable) items.push({ role: 'cut' }, { role: 'copy' }, { role: 'paste' })
    else if (params.selectionText) items.push({ role: 'copy' })
    items.push({ label: 'Back', enabled: contents.navigationHistory.canGoBack(), click: () => contents.navigationHistory.goBack() })
    items.push({ label: 'Reload', click: () => contents.reload() })
    Menu.buildFromTemplate(items).popup()
  })
})

// MARK: Files

/** Every MP3 among `paths`, with folders searched (sorted, like the Mac app). */
function expand(paths) {
  const out = []
  const walk = p => {
    let st
    try { st = fs.statSync(p) } catch { return }
    if (st.isDirectory()) {
      for (const name of fs.readdirSync(p).sort()) walk(path.join(p, name))
    } else if (/\.mp3$/i.test(p)) out.push(p)
  }
  paths.forEach(walk)
  return out
}

function loadFile(p) {
  const data = fs.readFileSync(p)
  const tag = id3.parse(data)
  const st = fs.statSync(p)
  return { path: p, tag: forUI(tag), mtime: st.mtimeMs }
}

/** Tags cross IPC as plain objects (Buffers arrive as Uint8Array). */
function forUI(tag) { return { ...tag, otherFrames: tag.otherFrames.map(f => ({ id: f.id, body: f.body })) } }
function fromUI(tag) {
  return {
    ...tag,
    cover: tag.cover ? Buffer.from(tag.cover) : null,
    otherFrames: (tag.otherFrames || []).map(f => ({ id: f.id, body: Buffer.from(f.body) })),
  }
}

const handle = (name, fn) => ipcMain.handle(name, (_e, ...args) => fn(...args))

handle('files:load', paths => {
  const files = []
  for (const p of expand(paths)) { try { files.push(loadFile(p)) } catch (e) { console.error('load failed', p, e) } }
  return files
})
handle('files:open', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'], filters: [{ name: 'MP3', extensions: ['mp3'] }] })
  return r.canceled ? [] : r.filePaths
})
handle('files:openFolder', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openDirectory'] })
  return r.canceled ? [] : r.filePaths
})
handle('files:saveDialog', async defaultPath => {
  const r = await dialog.showSaveDialog(win, { title: 'Save Song', defaultPath, filters: [{ name: 'MP3', extensions: ['mp3'] }] })
  return r.canceled ? null : r.filePath
})
handle('files:chooseFolder', async (title, defaultPath) => {
  const r = await dialog.showOpenDialog(win, { title, defaultPath, properties: ['openDirectory', 'createDirectory'] })
  return r.canceled ? null : r.filePaths[0]
})
handle('files:exists', p => fs.existsSync(p))
handle('files:readBytes', p => fs.readFileSync(p))
handle('files:info', p => {
  const l = mp3.layout(id3.audioOf(fs.readFileSync(p)))
  return { seconds: l.seconds, sampleRate: l.sampleRate }
})
handle('files:save', ({ source, dest, tag, gainDelta, trim }) => {
  try {
    const stored = id3.write(fromUI(tag), source, dest, { gainDelta, trim })
    const saved = id3.read(dest)
    history.record(dest, saved)
    return { gainSteps: stored, mtime: fs.statSync(dest).mtimeMs }
  } catch (e) {
    const perm = e.code === 'EPERM' || e.code === 'EACCES' || e.code === 'EBUSY'
    return { error: e.message, permission: perm }
  }
})
handle('files:rename', (from, name) => {
  const dir = path.dirname(from)
  let dest = path.join(dir, name), n = 2
  const base = name.replace(/\.mp3$/i, '')
  while (fs.existsSync(dest) && dest.toLowerCase() !== from.toLowerCase()) dest = path.join(dir, `${base} ${n++}.mp3`)
  if (dest.toLowerCase() === from.toLowerCase() && dest === from) return { path: from }
  try { fs.renameSync(from, dest) } catch (e) { return { error: e.message } }
  history.moved(from, dest)
  return { path: dest }
})
handle('shell:show', p => shell.showItemInFolder(p))
handle('shell:open', url => { if (/^https?:\/\//.test(url)) shell.openExternal(url) })

// MARK: Loudness

handle('loud:measure', async p => { try { return await loudness.measure(p) } catch (e) { return { error: e.message } } })
handle('loud:spectrum', async p => { try { return await loudness.spectrum(p) } catch { return null } })
handle('loud:recommend', r => loudness.recommendedSteps(r))
handle('loud:boost', async p => { try { return { tag: forUI(await loudness.limiterBoost(p)), mtime: fs.statSync(p).mtimeMs } } catch (e) { return { error: e.message } } })
handle('loud:restore', (p, tag) => { try { const t = loudness.restoreOriginal(p, fromUI(tag)); return { tag: forUI(t), mtime: fs.statSync(p).mtimeMs } } catch (e) { return { error: e.message } } })

// MARK: Lookups

handle('tags:search', async (title, artist, duration) => (await lookup.search(title, artist, duration)).map(lookup.forUI))
handle('tags:cover', async raw => lookup.coverData(raw))
handle('covers:albums', async q => { try { return { albums: await lookup.searchAlbums(q) } } catch { return { error: "Couldn't reach Apple's catalog. Check your connection." } } })
handle('net:bytes', async url => { try { return await lookup.fetchBuffer(url) } catch { return null } })

// MARK: Tools & downloads

handle('tools:status', () => tools.status())
const toolTask = fn => async () => {
  try { await fn(text => send('toolLog', text)); return { ok: true } } catch (e) { send('toolLog', '\n' + e.message + '\n'); return { error: e.message } }
}
handle('tools:install', toolTask(tools.install))
handle('tools:update', toolTask(tools.updateYtDlp))
handle('dl:start', (link, opts) => downloader.start(link, opts))
handle('dl:cancel', id => downloader.cancel(id))
handle('dl:remove', id => downloader.remove(id))
handle('dl:list', () => downloader.list())
handle('dl:folder', () => downloader.folder())
handle('find:search', q => downloader.searchYouTube(q))
handle('find:preview', link => downloader.previewURL(link))
handle('find:stopPreview', () => downloader.stopPreviewLookup())

// MARK: History, settings, app

handle('history:list', () => history.list())
handle('history:remove', id => history.remove(id))
handle('history:clear', () => history.clear())
handle('settings:all', () => settings.all())
handle('settings:set', (k, v) => {
  settings.set(k, v)
  if (k === 'uiStyle') nativeTheme.themeSource = v === 'mavericks' ? 'light' : 'system'
})
handle('app:info', () => {
  let changelog = ''
  for (const p of [path.join(process.resourcesPath || '', 'CHANGELOG.md'), path.join(__dirname, '..', '..', '..', 'CHANGELOG.md')]) {
    try { changelog = fs.readFileSync(p, 'utf8'); break } catch {}
  }
  return { version: app.getVersion(), platform: process.platform, mica: micaSupported, changelog, env: {
    tab: process.env.MP3TAGGER_TAB, play: process.env.MP3TAGGER_PLAY, theme: process.env.MP3TAGGER_THEME, noUpdate: !!process.env.MP3TAGGER_NO_UPDATE_CHECK,
    mute: !!process.env.MP3TAGGER_MUTE, search: process.env.MP3TAGGER_SEARCH,
  }, argFiles: argFiles(process.argv) }
})
handle('app:titleBar', (color, symbolColor) => { if (isWin && win) try { win.setTitleBarOverlay({ color, symbolColor, height: 52 }) } catch {} })
handle('update:check', manual => updater.check(manual))
handle('update:skip', v => updater.skip(v))

nativeTheme.themeSource = settings.get('uiStyle') === 'mavericks' ? 'light' : 'system'
