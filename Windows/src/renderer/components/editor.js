import { html, useState, useEffect, useRef, S, set, api, cls, coverURL, jpegCover, baseName, fmtTime, minus, status, setting, saveSetting } from '../lib.js'
import { Icon, SpeakerIcon } from '../icons.js'
import { Segmented, Spinner, Sheet } from './common.js'
import { edit, save, applyAlbumToAll, tagFileName, nameMatches, renameFromTags, player, theme } from '../state.js'

const FIELDS = [['title', 'Title'], ['artist', 'Artist'], ['album', 'Album'], ['albumArtist', 'Album Artist'], ['year', 'Year'], ['track', 'Track #'], ['genre', 'Genre']]

export function Editor({ f }) {
  const fileInput = useRef()
  useEffect(() => { theme.follow(f.tag.cover) }, [f.id, f.tag.cover])

  const setCover = async bytes => {
    try {
      const { bytes: jpeg } = await jpegCover(bytes)
      edit(f, 'cover', x => { x.tag = { ...x.tag, cover: jpeg, coverMime: 'image/jpeg' } })
    } catch { status("Couldn't use that image") }
  }
  const coverQuery = () => {
    const t = f.tag
    const name = t.album || t.title || baseName(f.path)
    return [t.albumArtist || t.artist, name, 'cover'].filter(Boolean).join(' ')
  }
  const openSearch = () => set({ sheet: { kind: 'cover', query: coverQuery(), onPick: bytes => setTimeout(() => setCover(bytes), 350) } })
  const name = tagFileName(f.tag)

  return html`<div class="editor">
    <div class="editor-left">
      <${GlassCover} cover=${f.tag.cover} onClick=${openSearch} onDropImage=${setCover} />
      <div class="row" style="gap:10px">
        <button class="btn glass icon" title="Search the web for cover art" onClick=${openSearch}><${Icon} name="globe" /></button>
        <button class="btn glass icon" title="Choose an image from your PC" onClick=${() => fileInput.current.click()}><${Icon} name="image" /></button>
        <button class="btn glass icon" title="Remove the cover" disabled=${!f.tag.cover}
          onClick=${() => edit(f, 'cover', x => { x.tag = { ...x.tag, cover: null } })}><${Icon} name="trash" /></button>
        <input ref=${fileInput} type="file" accept="image/*" style="display:none"
          onChange=${async e => { const file = e.target.files[0]; e.target.value = ''; if (file) setCover(new Uint8Array(await file.arrayBuffer())) }} />
      </div>
      <div class="small muted" style="white-space:nowrap">Click the cover to search, or drag an image onto it</div>
      <${TrimCard} f=${f} />
    </div>

    <div class="editor-right">
      <div class="form-grid">
        ${FIELDS.map(([k, label]) => html`
          <label for=${'f-' + k}>${label}</label>
          <input id=${'f-' + k} class="field" spellcheck="false" value=${f.tag[k]}
            onInput=${e => { const v = e.target.value; if (v !== f.tag[k]) edit(f, 'text:' + k, x => { x.tag = { ...x.tag, [k]: v } }) }} />`)}
      </div>
      <div class="btn-row" style="margin-top:16px;padding-left:96px">
        <button class="btn prominent" title="Save (Ctrl+S)" onClick=${() => save(f)}>Save…</button>
        <button class="btn glass" disabled=${S.files.length < 2} onClick=${() => applyAlbumToAll(f)}>Apply Album & Cover to All</button>
        <button class="btn glass icon" style="--size:30px" title="Fill in the official tags and cover from Apple Music"
          onClick=${() => set({ sheet: { kind: 'tags', file: f } })}><${Icon} name="wand" /></button>
      </div>
      <div style="padding-left:96px">
        <div class="path">${f.path}</div>
        ${name && !nameMatches(f.path, name) && html`<button class="link-btn" style="margin-top:6px" title="Rename the MP3 on disk to match its artist and title"
          onClick=${() => renameFromTags(f)}><${Icon} name="pencil" size=${13} /> Rename file to “${name}”</button>`}
      </div>
      <div style="margin-top:16px"><${LoudnessCard} f=${f} /></div>
    </div>
  </div>`
}

// ───────────── Cover: a glass slab that pours new art in ─────────────

function GlassCover({ cover, onClick, onDropImage }) {
  const url = coverURL(cover)
  const [layers, setLayers] = useState({ old: null, cur: url, key: 0, animate: false })
  const [drop, setDrop] = useState(false)
  useEffect(() => {
    if (url === layers.cur) return
    setLayers(l => ({ old: l.cur, cur: url, key: l.key + 1, animate: true }))
    const t = setTimeout(() => setLayers(l => ({ ...l, old: null })), 1500)
    return () => clearTimeout(t)
  }, [url])
  // a new song opens without the animation
  useEffect(() => () => {}, [])

  const onDrop = async e => {
    e.preventDefault(); e.stopPropagation(); setDrop(false)
    const file = [...e.dataTransfer.files].find(x => x.type.startsWith('image/'))
    if (file) return onDropImage(new Uint8Array(await file.arrayBuffer()))
    const link = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain')
    if (/^https?:\/\//.test(link)) {
      const bytes = await api.invoke('net:bytes', link.split(/\r?\n/)[0])
      if (bytes) onDropImage(bytes); else status("Couldn't download that image")
    }
  }
  const isImageDrag = e => [...e.dataTransfer.items].some(i => i.type.startsWith('image/') || i.type === 'text/uri-list')

  return html`<div class=${cls('cover', drop && 'drop')} onClick=${onClick} title="Click to search the web for cover art"
    onDragOver=${e => { if (isImageDrag(e)) { e.preventDefault(); e.stopPropagation(); setDrop(true) } }}
    onDragLeave=${() => setDrop(false)} onDrop=${onDrop}>
    ${layers.old && html`<img class="old" src=${layers.old} key=${'o' + layers.key} />`}
    ${layers.cur ? html`<img class=${cls('new', layers.animate && layers.old !== undefined && layers.key > 0 && 'pour')} src=${layers.cur} key=${'n' + layers.key} />`
      : html`<div class="empty" key=${'e' + layers.key}><${Icon} name="music" /><span class="row" style="gap:5px"><${Icon} name="search" size=${14} /> Search the web</span></div>`}
    ${layers.key > 0 && html`<div class="lens go" key=${'l' + layers.key}></div><div class="sheen go" key=${'s' + layers.key}></div>`}
    <div class="rim"></div>
    ${drop && html`<div class="frost"><${Icon} name="image" /><span>Drop to apply</span></div>`}
  </div>`
}

// ───────────── Loudness ─────────────

const STEP = 1.5, CEIL = -0.5, SPOTIFY = -14
const TARGETS = [{ value: -14, label: 'Spotify −14.0' }, { value: -11, label: 'Loud −11.0' }, { value: -9, label: 'Louder −9.0' }]
function recommended(r, target) {
  const wanted = Math.round((target - r.lufs) / STEP)
  if (wanted <= 0) return { steps: wanted, limited: false }
  const headroom = Math.max(Math.floor((CEIL - r.peakDB) / STEP), 0)
  return wanted > headroom ? { steps: headroom, limited: true } : { steps: wanted, limited: false }
}

function LoudnessCard({ f }) {
  const [state, setState] = useState({ r: null, failed: false, measuring: true, limited: false, boosting: false, error: null })
  const target = setting('loudnessTarget', SPOTIFY)
  const ffmpeg = S.tools?.ffmpeg

  const analyze = () => {
    setState(s => ({ ...s, measuring: true, failed: false }))
    const path = f.path
    api.invoke('loud:measure', path).then(r => {
      if (path !== f.path) return
      setState(s => ({ ...s, measuring: false, r: r.error ? null : r, failed: !!r.error }))
    })
  }
  useEffect(analyze, [f.path, f.mtime])

  const setSteps = steps => {
    const c = Math.min(Math.max(steps, -20), 20)
    if (c !== f.tag.gainSteps) edit(f, 'gain', x => { x.tag = { ...x.tag, gainSteps: c } })
  }
  const boost = async () => {
    f.tag = { ...f.tag, gainSteps: f.savedGain }    // the boost replaces any pending lossless change
    setState(s => ({ ...s, boosting: true, error: null }))
    const res = await player.release([f.path], () => api.invoke('loud:boost', f.path))
    if (res.error) setState(s => ({ ...s, boosting: false, error: res.error }))
    else { f.tag = { ...f.tag, limiterDB: res.tag.limiterDB, originalBackup: res.tag.originalBackup, gainSteps: 0 }; f.savedGain = 0; f.mtime = res.mtime; setState(s => ({ ...s, boosting: false })) }
  }
  const reset = async () => {
    setState(s => ({ ...s, limited: false }))
    if (!f.tag.limiterDB) return setSteps(0)
    setState(s => ({ ...s, boosting: true, error: null }))
    const res = await player.release([f.path], () => api.invoke('loud:restore', f.path, f.tag))
    if (res.error) setState(s => ({ ...s, boosting: false, error: res.error }))
    else { f.tag = { ...f.tag, limiterDB: 0, originalBackup: '', gainSteps: res.tag.gainSteps }; f.savedGain = res.tag.gainSteps; f.mtime = res.mtime; setState(s => ({ ...s, boosting: false })) }
  }

  const { r } = state
  let body
  if (r) {
    const pending = (f.tag.gainSteps - f.savedGain) * STEP
    const now = r.lufs + pending
    const x = v => (Math.min(Math.max(v, -30), -6) + 30) / 24 * 100
    const db = f.tag.gainSteps * STEP
    const boosted = !!f.tag.limiterDB
    const reach = r.lufs + recommended(r, target).steps * STEP
    const offTarget = boosted ? Math.abs(r.lufs - target) > 1 : reach < target - 1
    body = html`
      <div class="meter"><div class="fill" style=${`width:${x(now)}%`}></div>
        <div class="mark" style=${`left:calc(${x(SPOTIFY)}% - 1px)`}></div><div class="mark-label" style=${`left:${x(SPOTIFY)}%`}>Spotify</div></div>
      <div class="muted" style="font-size:13px">${minus(now)} LUFS${pending ? ' after saving' : ''} · target ${minus(target)}${target !== SPOTIFY ? ' (Spotify plays at −14)' : ''}</div>
      <div class="row"><span class="muted" style="font-size:13px">Target</span>
        <${Segmented} small value=${target} options=${TARGETS} onChange=${v => saveSetting('loudnessTarget', v)} /></div>
      <div class="row">
        <button class="btn prominent" title="Set the lossless boost that brings this song to the target (as far as its peaks allow)"
          onClick=${() => { const rec = recommended(r, target); setState(s => ({ ...s, limited: rec.limited })); setSteps(f.savedGain + rec.steps) }}>Match</button>
        <button class="btn glass icon" style="--size:30px" title="−1.5 dB" onClick=${() => { setState(s => ({ ...s, limited: false })); setSteps(f.tag.gainSteps - 1) }}><${Icon} name="minus" /></button>
        <span class="tnum" style="min-width:70px;text-align:center;font-size:13px">${db === 0 ? 'Original' : (db > 0 ? '+' : '−') + Math.abs(db).toFixed(1) + ' dB'}</span>
        <button class="btn glass icon" style="--size:30px" title="+1.5 dB" onClick=${() => { setState(s => ({ ...s, limited: false })); setSteps(f.tag.gainSteps + 1) }}><${Icon} name="plus" /></button>
        <button class="btn glass icon" style="--size:30px" title="Back to the original volume" disabled=${!f.tag.gainSteps && !f.tag.limiterDB} onClick=${reset}><${Icon} name="undo" /></button>
      </div>
      ${boosted && html`<div class="label-line small muted"><${Icon} name="wave" /> Boosted +${f.tag.limiterDB.toFixed(1)} dB with a limiter. Reset brings back the original.</div>`}
      ${offTarget && html`
        ${!boosted && html`<div class="label-line small warn"><${Icon} name="alert" /> About ${Math.round(target - reach)} dB under the target — its peaks leave no room for a lossless boost.</div>`}
        <div class="row">
          <button class="btn glass" disabled=${state.boosting || !ffmpeg} onClick=${boost}
            title=${ffmpeg ? "Raise it to the target and gently limit only the loudest peaks (like Spotify's Loud mode). Re-encodes once at 320 kbps from the original, which is kept." : 'Needs ffmpeg — set it up in the Download tab'}>
            ${state.boosting ? html`<${Spinner} />` : boosted ? `Re-boost to ${minus(target)}` : `Boost to ${minus(target)} with limiter`}</button>
          <span class="small faint">Re-encodes at 320 kbps · original kept</span>
        </div>`}
      ${!offTarget && r.peakDB + pending > CEIL + 0.01 && pending > 0 && html`<div class="label-line small warn"><${Icon} name="alert" /> This much boost may distort the loudest parts.</div>`}
      ${!offTarget && !(r.peakDB + pending > CEIL + 0.01 && pending > 0) && state.limited && html`<div class="label-line small muted"><${Icon} name="info" /> Boost limited so the loudest parts don't distort.</div>`}
      ${state.error && html`<div class="label-line small warn"><${Icon} name="alert" /> ${state.error}</div>`}
      ${!boosted && html`<div class="small faint">Lossless: the audio isn't re-encoded, and Reset restores the original exactly. Applies when you save.</div>`}`
  } else body = html`<div class="muted" style="font-size:13px">${state.failed ? "Couldn't read this song's audio." : 'Measuring…'}</div>`

  return html`<div class="panel card">
    <div class="row"><h3><${SpeakerIcon} volume=${1} /> Loudness</h3><span class="grow"></span>${state.measuring && html`<${Spinner} />`}</div>
    ${body}
  </div>`
}

// ───────────── Trim (lossless, applied on save) ─────────────

function PlayHead({ f, total }) {
  const ref = useRef()
  useEffect(() => {
    let raf
    const tick = () => {
      if (ref.current) {
        const on = player.path === f.path && total > 0
        ref.current.style.display = on ? '' : 'none'
        if (on) ref.current.style.left = `calc(${Math.min(player.current / total, 1) * 100}% - 1px)`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [f.path, total])
  return html`<div ref=${ref} class="head"></div>`
}

function TrimCard({ f }) {
  const [total, setTotal] = useState(0)
  useEffect(() => { api.invoke('files:info', f.path).then(i => setTotal(i.seconds)).catch(() => setTotal(0)) }, [f.path, f.mtime])
  const end = f.trimEnd ?? total
  const loaded = player.path === f.path
  const a = total ? f.trimStart / total : 0, b = total ? end / total : 1
  const setStart = v => edit(f, 'trim', x => { x.trimStart = Math.min(Math.max(0, v), end - 1) })
  const setEnd = v => edit(f, 'trim', x => { const e = Math.max(Math.min(v, total), x.trimStart + 1); x.trimEnd = e >= total - 0.01 ? null : e })
  const preview = async t => {
    if (!loaded) await player.toggle(f.path, 'files')
    else if (!player.playing) player.playPause()
    player.seek(t)
  }
  const fmt = v => `${fmtTime(Math.floor(v))}.${Math.floor(v * 10) % 10}`
  const row = (label, value, setter, from) => html`<div class="trim-row">
    <span>${label}</span>
    <button class="btn glass icon" style="--size:24px" title="0.5 s earlier" onClick=${() => setter(value - 0.5)}><${Icon} name="minus" /></button>
    <span class="time">${fmt(value)}</span>
    <button class="btn glass icon" style="--size:24px" title="0.5 s later" onClick=${() => setter(value + 0.5)}><${Icon} name="plus" /></button>
    <button class="btn glass" style="height:26px;padding:0 12px;justify-self:end" disabled=${!loaded} title=${loaded ? 'Use the current playback position' : 'Play this song first, then click at the right moment'}
      onClick=${() => setter(player.current)}>Here</button>
    <button class="btn glass icon" style="--size:24px" title=${label === 'Start' ? 'Play from the new start' : 'Play the last 4 seconds before the new end'}
      onClick=${() => preview(from)}><${Icon} name="play" /></button>
  </div>`
  return html`<div class="panel card" style="width:272px;margin-top:14px">
    <div class="row"><h3><${Icon} name="scissors" /> Trim</h3><span class="grow"></span>
      ${(f.trimStart > 0 || f.trimEnd != null) && html`<button class="btn glass icon" style="--size:26px" title="Keep the whole song"
        onClick=${() => edit(f, 'trim', x => { x.trimStart = 0; x.trimEnd = null })}><${Icon} name="undo" /></button>`}</div>
    <div class="trimbar"><div class="kept" style=${`left:${a * 100}%;width:max(4px, ${(b - a) * 100}%)`}></div><${PlayHead} f=${f} total=${total} /></div>
    ${row('Start', f.trimStart, setStart, f.trimStart)}
    ${row('End', end, setEnd, Math.max(f.trimStart, end - 4))}
    <div class="small muted">New length ${fmtTime(Math.max(0, end - f.trimStart))} of ${fmtTime(total)}. Cuts whole MP3 frames, no re-encoding. Applies when you save; use Save to a new name to keep the original.</div>
  </div>`
}

// ───────────── Official Tags (Apple Music catalog) ─────────────

export function TagsSheet({ file: f }) {
  const t = f.tag
  const title = t.title || baseName(f.path)
  const primary = (t.artist || '').split(/[,&]/)[0].replace(/\s+(x|feat\.?|ft\.?)\s+.*$/i, '').trim()
  const simple = title.replace(/\s*[([][^)\]]*[)\]]/g, '').replace(/\s+(ft\.?|feat\.?|featuring|with)\s+.*$/i, '').trim()
  const [query, setQuery] = useState([primary, simple].filter(Boolean).join(' '))
  const [results, setResults] = useState(null)
  const [applying, setApplying] = useState(null)
  const [duration, setDuration] = useState(null)
  const close = () => set({ sheet: null })
  const run = async (ti, ar, d) => { setResults(null); setResults(await api.invoke('tags:search', ti, ar, d)) }
  useEffect(() => { api.invoke('files:info', f.path).then(i => { setDuration(i.seconds); run(title, t.artist, i.seconds) }) }, [])
  const pick = async m => {
    setApplying(m.id)
    const cover = await api.invoke('tags:cover', m.raw)
    edit(f, 'tags', x => {
      const tag = { ...x.tag, title: m.title, artist: m.artist, albumArtist: m.raw.collectionArtistName || m.artist }
      if (m.album) tag.album = m.album
      if (m.year) tag.year = m.year
      if (m.raw.trackNumber) tag.track = m.raw.trackCount ? `${m.raw.trackNumber}/${m.raw.trackCount}` : String(m.raw.trackNumber)
      if (m.raw.primaryGenreName) tag.genre = m.raw.primaryGenreName
      if (cover) { tag.cover = cover; tag.coverMime = 'image/jpeg' }
      x.tag = tag
    })
    close()
    status(`Filled in from Apple Music: ${m.title} · ${m.album}`)
  }
  return html`<${Sheet} onClose=${close}>
    <div class="row"><h2 class="grow">Official Tags</h2><button class="btn glass" onClick=${close}>Cancel</button></div>
    <div class="muted" style="font-size:13px">Pick the right song from Apple's catalog. Title, artist, album, year, track, genre and a high-res cover get filled in (you can still edit them before saving).</div>
    <div class="row">
      <input class="field" value=${query} onInput=${e => setQuery(e.target.value)} placeholder="Song and artist" onKeyDown=${e => e.key === 'Enter' && run(query, '', duration)} />
      <button class="btn prominent" onClick=${() => run(query, '', duration)}>Search</button>
    </div>
    <div style="height:340px;overflow-y:auto;display:flex;flex-direction:column;gap:3px">
      ${results === null ? html`<div class="placeholder"><${Spinner} /></div>`
        : !results.length ? html`<div class="placeholder">No matches. Try other words.</div>`
        : results.map(m => html`<button class="result-row" disabled=${applying != null} onClick=${() => pick(m)}>
            <img src=${m.thumb} />
            <div class="grow"><div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${m.title}</div>
              <div class="muted" style="font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${[m.artist, m.album, m.year].filter(Boolean).join(' · ')}</div></div>
            ${applying === m.id ? html`<${Spinner} />` : m.seconds && html`<span class="small muted tnum">${fmtTime(m.seconds)}</span>`}
          </button>`)}
    </div>
  <//>`
}
