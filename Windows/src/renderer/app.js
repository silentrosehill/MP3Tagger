import { html, render, useState, useEffect, S, set, touch, api, cls, useStore } from './lib.js'
import { Icon } from './icons.js'
import { Sidebar, ContextMenu } from './components/sidebar.js'
import { Editor, TagsSheet } from './components/editor.js'
import { MiniPlayer } from './components/player.js'
import { DownloadView, AutoView, HistoryDetail, ChangelogView, refreshTools } from './components/pages.js'
import { ThemePicker, InfoPanel, AlertSheet, CoverSheet, YouTubeSheet, checkUpdates } from './components/popovers.js'
import { addPaths, selected, saveAll, save, undo, redo, refreshHistory, player, theme } from './state.js'

const isWin = api.platform === 'win32', isMac = api.platform === 'darwin'

function Detail() {
  let body
  if (S.tab === 'changelog') body = html`<${ChangelogView} />`
  else if (S.tab === 'download') body = html`<${DownloadView} />`
  else if (S.tab === 'find') body = html`<${AutoView} />`
  else if (S.tab === 'history') {
    const e = S.history.find(x => x.id === S.historySelection)
    body = e ? html`<${HistoryDetail} key=${e.id} e=${e} />` : html`<${Placeholder} text=${S.history.length ? 'Select a song' : 'Songs you save will show up here'} />`
  } else {
    const f = selected()
    body = f ? html`<${Editor} key=${f.id} f=${f} />` : html`<${Placeholder} text="Select a file" />`
  }
  return html`<div class="detail-body">${body}</div>`
}

function Placeholder({ text }) {
  useEffect(() => { theme.followNothing() }, [])
  return html`<div class="placeholder">${text}</div>`
}

function TitleBar() {
  const anchor = isWin ? 150 : 14
  const toggle = p => set({ popover: S.popover === p ? null : p })
  return html`<div class="titlebar">
    ${S.sidebarCollapsed && html`<button class="icon-btn show-sidebar" title="Show the sidebar" onClick=${() => set({ sidebarCollapsed: false })}><${Icon} name="sidebar" /></button>`}
    <img class="app-icon" src="../../build/icon.png" />
    <div class="title">MP3 Tagger ${S.info.version.replace(/\.0$/, '')}</div>
    <div class="spacer"></div>
    <div class="toolbar glass" data-keep-popover>
      <button class="icon-btn" title="What each tab does" onClick=${() => toggle('info')}><${Icon} name="info" /></button>
      <button class="icon-btn" title="Change the app's color" onClick=${() => toggle('theme')}><${Icon} name="palette" /></button>
      <button class="icon-btn" title="Add files (Ctrl+O)" onClick=${addFiles}><${Icon} name="plus" /></button>
      <button class="icon-btn" title="Save All (Ctrl+Shift+S)" onClick=${saveAll}><${Icon} name="saveAll" /></button>
    </div>
    ${S.popover === 'theme' && html`<${ThemePicker} anchor=${anchor} />`}
    ${S.popover === 'info' && html`<${InfoPanel} anchor=${anchor} />`}
  </div>`
}

async function addFiles() {
  const paths = await api.invoke('files:open')
  if (paths.length) addPaths(paths)
}

function SheetHost() {
  const s = S.sheet
  if (!s) return null
  if (s.kind === 'alert') return html`<${AlertSheet} ...${s} />`
  if (s.kind === 'tags') return html`<${TagsSheet} file=${s.file} />`
  if (s.kind === 'cover') return html`<${CoverSheet} query=${s.query} onPick=${s.onPick} />`
  if (s.kind === 'youtube') return html`<${YouTubeSheet} onDownload=${s.onDownload} />`
  return null
}

function App() {
  useStore()     // the whole window re-renders when the store changes
  const [dropping, setDropping] = useState(false)
  useEffect(() => {
    // drag MP3s or folders anywhere onto the window
    let depth = 0
    const isFiles = e => [...(e.dataTransfer?.types || [])].includes('Files')
    const enter = e => { if (isFiles(e)) { depth++; setDropping(true) } }
    const leave = e => { if (isFiles(e) && --depth <= 0) { depth = 0; setDropping(false) } }
    const over = e => { if (isFiles(e)) e.preventDefault() }
    const drop = e => {
      e.preventDefault(); depth = 0; setDropping(false)
      const paths = [...e.dataTransfer.files].map(f => api.pathFor(f)).filter(Boolean)
      if (paths.length) addPaths(paths)
    }
    addEventListener('dragenter', enter); addEventListener('dragleave', leave); addEventListener('dragover', over); addEventListener('drop', drop)
    return () => { removeEventListener('dragenter', enter); removeEventListener('dragleave', leave); removeEventListener('dragover', over); removeEventListener('drop', drop) }
  }, [])

  return html`<div id="app" class=${cls(isWin && 'win', isMac && 'mac')}>
    <${Sidebar} />
    <main class="detail">
      <${TitleBar} />
      <${Detail} />
      ${S.status && html`<div class="statusbar">${S.status}</div>`}
    </main>
    <${MiniPlayer} />
    <${SheetHost} />
    <${ContextMenu} />
    ${dropping && html`<div class="dropzone"><div class="glass">Drop MP3s or folders to add them</div></div>`}
  </div>`
}

// Keyboard: Space = play/pause, ← → = previous/next (never while typing), Ctrl+S/O/Z…
addEventListener('keydown', e => {
  const typing = e.target.closest('input, textarea, select, webview, [contenteditable]')
  const mod = e.ctrlKey || e.metaKey
  const f = selected()
  if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); if (e.shiftKey) saveAll(); else if (f && S.tab === 'files') save(f); return }
  if (mod && e.key.toLowerCase() === 'o') { e.preventDefault(); addFiles(); return }
  if (mod && !typing && f && S.tab === 'files') {
    if (e.key.toLowerCase() === 'z' && !e.shiftKey) { e.preventDefault(); undo(f); return }
    if (e.key.toLowerCase() === 'y' || (e.key.toLowerCase() === 'z' && e.shiftKey)) { e.preventDefault(); redo(f); return }
  }
  if (typing || mod || e.altKey || S.sheet) return
  if (e.code === 'Space') {
    if (player.path) player.playPause()
    else if (S.tab === 'files' && f) player.toggle(f.path, 'files')
    else return
    e.preventDefault()
  } else if (e.key === 'ArrowRight' && player.path) { e.preventDefault(); player.next() }
  else if (e.key === 'ArrowLeft' && player.path) { e.preventDefault(); player.previous() }
  else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && (S.tab === 'files' || S.tab === 'history')) {
    // move the selection through the list
    e.preventDefault()
    const d = e.key === 'ArrowDown' ? 1 : -1
    if (S.tab === 'files') {
      const i = S.files.findIndex(x => x.id === S.selection), n = S.files[Math.min(Math.max(i + d, 0), S.files.length - 1)]
      if (n) set({ selection: n.id })
    } else {
      const i = S.history.findIndex(x => x.id === S.historySelection), n = S.history[Math.min(Math.max(i + d, 0), S.history.length - 1)]
      if (n) set({ historySelection: n.id })
    }
  }
})
// Ctrl+Z inside a text field: the editor's own undo, so it matches what the fields show
addEventListener('keydown', e => {
  if (!(e.ctrlKey || e.metaKey) || !e.target.matches?.('.form-grid input')) return
  const f = selected()
  if (!f) return
  if (e.key.toLowerCase() === 'z' && !e.shiftKey) { e.preventDefault(); undo(f) }
  else if (e.key.toLowerCase() === 'y' || (e.key.toLowerCase() === 'z' && e.shiftKey)) { e.preventDefault(); redo(f) }
}, true)
api.on('openFiles', paths => addPaths(paths).then(() => set({ tab: 'files' })))
addEventListener('beforeunload', () => { /* unsaved edits are kept only for this session, like the Mac app */ })

// ───────────── Start ─────────────

;(async () => {
  const [settings, info] = await Promise.all([api.invoke('settings:all'), api.invoke('app:info')])
  S.settings = settings
  S.info = info
  if (info.mica || isMac) document.documentElement.classList.add('material')
  player.volume = settings.volume ?? 0.8
  if (info.env.mute) player.mute = true
  const tabs = { history: 'history', download: 'download', find: 'find', auto: 'find', changelog: 'changelog' }
  if (tabs[info.env.tab]) S.tab = tabs[info.env.tab]
  theme.apply()
  render(html`<${App} />`, document.body)

  // songs downloaded in the app stay in Files across launches
  const downloaded = (settings.downloadedFiles || [])
  const existing = []
  for (const p of downloaded) if (await api.invoke('files:exists', p)) existing.push(p)
  S.downloadedPaths = new Set(existing)
  if (existing.length !== downloaded.length) api.invoke('settings:set', 'downloadedFiles', existing)
  if (existing.length) await addPaths(existing, { quiet: true })
  if (info.argFiles.length) await addPaths(info.argFiles)
  refreshHistory()
  refreshTools()
  const jobs = await api.invoke('dl:list')
  if (jobs.length) { (await import('./components/pages.js')).downloads.jobs = jobs; touch() }
  if (info.env.play) { await addPaths([info.env.play], { quiet: true }); player.toggle(info.env.play, 'files') }
  if (info.env.theme) setTimeout(() => set({ popover: 'theme' }), parseFloat(info.env.theme) * 1000)
  if (!info.env.noUpdate) checkUpdates(false)
})().catch(e => console.error('startup failed', e && e.stack || e))
