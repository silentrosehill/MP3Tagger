import { html, S, set, api, cls, relTime, baseName, useState } from '../lib.js'
import { Icon } from '../icons.js'
import { Segmented, Marquee, PlayThumb } from './common.js'
import { isDownloaded, removeFromList, renameFromTags, renameAllFromTags, tagFileName, nameMatches, openInEditor, refreshHistory } from '../state.js'
import { downloads, cancelJob, removeJob } from './pages.js'

const TABS = [
  { value: 'files', label: 'Files' }, { value: 'history', label: 'History' }, { value: 'find', label: 'Auto' },
  { value: 'download', label: 'Download', icon: 'download' }, { value: 'changelog', label: 'Changelog', icon: 'notes' },
]

/** Right-click menu built from [{label, action, disabled}] | 'sep'. */
export function contextMenu(e, items) {
  e.preventDefault()
  set({ menu: { x: e.clientX, y: e.clientY, items } })
}

export function ContextMenu() {
  const m = S.menu
  if (!m) return null
  const close = () => set({ menu: null })
  return html`<div style="position:fixed;inset:0;z-index:100" onMouseDown=${close} onContextMenu=${e => { e.preventDefault(); close() }}>
    <div class="popover" style=${`left:${Math.min(m.x, innerWidth - 230)}px;top:${Math.min(m.y, innerHeight - m.items.length * 32 - 20)}px;padding:5px;min-width:200px;transform-origin:top left;animation-duration:.18s`}
      onMouseDown=${e => e.stopPropagation()}>
      ${m.items.map(it => it === 'sep' ? html`<hr style="margin:4px 6px" />` : html`
        <button class="menu-item" disabled=${it.disabled} onClick=${() => { close(); it.action() }}>${it.label}</button>`)}
    </div>
  </div>`
}

function FileRow({ f }) {
  const [hover, setHover] = useState(false)
  const sel = S.selection === f.id
  const name = tagFileName(f.tag)
  return html`<div class=${cls('list-row', sel && 'selected')} onClick=${() => set({ selection: f.id })}
    onMouseEnter=${() => setHover(true)} onMouseLeave=${() => setHover(false)}
    onContextMenu=${e => contextMenu(e, [
      { label: 'Show in Folder', action: () => api.invoke('shell:show', f.path) },
      { label: 'Rename from Tags', action: () => renameFromTags(f), disabled: !name || nameMatches(f.path, name) },
      { label: 'Rename All from Tags', action: renameAllFromTags },
      'sep',
      { label: 'Remove from List', action: () => removeFromList(f) },
    ])}>
    <${PlayThumb} path=${f.path} cover=${f.tag.cover} mime=${f.tag.coverMime} source="files" />
    <div class="meta">
      <${Marquee} className="t1" text=${f.tag.title || baseName(f.path)} active=${hover || sel} />
      <div class="t2">${f.tag.artist || 'Unknown artist'}</div>
    </div>
    ${isDownloaded(f.path) && html`<span class="badge" title="Downloaded in MP3 Tagger"><${Icon} name="download" /></span>`}
    ${f.dirty && html`<span class="dot" title="Unsaved changes"></span>`}
  </div>`
}

function HistoryRow({ e }) {
  const [hover, setHover] = useState(false)
  const sel = S.historySelection === e.id
  return html`<div class=${cls('list-row', sel && 'selected', !e.exists && 'missing')} onClick=${() => set({ historySelection: e.id })}
    onMouseEnter=${() => setHover(true)} onMouseLeave=${() => setHover(false)}
    onContextMenu=${ev => contextMenu(ev, [
      { label: 'Open in Editor', action: () => openInEditor(e.path), disabled: !e.exists },
      { label: 'Show in Folder', action: () => api.invoke('shell:show', e.path), disabled: !e.exists },
      'sep',
      { label: 'Remove from History', action: async () => { await api.invoke('history:remove', e.id); refreshHistory() } },
    ])}>
    <${PlayThumb} path=${e.path} cover=${e.thumb ? 'data:image/jpeg;base64,' + e.thumb : null} source="history" disabled=${!e.exists} />
    <div class="meta">
      <${Marquee} className="t1" text=${e.title || baseName(e.path)} active=${hover || sel} />
      <div class="t2">${relTime(e.lastSaved)}${e.artist ? ' · ' + e.artist : ''}</div>
    </div>
    ${!e.exists && html`<span title="File was moved or deleted" class="warn"><${Icon} name="alert" size=${15} /></span>`}
  </div>`
}

function DownloadRow({ j }) {
  const active = ['starting', 'downloading', 'converting', 'tagging'].includes(j.phase)
  return html`<div class="list-row" onContextMenu=${e => contextMenu(e, [
      ...(active ? [{ label: 'Cancel', action: () => cancelJob(j) }] : []),
      ...(j.phase === 'done' && j.file ? [{ label: 'Open in Editor', action: () => openInEditor(j.file) }, { label: 'Show in Folder', action: () => api.invoke('shell:show', j.file) }] : []),
      'sep', { label: 'Remove from List', action: () => removeJob(j) }])}
    onDblClick=${() => j.phase === 'done' && j.file && openInEditor(j.file)}>
    <div class="thumb" style="width:32px;height:32px;border-radius:4px">${j.thumbnail ? html`<img src=${j.thumbnail} />` : html`<${Icon} name="download" />`}</div>
    <div class="meta">
      <${Marquee} className="t1" text=${j.title} />
      ${active && html`<div class=${cls('progress', j.phase !== 'downloading' && 'indeterminate')} style="margin:3px 0"><div style=${`width:${j.progress * 100}%`}></div></div>`}
      <div class=${cls('t2', j.phase === 'failed' && 'warn')}>${jobStatus(j)}</div>
    </div>
  </div>`
}

export function jobStatus(j) {
  switch (j.phase) {
    case 'starting': return 'Starting…'
    case 'downloading': return `Downloading ${Math.round(j.progress * 100)}%`
    case 'converting': return 'Converting to MP3…'
    case 'tagging': return 'Adding cover & tags…'
    case 'done': return 'Done'
    case 'cancelled': return 'Cancelled'
    default: return j.error || 'Failed'
  }
}

function Empty({ icon, text }) {
  return html`<div class="list-empty"><div><${Icon} name=${icon} /><div>${text}</div></div></div>`
}

export function Sidebar() {
  const tab = S.tab
  let list
  if (tab === 'files') list = S.files.length ? S.files.map(f => html`<${FileRow} key=${f.id} f=${f} />`) : html`<${Empty} icon="musicList" text="Drop MP3 files or folders here" />`
  else if (tab === 'history') list = S.history.length ? S.history.map(e => html`<${HistoryRow} key=${e.id} e=${e} />`) : html`<${Empty} icon="history" text="No saved songs yet" />`
  else if (tab === 'changelog') list = html`<${ChangelogList} />`
  else list = downloads.jobs.length ? downloads.jobs.map(j => html`<${DownloadRow} key=${j.id} j=${j} />`) : html`<${Empty} icon="download" text="No downloads yet" />`
  return html`<aside class=${cls('sidebar', S.sidebarCollapsed && 'collapsed')}>
    <div class="sidebar-top">
      <button class="icon-btn" title="Hide the sidebar" onClick=${() => set({ sidebarCollapsed: true })}><${Icon} name="sidebar" /></button>
    </div>
    <${Segmented} className="tabs" value=${tab} options=${TABS} onChange=${v => set({ tab: v })} />
    <div class="list" style="position:relative">${list}</div>
    ${tab === 'history' && S.history.length > 0 && html`<div class="sidebar-foot">
      <button class="btn glass" onClick=${() => set({ sheet: { kind: 'alert', title: 'Clear all history?', message: 'The songs themselves are not deleted.',
        buttons: [{ label: 'Clear History', prominent: true, action: async () => { await api.invoke('history:clear'); set({ historySelection: null }); refreshHistory() } }] } })}>Clear History…</button>
    </div>`}
  </aside>`
}

function ChangelogList() {
  const versions = parseChangelog(S.info.changelog)
  return versions.map(v => html`<div class=${cls('list-row', S.changelogSelection === v.version && 'selected')} key=${v.version}
    onClick=${() => { set({ changelogSelection: v.version }); document.getElementById('v-' + v.version)?.scrollIntoView({ behavior: 'smooth' }) }}>
    <div class="meta"><div class="t1" style="font-weight:600">${v.version}</div><div class="t2">${v.items[0] || ''}</div></div>
  </div>`)
}

export function parseChangelog(text) {
  const out = []
  for (const line of (text || '').split(/\r?\n/)) {
    const m = /^##\s+(\S+)(.*)$/.exec(line)
    if (m) { out.push({ version: m[1], build: m[2].trim(), items: [] }); continue }
    const b = /^-\s+(.*)$/.exec(line)
    if (b && out.length) out[out.length - 1].items.push(b[1])
  }
  return out
}
