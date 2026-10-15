import { html, useState, useEffect, useRef, S, set, touch, api, cls, coverURL, fmtTime, relTime, baseName, setting, saveSetting } from '../lib.js'
import { Icon } from '../icons.js'
import { Switch, Spinner, PlayThumb } from './common.js'
import { player, openInEditor, theme, addDownloaded } from '../state.js'
import { parseChangelog, jobStatus } from './sidebar.js'

// ───────────── Downloads (jobs run in the main process) ─────────────

export const downloads = { jobs: [], log: '', toolBusy: false, message: null, findJob: null }
api.on('job', j => {
  const i = downloads.jobs.findIndex(x => x.id === j.id)
  if (i >= 0) downloads.jobs[i] = j; else downloads.jobs.unshift(j)
  if (downloads.findJob?.id === j.id) downloads.findJob = j
  touch()
})
api.on('downloadFinished', async j => {
  await addDownloaded(j.file)
  set({ status: `Downloaded ${baseName(j.file)} — added to Files` })
  if (j.openWhenDone && S.tab === 'find') openInEditor(j.file)
})
api.on('toolLog', text => { downloads.log = (downloads.log + text).slice(-6000); touch() })

export async function refreshTools() { S.tools = await api.invoke('tools:status'); touch() }
export const cancelJob = j => api.invoke('dl:cancel', j.id)
export function removeJob(j) { api.invoke('dl:remove', j.id); downloads.jobs = downloads.jobs.filter(x => x.id !== j.id); touch() }
const isActive = j => ['starting', 'downloading', 'converting', 'tagging'].includes(j.phase)

async function startDownload(link, opts) {
  const r = await api.invoke('dl:start', link, opts)
  if (r.error) { downloads.message = r.error; touch(); return null }
  downloads.message = null
  touch()
  return r.job
}

async function toolTask(kind, done) {
  downloads.toolBusy = true; downloads.message = null; downloads.log = ''; touch()
  const r = await api.invoke(kind)
  downloads.toolBusy = false
  downloads.message = r.error ? 'Something went wrong (see the log above).' : done
  await refreshTools()
}

function SetupCard() {
  const t = S.tools || {}
  const line = (name, p) => html`<div class="label-line" style="font-size:13px">
    <span style=${`color:${p ? 'var(--green)' : 'var(--orange)'}`}><${Icon} name=${p ? 'check' : 'x'} /></span> ${p ? `${name} — ${p}` : `${name} — not installed`}</div>`
  return html`<div class="card">
    <h3><${Icon} name="wrench" /> One-time setup</h3>
    <div class="muted">Downloading uses two free, open-source tools: yt-dlp (fetches the audio) and ffmpeg (converts it to MP3). MP3 Tagger can download them for you (about 200 MB).</div>
    ${line('yt-dlp', t.ytdlp)}${line('ffmpeg', t.ffmpeg)}
    <div class="row">
      ${t.platform !== 'win32' && !t.brew ? html`<span class="small">Install Homebrew from brew.sh first, then run: brew install yt-dlp ffmpeg</span>`
        : html`<button class="btn prominent" disabled=${downloads.toolBusy} onClick=${() => toolTask('tools:install', "Tools installed. You're ready to download.")}>
          ${downloads.toolBusy ? html`<${Spinner} /> Installing… (this can take a few minutes)` : html`<${Icon} name="download" /> Install yt-dlp and ffmpeg`}</button>`}
      <button class="btn glass" onClick=${refreshTools}>Check Again</button>
    </div>
  </div>`
}

function JobCard({ j }) {
  return html`<div class="job">
    <img src=${j.thumbnail || ''} />
    <div class="col grow" style="gap:8px">
      <div style="font-weight:600;font-size:15px">${j.title}</div>
      ${isActive(j) && html`<div class=${cls('progress', j.phase !== 'downloading' && 'indeterminate')}><div style=${`width:${j.progress * 100}%`}></div></div>`}
      <div class=${cls('muted', j.phase === 'failed' && 'warn')} style="font-size:13px">${jobStatus(j)}</div>
      <div class="row">
        ${isActive(j) && html`<button class="btn glass" onClick=${() => cancelJob(j)}>Cancel</button>`}
        ${j.phase === 'done' && j.file && html`<button class="btn prominent" onClick=${() => openInEditor(j.file)}>Open in Editor</button>
          <button class="btn glass" onClick=${() => api.invoke('shell:show', j.file)}>Show in Folder</button>`}
      </div>
    </div>
  </div>`
}

const QUALITIES = [['best', 'Best (VBR)'], ['k320', '320 kbps'], ['k192', '192 kbps'], ['k128', '128 kbps']]

export function DownloadView() {
  const [link, setLink] = useState('')
  const [folder, setFolder] = useState('')
  useEffect(() => { refreshTools(); theme.followNothing(); api.invoke('dl:folder').then(setFolder) }, [])
  const ready = S.tools?.ytdlp && S.tools?.ffmpeg
  const go = async l => { if (await startDownload(l ?? link)) setLink('') }
  const latest = downloads.jobs[0]
  return html`<div class="page">
    <div><h2>Download Audio</h2><div class="muted" style="margin-top:4px">Paste a video link to save its audio as a tagged MP3, ready for Spotify.</div></div>
    ${ready ? html`
      <div class="card">
        <div class="row">
          <div class="searchbox"><${Icon} name="youtube" style="color:var(--pink)" />
            <input placeholder="https://www.youtube.com/watch?v=…  (or browse YouTube →)" value=${link} onInput=${e => setLink(e.target.value)} onKeyDown=${e => e.key === 'Enter' && go()} />
            ${link && html`<button class="icon-btn" style="width:20px;height:20px" title="Clear" onClick=${() => setLink('')}><${Icon} name="x" /></button>`}
          </div>
          <button class="btn glass icon" style="--size:32px" title="Browse YouTube" onClick=${() => set({ sheet: { kind: 'youtube', onDownload: l => { set({ sheet: null }); go(l) } } })}><${Icon} name="youtube" /></button>
          <button class="btn glass icon" style="--size:32px" title="Paste link" onClick=${async () => setLink((await navigator.clipboard.readText()).trim())}><${Icon} name="clipboard" /></button>
          <button class="btn prominent" disabled=${!link.trim()} onClick=${() => go()}>Download</button>
        </div>
        <div class="row" style="flex-wrap:wrap;gap:12px">
          <select class="field" style="width:auto" value=${setting('dlQuality', 'best')} onChange=${e => saveSetting('dlQuality', e.target.value)}>
            ${QUALITIES.map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select>
          <${Switch} label="Match loudness target" title="Boost quiet downloads to your loudness target" checked=${setting('dlMatchLoudness', true)} onChange=${v => saveSetting('dlMatchLoudness', v)} />
          <button class="btn glass" title=${'Save to: ' + folder} onClick=${async () => { const d = await api.invoke('files:chooseFolder', 'Save downloads here', folder); if (d) { saveSetting('dlFolder', d); setFolder(d) } }}>
            <${Icon} name="folder" /> ${folder.split(/[\\/]/).pop()}</button>
          <span class="grow"></span>
          <button class="btn glass" disabled=${downloads.toolBusy} title="Get the latest yt-dlp (fixes most download errors after YouTube changes)"
            onClick=${() => toolTask('tools:update', 'yt-dlp is up to date.')}>${downloads.toolBusy ? html`<${Spinner} />` : html`<${Icon} name="refresh" /> Update yt-dlp`}</button>
        </div>
        <${Switch} label="Official tags & cover from Apple Music (album, year, track, genre)" checked=${setting('dlOfficialTags', true)} onChange=${v => saveSetting('dlOfficialTags', v)}
          title="After downloading, look the song up in Apple's catalog and use its tags and high-res cover when it's a clear match. Also used by the Auto tab." />
      </div>
      ${latest && html`<${JobCard} j=${latest} />`}` : html`<${SetupCard} />`}
    ${(downloads.toolBusy || downloads.log) && html`<div class="log" ref=${el => el && (el.scrollTop = el.scrollHeight)}>${downloads.log}</div>`}
    ${downloads.message && html`<div class="label-line muted"><${Icon} name="info" /> ${downloads.message}</div>`}
    <div class="label-line small faint"><${Icon} name="hand" /> Only download videos you own or have permission to download.</div>
  </div>`
}

// ───────────── Auto: search YouTube, preview, download → tags → editor ─────────────

const finder = { query: '', results: [], searching: false, message: null, preview: null }
const previewAudio = new Audio()
previewAudio.addEventListener('timeupdate', () => {
  if (!finder.preview) return
  finder.preview.progress = Math.min(previewAudio.currentTime / 30, 1)
  if (previewAudio.currentTime >= 30) stopPreview()
  touch()
})
previewAudio.addEventListener('ended', () => stopPreview())
export function stopPreview() {
  api.invoke('find:stopPreview')
  previewAudio.pause(); previewAudio.removeAttribute('src')
  finder.preview = null
  touch()
}
async function togglePreview(v) {
  if (finder.preview?.id === v.id) return stopPreview()
  stopPreview()
  finder.preview = { id: v.id, loading: true, progress: 0 }
  finder.message = null
  if (player.playing) player.playPause()     // pause your song
  touch()
  const url = await api.invoke('find:preview', `https://www.youtube.com/watch?v=${v.id}`)
  if (finder.preview?.id !== v.id) return
  if (!url) { finder.preview = null; finder.message = "Couldn't load a preview for that one."; return touch() }
  finder.preview.loading = false
  previewAudio.src = url
  previewAudio.volume = player.volume
  previewAudio.play().catch(() => { finder.preview = null; finder.message = "Couldn't play that preview."; touch() })
  touch()
}
async function search() {
  const q = finder.query.trim()
  if (!q) return
  stopPreview()
  Object.assign(finder, { results: [], message: null, searching: true }); touch()
  const r = await api.invoke('find:search', q)
  if (r.cancelled) return
  Object.assign(finder, { searching: false, results: r.results || [], message: r.error }); touch()
}
const viewsText = v => v == null ? null : v >= 1e9 ? (v / 1e9).toFixed(1) + 'B views' : v >= 1e6 ? (v / 1e6).toFixed(1) + 'M views' : v >= 1e3 ? Math.floor(v / 1e3) + 'K views' : v + ' views'

function VideoRow({ v, busy }) {
  const pv = finder.preview?.id === v.id ? finder.preview : null
  const pick = async () => { stopPreview(); downloads.findJob = await startDownload(`https://www.youtube.com/watch?v=${v.id}`, { openWhenDone: true }); touch() }
  const C = 2 * Math.PI * 15
  return html`<div class="video-row" onDblClick=${() => !busy && pick()} title="Double-click or press Download">
    <div class=${cls('vthumb', pv && 'on')} onClick=${() => togglePreview(v)} title=${pv ? 'Stop preview' : 'Play the first 30 seconds'}>
      <img src=${`https://i.ytimg.com/vi/${v.id}/mqdefault.jpg`} loading="lazy" />
      ${!pv && v.duration && html`<span class="dur">${fmtTime(v.duration)}</span>`}
      <div class="pv"><div class="ring">
        ${pv && !pv.loading && html`<svg class="arc" viewBox="0 0 34 34"><circle cx="17" cy="17" r="15" fill="none" stroke="#fff" stroke-width="2.5" stroke-linecap="round"
          stroke-dasharray=${C} stroke-dashoffset=${C * (1 - pv.progress)} style="transition:stroke-dashoffset .25s linear" /></svg>`}
        ${pv?.loading ? html`<${Spinner} />` : html`<${Icon} name=${pv ? 'pause' : 'play'} />`}
      </div></div>
    </div>
    <div class="grow">
      <div style="font-weight:600;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${v.title}</div>
      <div class="muted" style="font-size:13px;margin-top:3px">${[v.channel, viewsText(v.views)].filter(Boolean).join(' · ')}</div>
    </div>
    <button class="btn glass" disabled=${busy} onClick=${pick}>Download</button>
  </div>`
}

export function AutoView() {
  const input = useRef()
  useEffect(() => {
    refreshTools(); theme.followNothing(); input.current?.focus()
    if (!finder.query && !finder.results.length && S.info.env?.search) { finder.query = S.info.env.search; search() }
    return () => stopPreview()
  }, [])
  const ready = S.tools?.ytdlp && S.tools?.ffmpeg
  const job = downloads.findJob
  const busy = job && isActive(job)
  return html`<div class="page">
    <div><h2>Auto Download</h2><div class="muted" style="margin-top:4px">Type a song and artist, pick the right video, and it's downloaded and opened in the editor.</div></div>
    ${ready ? html`
      <div class="card" style="flex-direction:row;align-items:center">
        <div class="searchbox"><${Icon} name="search" />
          <input ref=${input} placeholder="Song name and artist" value=${finder.query} onInput=${e => { finder.query = e.target.value; touch() }} onKeyDown=${e => e.key === 'Enter' && search()} />
          ${finder.query && html`<button class="icon-btn" style="width:20px;height:20px" title="Clear" onClick=${() => { finder.query = ''; touch(); input.current.focus() }}><${Icon} name="x" /></button>`}
        </div>
        <button class="btn prominent" style="min-width:84px" disabled=${!finder.query.trim() || finder.searching} onClick=${search}>${finder.searching ? html`<${Spinner} />` : 'Search'}</button>
      </div>
      ${job && job.phase !== 'done' && html`<${JobCard} j=${job} />`}
      ${finder.message && html`<div class="label-line muted"><${Icon} name="info" /> ${finder.message}</div>`}
      ${downloads.message && html`<div class="label-line muted"><${Icon} name="info" /> ${downloads.message}</div>`}
      ${finder.results.length > 0 && html`<div class="card" style="padding:8px;gap:0">${finder.results.map(v => html`<${VideoRow} key=${v.id} v=${v} busy=${busy} />`)}</div>`}`
    : html`<div class="card"><div class="label-line"><${Icon} name="wrench" /> Finding songs uses yt-dlp and ffmpeg. Set them up in the Download tab first.</div>
        <div><button class="btn prominent" onClick=${() => set({ tab: 'download' })}>Go to Download</button></div></div>`}
    <div class="label-line small faint"><${Icon} name="hand" /> Only download videos you own or have permission to download.</div>
  </div>`
}

// ───────────── History detail ─────────────

export function HistoryDetail({ e }) {
  const [tag, setTag] = useState(null)
  useEffect(() => {
    setTag(null)
    if (e.exists) api.invoke('files:load', [e.path]).then(r => { if (r[0]) setTag(r[0].tag) })
  }, [e.id])
  const cover = tag?.cover ? coverURL(tag.cover, tag.coverMime) : e.thumb ? 'data:image/jpeg;base64,' + e.thumb : null
  useEffect(() => { theme.follow(tag?.cover || null) }, [tag])
  const rows = [['Artist', tag?.artist ?? e.artist], ['Album', tag?.album ?? e.album], ['Year', tag?.year], ['Genre', tag?.genre], ['Saved', `${relTime(e.lastSaved)}${e.saveCount > 1 ? ` · ${e.saveCount} times` : ''}`], ['File', e.path]]
  return html`<div class="hist">
    <div class="big">${cover ? html`<img src=${cover} />` : html`<${Icon} name="music" size=${64} />`}<div class="rim"></div></div>
    <div class="col" style="gap:12px;min-width:0">
      <h2>${tag?.title || e.title || baseName(e.path)}</h2>
      <dl class="kv">${rows.filter(r => r[1]).map(([k, v]) => html`<dt>${k}</dt><dd style="word-break:break-all">${v}</dd>`)}</dl>
      ${e.exists ? html`<div class="row">
          <button class="btn prominent" onClick=${() => player.toggle(e.path, 'history')}><${Icon} name=${player.isPlaying(e.path) ? 'pause' : 'play'} size=${14} /> ${player.isPlaying(e.path) ? 'Pause' : 'Play'}</button>
          <button class="btn glass" onClick=${() => openInEditor(e.path)}>Open in Editor</button>
          <button class="btn glass" onClick=${() => api.invoke('shell:show', e.path)}>Show in Folder</button></div>`
        : html`<div class="label-line warn"><${Icon} name="alert" /> This file was moved or deleted.</div>`}
    </div>
  </div>`
}

// ───────────── Changelog ─────────────

export function ChangelogView() {
  useEffect(() => { theme.followNothing() }, [])
  const versions = parseChangelog(S.info.changelog)
  return html`<div class="changelog">
    <h2 style="margin-bottom:18px">What's New</h2>
    ${versions.map(v => html`<div class="version" id=${'v-' + v.version}>
      <h3>${v.version} <span class="build">${v.build}</span></h3>
      <ul>${v.items.map(it => html`<li><${Icon} name=${/^fix/i.test(it) ? 'wrench' : 'sparkle'} /><span>${it}</span></li>`)}</ul>
    </div>`)}
  </div>`
}
