import { html, useState, useEffect, useRef, S, set, api, cls, palette, hsb, fromHex, PRESETS, PURPLE, sameColor, jpegCover, status } from '../lib.js'
import { Icon } from '../icons.js'
import { Segmented, Switch, Range, Spinner, Sheet, useDismiss } from './common.js'
import { theme } from '../state.js'

// ───────────── Theme picker ─────────────

export function ThemePicker({ anchor }) {
  const ref = useRef()
  useDismiss(ref, () => set({ popover: null }))
  const base = theme.base
  const hex = hsb(base.hue, base.saturation, base.brightness)
  return html`<div ref=${ref} class="popover" style=${`top:56px;right:${anchor}px;width:282px`}>
    <div class="col" style="gap:14px">
      <h3 style="font-size:15px">Theme</h3>
      <div><div class="sub">Style</div>
        <${Segmented} value=${theme.style} options=${[{ value: 'glass', label: 'Liquid Glass' }, { value: 'mavericks', label: 'Mavericks' }]}
          onChange=${v => theme.set('uiStyle', v)} />
        ${theme.style === 'mavericks' && html`<div class="small muted" style="margin-top:6px">Classic OS X 10.9 look: Aqua buttons, light panels. Colors below apply to Liquid Glass.</div>`}
      </div>
      ${theme.style === 'glass' && html`<div><div class="sub">Glass</div>
        <div class="row"><span class="small muted">Clear</span>
          <${Range} value=${theme.glassTint} onInput=${v => theme.set('glassTint', v)} title="How the app's glass looks: clear and see-through, or frosted and tinted with your colour" />
          <span class="small muted">Tinted</span></div></div>`}
      <div><div class="sub">Player disc</div>
        <${Segmented} value=${theme.disc} options=${[{ value: 'vinyl', label: 'Vinyl' }, { value: 'cd', label: 'CD' }]} onChange=${v => theme.set('discKind', v)} /></div>
      <hr />
      <${Switch} checked=${theme.matchCover} onChange=${v => theme.set('themeMatchCover', v)} label="Match album cover" sub="Colors follow the cover you're viewing" />
      <div class="swatches">
        ${PRESETS.map(([name, t]) => {
          const p = palette(t), on = !theme.matchCover && sameColor(base, t)
          return html`<button class=${cls('swatch', on && 'on')} title=${name} onClick=${() => theme.setBase(t)}
            style=${`background:linear-gradient(135deg, ${p.pink}, ${p.purple}, ${p.indigo});box-shadow:0 2px ${on ? 8 : 4}px color-mix(in srgb, ${p.purple} ${on ? 70 : 35}%, transparent)`}>
            ${on && html`<${Icon} name="check" />`}</button>`
        })}
      </div>
      <hr />
      <div class="row"><span class="grow">Custom color</span>
        <input type="color" class="color-well" value=${hex} onInput=${e => theme.setBase(fromHex(e.target.value))} /></div>
      <div><div class="row"><span class="grow">Sidebar tint</span><span class="muted tnum">${Math.round(theme.tint * 100)}%</span></div>
        <${Range} value=${theme.tint} max=${2} onInput=${v => theme.set('themeTint', v)} /></div>
      <div style="text-align:center"><button class="btn glass" onClick=${() => theme.setBase(PURPLE)}>Reset to Purple</button></div>
    </div>
  </div>`
}

// ───────────── Info: what's where ─────────────

const SECTIONS = [
  ['files', 'musicList', 'Files', ['Drop MP3s or folders, or press +', 'Edit title, artist, album, year, track and genre',
    'Cover: drag an image on, pick a file, or search albums and the web', '✨ Official Tags: fill everything in from Apple Music',
    'Loudness: match Spotify (−14 LUFS), lossless and undoable', 'Trim: cut a talking intro/outro (play it, click Here), no re-encoding',
    'Save, Apply Album & Cover to All · Ctrl+Z undoes unsaved changes', 'Rename files to “Artist - Title” (under the path, or right-click)']],
  ['history', 'history', 'History', ["Every song you've saved, newest first", 'Click a cover to play it']],
  ['find', 'wand', 'Auto', ['Type a song and artist to find it on YouTube', 'Click a thumbnail to hear the first 30 seconds', 'Download: official tags + cover, Spotify loudness, then the editor']],
  ['download', 'download', 'Download', ['Paste a video link, or browse YouTube in the app (with ad blocker)', 'Pick the quality and folder, and update yt-dlp if downloads fail']],
  ['changelog', 'notes', 'Changelog', ['What changed in every version', 'New versions: the app checks GitHub daily, or use Check for Updates below']],
  [null, 'disc', 'Mini player', ['Drag it anywhere; it snaps to the corners', 'Vinyl or CD, visualizer, seek bar, volume, ✕ to close',
    'Plays through the list: ⏮ ⏭, or Space = play/pause, ← → = previous/next; media keys work too']],
  [null, 'palette', 'Theme (🎨)', ['Liquid Glass or Mavericks style, vinyl or CD', 'Colors, custom color, or match the album cover']],
]

export function InfoPanel({ anchor }) {
  const ref = useRef()
  useDismiss(ref, () => set({ popover: null }))
  return html`<div ref=${ref} class="popover" style=${`top:56px;right:${anchor}px;width:360px`}>
    <h3 style="margin-bottom:8px">What's where</h3>
    ${SECTIONS.map(([tab, icon, title, points]) => html`<button class=${cls('info-section', tab && 'go')} disabled=${!tab}
      onClick=${() => tab && set({ tab, popover: null })} style=${tab ? '' : 'cursor:default'}>
      <${Icon} name=${icon} />
      <div><div style="font-weight:600">${title}</div><ul>${points.map(p => html`<li>${p}</li>`)}</ul></div>
    </button>`)}
    <hr style="margin:8px 0" />
    <div class="row"><span class="small muted grow">MP3 Tagger ${S.info.version}</span>
      <button class="btn glass" style="height:26px" onClick=${() => { set({ popover: null }); checkUpdates(true) }}>Check for Updates…</button></div>
  </div>`
}

export async function checkUpdates(manual) {
  const r = await api.invoke('update:check', manual)
  if (!r) return
  set({ sheet: { kind: 'alert', title: r.title, message: r.message,
    buttons: r.url ? [{ label: 'Download', prominent: true, action: () => api.invoke('shell:open', r.url) }] : [],
    cancel: r.version ? 'Later' : 'OK', onCancel: r.version ? () => api.invoke('update:skip', r.version) : null } })
}

// ───────────── Alert ─────────────

export function AlertSheet({ title, message, buttons = [], cancel, onCancel }) {
  const close = () => set({ sheet: null })
  return html`<${Sheet} width=${430} onClose=${() => { onCancel?.(); close() }}>
    <h2 style="font-size:17px">${title}</h2>
    ${message && html`<p class="muted" style="margin:0;line-height:1.5">${message}</p>`}
    <div class="row" style="justify-content:flex-end;margin-top:6px">
      <button class="btn glass" onClick=${() => { onCancel?.(); close() }}>${cancel || (buttons.length ? 'Cancel' : 'OK')}</button>
      ${buttons.map(b => html`<button class=${cls('btn', b.prominent ? 'prominent' : 'glass')} onClick=${() => { close(); b.action() }}>${b.label}</button>`)}
    </div>
  <//>`
}

// ───────────── Cover search: Apple's album art, or the web ─────────────

const ENGINES = {
  google: q => `https://www.google.com/search?${new URLSearchParams({ q, udm: '2' })}`,
  duckduckgo: q => `https://duckduckgo.com/?${new URLSearchParams({ q, iax: 'images', ia: 'images' })}`,
  bing: q => `https://www.bing.com/images/search?${new URLSearchParams({ q })}`,
}

export function CoverSheet({ query: initial, onPick }) {
  const [query, setQuery] = useState(initial)
  const [mode, setMode] = useState('albums')
  const [engine, setEngine] = useState('google')
  const [albums, setAlbums] = useState(null)
  const [error, setError] = useState(null)
  const [message, setMessage] = useState(null)
  const [webURL, setWebURL] = useState(null)
  const [small, setSmall] = useState(null)
  const close = () => set({ sheet: null })

  const searchAlbums = async q => {
    setAlbums(null); setError(null)
    const r = await api.invoke('covers:albums', q)
    if (r.error) { setAlbums([]); setError(r.error) } else { setAlbums(r.albums); if (!r.albums.length) setError('No albums found. Try fewer words, or search the Web tab.') }
  }
  const search = () => { if (mode === 'albums') searchAlbums(query); else setWebURL(ENGINES[engine](query)) }
  useEffect(() => { searchAlbums(query) }, [])
  useEffect(() => { if (mode === 'web' && !webURL) setWebURL(ENGINES[engine](query)) }, [mode])

  const use = async (url, minCheck) => {
    setMessage('Getting image…'); setSmall(null)
    const bytes = await api.invoke('net:bytes', url)
    if (!bytes) return setMessage("Couldn't download that image. Try clicking it first and using the larger preview.")
    try {
      const { width } = await jpegCover(bytes)
      if (minCheck && width < 300) { setMessage(null); return setSmall({ bytes, width }) }
    } catch { return setMessage("That isn't an image MP3 Tagger can read.") }
    close(); onPick(bytes)
  }
  useEffect(() => api.on('cover:useImage', src => use(src, true)), [])

  return html`<${Sheet} width=${Math.min(innerWidth - 80, 900)} style=${`height:${Math.min(innerHeight - 80, 720)}px`} onClose=${close}>
    <div class="row">
      <${Segmented} value=${mode} options=${[{ value: 'albums', label: 'Albums' }, { value: 'web', label: 'Web' }]} onChange=${setMode} />
      <div class="searchbox"><${Icon} name="search" /><input value=${query} onInput=${e => setQuery(e.target.value)} onKeyDown=${e => e.key === 'Enter' && search()} /></div>
      ${mode === 'web' && html`<select class="field" style="width:auto" value=${engine} onChange=${e => { setEngine(e.target.value); setWebURL(ENGINES[e.target.value](query)) }}>
        <option value="google">Google</option><option value="duckduckgo">DuckDuckGo</option><option value="bing">Bing</option></select>`}
      <button class="btn prominent" onClick=${search}>Search</button>
      <button class="btn glass" onClick=${close}>Close</button>
    </div>
    <div class="small muted">${mode === 'albums' ? "Official album art from Apple's catalog. Click one to use it." : 'Right-click any image → Use as Cover Art.'}
      ${message && html` · <span class="warn">${message}</span>`}</div>
    ${small && html`<div class="row small warn"><${Icon} name="alert" size=${14} /> That image is only ${small.width} px, so it may look blurry.
      <button class="btn glass" style="height:24px" onClick=${() => { close(); onPick(small.bytes) }}>Use Anyway</button></div>`}
    ${mode === 'albums' ? html`<div style="flex:1;overflow-y:auto">
        ${albums === null ? html`<div class="placeholder"><${Spinner} /></div>` : error ? html`<div class="placeholder">${error}</div>`
          : html`<div class="album-grid">${albums.map(a => html`<button class="album" title=${`${a.name} — ${a.artist}`} onClick=${() => use(a.art.replace('100x100bb', '1200x1200bb'))}>
              <img src=${a.art.replace('100x100bb', '300x300bb')} loading="lazy" /><div class="n">${a.name}</div><div class="a">${a.artist}</div></button>`)}</div>`}
      </div>` : webURL && html`<webview src=${webURL} partition="persist:covers"></webview>`}
  <//>`
}

// ───────────── YouTube browser (signed in stays signed in; ad blocker built in) ─────────────

export function YouTubeSheet({ onDownload }) {
  const view = useRef()
  const [url, setURL] = useState('https://www.youtube.com/')
  const [adblock, setAdblock] = useState(S.settings.adBlock ?? true)
  useEffect(() => {
    const v = view.current
    if (!v) return
    const nav = () => setURL(v.getURL())
    v.addEventListener('did-navigate', nav); v.addEventListener('did-navigate-in-page', nav)
    return () => { v.removeEventListener('did-navigate', nav); v.removeEventListener('did-navigate-in-page', nav) }
  }, [])
  const isVideo = /youtube\.com\/(watch|shorts\/)|youtu\.be\//.test(url)
  const close = () => set({ sheet: null })
  return html`<${Sheet} width=${Math.min(innerWidth - 60, 1100)} style=${`height:${Math.min(innerHeight - 60, 820)}px`} onClose=${close}>
    <div class="row">
      <button class="icon-btn" title="Back" onClick=${() => view.current?.goBack()}><${Icon} name="left" /></button>
      <button class="icon-btn" title="Forward" onClick=${() => view.current?.goForward()}><${Icon} name="right" /></button>
      <button class="icon-btn" title="Reload" onClick=${() => view.current?.reload()}><${Icon} name="refresh" /></button>
      <div class="searchbox"><${Icon} name="youtube" style="color:var(--pink)" /><input value=${url} readonly /></div>
      <${Switch} label="Block ads" checked=${adblock} onChange=${v => { setAdblock(v); api.invoke('settings:set', 'adBlock', v); view.current?.reload() }} />
      <button class="btn prominent" disabled=${!isVideo} title=${isVideo ? 'Download this video\'s audio' : 'Open a video first'} onClick=${() => onDownload(url)}><${Icon} name="download" size=${15} /> Download</button>
      <button class="btn glass" onClick=${close}>Close</button>
    </div>
    <webview ref=${view} src="https://www.youtube.com/" partition="persist:youtube" allowpopups
     ></webview>
  <//>`
}
