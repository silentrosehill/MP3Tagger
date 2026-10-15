import { html, useState, useEffect, useRef, S, cls, coverURL, fmtTime, setting, saveSetting } from '../lib.js'
import { Icon, SpeakerIcon } from '../icons.js'
import { Marquee, Range } from './common.js'
import { player, theme } from '../state.js'

/** Runs `fn(now)` every animation frame while `on`. */
function useFrames(on, fn, deps = []) {
  useEffect(() => {
    if (!on) { fn(performance.now()); return }
    let raf
    const tick = now => { fn(now); raf = requestAnimationFrame(tick) }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [on, ...deps])
}

/** Vinyl at 33⅓ RPM, in step with the song's position (it stops when paused and jumps when you skip). */
function Vinyl({ cover, spinning }) {
  const face = useRef()
  useFrames(spinning, () => { if (face.current) face.current.style.transform = `rotate(${player.current * 200}deg)` })
  return html`<div class="vinyl">
    <div ref=${face} style="position:absolute;inset:0">
      <div class="face"></div>
      <div class="label">${cover && html`<img src=${cover} />`}</div>
      <div class="hole"></div>
    </div>
    <div class="shine"></div>
  </div>`
}

/** Degrees an audio CD has turned after t s: constant linear velocity (1.3 m/s) along a 1.6 µm spiral from r = 25 mm. */
function cdAngle(t) {
  const v = 1.3, r0 = 0.025, pitch = 1.6e-6
  const r = Math.sqrt(r0 * r0 + v * pitch * Math.max(t, 0) / Math.PI)
  return ((r - r0) / pitch * 360) % 360
}
const GLINTS = [
  { base: 8, w: 1.2, phase: 0, tint: '95,227,245', k: 0.9 },
  { base: 30, w: 4, phase: 1.7, tint: '255,255,255', k: 0.8 },
  { base: 140, w: 3, phase: 3.1, tint: '255,255,255', k: 0.6 },
  { base: 250, w: 2, phase: 4.4, tint: '183,240,200', k: 0.5 },
  { base: 300, w: 3, phase: 2.5, tint: '246,199,160', k: 0.5 },
]
const lobes = (w, c) => `conic-gradient(from 0deg, rgba(${c},0) 0%, rgba(${c},0) ${25 - w}%, rgba(${c},1) 25%, rgba(${c},0) ${25 + w}%, rgba(${c},0) ${75 - w}%, rgba(${c},1) 75%, rgba(${c},0) ${75 + w}%, rgba(${c},0) 100%)`

/** CD from its shiny side, real CD speed, Yeezus-style reflections that stay with the light. */
function CD({ spinning }) {
  const bow = useRef(), spin = useRef(), glints = useRef([])
  useFrames(spinning, () => {
    const t = player.current
    const wobble = Math.sin(t * 2.3) * 7 + Math.sin(t * 5.1) * 2.5
    if (bow.current) { bow.current.style.setProperty('--wob', wobble + 'deg'); bow.current.style.setProperty('--hue', Math.sin(t * 1.3) * 10 + 'deg') }
    GLINTS.forEach((g, i) => {
      const el = glints.current[i]
      if (!el) return
      el.style.transform = `rotate(${g.base + wobble + Math.sin(t * 1.1 + g.phase) * 3}deg)`
      el.style.opacity = g.k * (0.75 + 0.25 * Math.sin(t * 3.7 + g.phase))
    })
    if (spin.current) spin.current.style.transform = `rotate(${cdAngle(t)}deg)`
  })
  return html`<div class="cd">
    <div class="silver"></div>
    <div class="refl">
      <div ref=${bow} class="bow" style="position:absolute;inset:0;border-radius:50%"></div>
      ${GLINTS.map((g, i) => html`<div class="glint" ref=${el => { glints.current[i] = el }} style=${`position:absolute;inset:0;border-radius:50%;background:${lobes(g.w, g.tint)}`}></div>`)}
    </div>
    <div ref=${spin} style="position:absolute;inset:0"><div class="print"></div><div class="hub"></div><div class="ridges"></div></div>
    <div class="rimline"></div>
  </div>`
}

/** Dynamic Island-style bars moving with the song's real bass, mids and treble. */
function Bars({ playing }) {
  const box = useRef()
  const order = [2, 0, 1, 3, 5, 4]
  useFrames(playing, () => {
    const bars = box.current?.children
    if (!bars) return
    const t = player.current, s = player.spectrum, H = 24, W = 3.5
    for (let i = 0; i < 6; i++) {
      let v
      if (!playing) v = 0
      else if (s && s.levels.length > s.bands * 2) {
        const frames = s.levels.length / s.bands, x = Math.max(0, t * s.fps), k = Math.min(Math.floor(x), frames - 2), f = Math.min(x - k, 1)
        const a = s.levels[k * s.bands + order[i]], b = s.levels[(k + 1) * s.bands + order[i]]
        v = (a + (b - a) * f) / 255
      } else v = 0.25 + 0.2 * Math.sin(t * 6 + i * 1.1)    // still measuring: a soft idle wave
      bars[i].style.height = W + (H - W) * v + 'px'
    }
  })
  return html`<div class="bars" ref=${box}>${[0, 1, 2, 3, 4, 5].map(() => html`<i style=${playing ? 'transition:none' : ''}></i>`)}</div>`
}

/** Position slider + times, updating a few times a second (dragging seeks on release). */
function Progress() {
  const [, force] = useState(0), [scrub, setScrub] = useState(null)
  useEffect(() => { const id = setInterval(() => force(n => n + 1), 250); return () => clearInterval(id) }, [])
  const cur = scrub ?? player.current, dur = player.duration
  return html`
    <span class="t">${fmtTime(cur)}</span>
    <${Range} className="grow" value=${Math.min(cur, Math.max(dur, 1))} max=${Math.max(dur, 1)} disabled=${dur <= 0} title="Drag to skip through the song"
      onInput=${v => setScrub(v)} onChange=${v => { player.seek(v); setScrub(null) }} />
    <span class="t r">−${fmtTime(dur - cur)}</span>`
}

const MARGIN = 16
/** Picture-in-picture mini player: drag it anywhere, it snaps to the nearest corner. */
export function MiniPlayer() {
  const [corner, setCorner] = useState(setting('pipCorner', 'bottomTrailing'))
  const [drag, setDrag] = useState(null)
  const [volOpen, setVolOpen] = useState(false)
  const el = useRef(), volTimer = useRef(), holding = useRef(false)
  const [size, setSize] = useState({ w: innerWidth, h: innerHeight })
  useEffect(() => { const r = () => setSize({ w: innerWidth, h: innerHeight }); addEventListener('resize', r); return () => removeEventListener('resize', r) }, [])
  if (!player.path) return null

  const h = el.current?.offsetHeight || 130, w = 400
  const pos = c => ({
    x: c.endsWith('Leading') ? MARGIN : size.w - MARGIN - w,
    y: c.startsWith('top') ? 52 + MARGIN : size.h - MARGIN - h - (S.status ? 30 : 0),
  })
  const p = pos(corner)
  const left = drag ? p.x + drag.dx : p.x, top = drag ? p.y + drag.dy : p.y

  const startDrag = e => {
    if (e.button !== 0 || e.target.closest('button, input')) return
    e.preventDefault()
    const sx = e.clientX, sy = e.clientY
    let last = { t: performance.now(), x: sx, y: sy }, vel = { x: 0, y: 0 }
    const move = ev => {
      const now = performance.now(), dt = Math.max(now - last.t, 1)
      vel = { x: (ev.clientX - last.x) / dt, y: (ev.clientY - last.y) / dt }
      last = { t: now, x: ev.clientX, y: ev.clientY }
      setDrag({ dx: ev.clientX - sx, dy: ev.clientY - sy })
    }
    const up = ev => {
      removeEventListener('pointermove', move); removeEventListener('pointerup', up)
      // fling-aware: where the throw would land decides the corner
      const cx = p.x + w / 2 + (ev.clientX - sx) + vel.x * 180, cy = p.y + h / 2 + (ev.clientY - sy) + vel.y * 180
      const c = (cy < size.h / 2 ? 'top' : 'bottom') + (cx < size.w / 2 ? 'Leading' : 'Trailing')
      setCorner(c); saveSetting('pipCorner', c); setDrag(null)
    }
    addEventListener('pointermove', move); addEventListener('pointerup', up)
  }
  const touchVolume = () => {
    clearTimeout(volTimer.current)
    volTimer.current = setTimeout(() => { if (!holding.current) setVolOpen(false) }, 3000)
  }
  const spinning = player.playing
  const cover = player.cover ? coverURL(player.cover.bytes, player.cover.mime) : null
  const disc = theme.disc
  const mav = theme.style === 'mavericks'

  return html`<div class="pip-layer">
    <div ref=${el} class=${cls('pip', !mav && 'glass', drag && 'dragging')} style=${`left:${left}px;top:${top}px`} onPointerDown=${startDrag}>
      <div class="grab" title="Drag to move the player"></div>
      <button class="close" title="Close the player" onClick=${() => player.stop()}><${Icon} name="x" /></button>
      <div class="top" title="Drag to move the player">
        <div class=${cls('art', spinning && 'out')} style=${`width:${spinning ? 104 : 72}px`}>
          <div class="disc">${disc === 'cd' ? html`<${CD} spinning=${spinning} />` : html`<${Vinyl} cover=${cover} spinning=${spinning} />`}</div>
          <div class="cov">${cover ? html`<img src=${cover} />` : html`<${Icon} name="music" />`}</div>
        </div>
        <div class="titles">
          <${Marquee} className="a" text=${player.title} />
          <${Marquee} className="b" text=${player.artist || 'Unknown artist'} />
        </div>
        <${Bars} playing=${spinning} />
      </div>
      <div class="controls">
        <button class="ctl small" title="Previous song (←)" onClick=${() => player.previous()}><${Icon} name="back" /></button>
        <button class="ctl big" title=${spinning ? 'Pause (Space)' : 'Play (Space)'} onClick=${() => player.playPause()}><${Icon} name=${spinning ? 'pause' : 'play'} /></button>
        <button class="ctl small" title="Next song (→)" disabled=${!player.hasNext} onClick=${() => player.next()}><${Icon} name="fwd" /></button>
        <${Progress} />
        <button class="ctl vol" title=${`Volume ${Math.round(player.volume * 100)}%`} onClick=${() => { setVolOpen(!volOpen); touchVolume() }}>
          <${SpeakerIcon} volume=${player.volume} /></button>
      </div>
      ${volOpen && html`<div class=${cls('volpill', !mav && 'glass')}>
        <button class="icon-btn" title=${player.volume === 0 ? 'Unmute' : 'Mute'} onClick=${() => { player.toggleMute(); touchVolume() }}>
          <${SpeakerIcon} volume=${player.volume === 0 ? 0 : -1} /></button>
        <${Range} value=${player.volume} onInput=${v => { player.setVolume(v); touchVolume() }}
          onPointerDown=${() => { holding.current = true }} onPointerUp=${() => { holding.current = false; touchVolume() }} />
        <span class="n">${Math.round(player.volume * 100)}</span>
      </div>`}
    </div>
  </div>`
}
