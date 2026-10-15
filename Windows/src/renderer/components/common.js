import { html, useState, useEffect, useRef, useLayoutEffect, cls, coverURL, rangeStyle } from '../lib.js'
import { Icon } from '../icons.js'
import { player } from '../state.js'

/** Switch whose theme-coloured thumb slides between options. options: [{value, label, icon?}] */
export function Segmented({ value, options, onChange, small, className }) {
  const box = useRef(), [thumb, setThumb] = useState(null)
  const measure = () => {
    const i = options.findIndex(o => o.value === value)
    const b = box.current?.children[i + 1]
    if (b) setThumb({ left: b.offsetLeft, width: b.offsetWidth })
  }
  useLayoutEffect(measure, [value, options.length])
  useEffect(() => {
    const ro = new ResizeObserver(measure)
    ro.observe(box.current)
    return () => ro.disconnect()
  }, [value])
  return html`<div ref=${box} class=${cls('segmented glass', small && 'small', className)}>
    <div class="thumb" style=${thumb ? `left:${thumb.left}px;width:${thumb.width}px` : 'opacity:0'}></div>
    ${options.map(o => html`<button class=${cls(o.value === value && 'on', o.icon && 'iconic')} title=${o.label}
      onClick=${() => onChange(o.value)}>${o.icon ? html`<${Icon} name=${o.icon} />` : o.label}</button>`)}
  </div>`
}

/** One line that scrolls like a ticker when it doesn't fit (only while `active`). */
export function Marquee({ text, active = true, className }) {
  const box = useRef(), inner = useRef(), [over, setOver] = useState(false)
  useLayoutEffect(() => {
    const check = () => box.current && inner.current && setOver(inner.current.scrollWidth - box.current.clientWidth > 0.5)
    check()
    const ro = new ResizeObserver(check)
    ro.observe(box.current)
    return () => ro.disconnect()
  }, [text])
  const scrolling = over && active
  useEffect(() => {
    if (!scrolling) return
    const el = inner.current, speed = 28, gap = 36, pause = 1.8
    const width = el.firstChild.offsetWidth + gap
    const start = performance.now()
    let raf
    const tick = now => {
      const cycle = ((now - start) / 1000) % (width / speed + pause)
      el.style.transform = `translateX(${-(cycle < pause ? 0 : (cycle - pause) * speed)}px)`
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => { cancelAnimationFrame(raf); el.style.transform = '' }
  }, [scrolling, text])
  return html`<div ref=${box} class=${cls('marquee', scrolling && 'scrolling', className)} title=${over ? text : undefined}>
    <span ref=${inner} style=${scrolling ? 'display:inline-flex;gap:36px' : ''}><span>${text}</span>${scrolling ? html`<span>${text}</span>` : null}</span>
  </div>`
}

/** Cover thumbnail you click to play/pause that song. */
export function PlayThumb({ path, cover, mime, size = 40, source, disabled, onError }) {
  const current = player.path === path, playing = player.isPlaying(path)
  const [hover, setHover] = useState(false)
  const url = cover ? (typeof cover === 'string' ? cover : coverURL(cover, mime)) : null
  return html`<div class=${cls('thumb', current && 'current')} style=${`width:${size}px;height:${size}px;border-radius:${size / 10}px`}
    onMouseEnter=${() => setHover(true)} onMouseLeave=${() => setHover(false)}
    onClick=${e => { e.stopPropagation(); if (!disabled) player.toggle(path, source).catch(() => onError?.("Couldn't play this file")) }}
    title=${playing ? 'Pause' : 'Play'}>
    ${url ? html`<img src=${url} loading="lazy" />` : html`<${Icon} name="music" />`}
    ${!disabled && html`<div class="play">
      ${playing && !hover ? html`<${Icon} name="speaker" /> ` : html`<${Icon} name=${playing ? 'pause' : 'play'} />`}
    </div>`}
  </div>`
}

export function Switch({ checked, onChange, label, sub, title }) {
  return html`<label class="switch" title=${title}>
    <input type="checkbox" checked=${checked} onChange=${e => onChange(e.target.checked)} />
    <span class="track"></span>
    ${label && html`<span class="col"><span>${label}</span>${sub && html`<span class="small muted">${sub}</span>`}</span>`}
  </label>`
}

export function Range({ value, min = 0, max = 1, step = 'any', onInput, onChange, className, disabled, title, onPointerDown, onPointerUp }) {
  return html`<input type="range" class=${className} min=${min} max=${max} step=${step} value=${value} disabled=${disabled} title=${title}
    style=${rangeStyle(value, min, max)} onInput=${e => onInput?.(parseFloat(e.target.value))}
    onChange=${e => onChange?.(parseFloat(e.target.value))} onPointerDown=${onPointerDown} onPointerUp=${onPointerUp} />`
}

export const Spinner = () => html`<span class="spinner"></span>`

/** Closes popovers on an outside click or Escape. */
export function useDismiss(ref, onClose) {
  useEffect(() => {
    const down = e => { if (ref.current && !ref.current.contains(e.target) && !e.target.closest('[data-keep-popover]')) onClose() }
    const key = e => { if (e.key === 'Escape') onClose() }
    setTimeout(() => document.addEventListener('mousedown', down), 0)
    document.addEventListener('keydown', key)
    return () => { document.removeEventListener('mousedown', down); document.removeEventListener('keydown', key) }
  }, [])
}

export function Sheet({ children, width = 560, onClose, style }) {
  useEffect(() => {
    const key = e => { if (e.key === 'Escape') onClose?.() }
    document.addEventListener('keydown', key)
    return () => document.removeEventListener('keydown', key)
  }, [])
  return html`<div class="scrim" onMouseDown=${e => { if (e.target === e.currentTarget) onClose?.() }}>
    <div class="sheet" style=${`width:${width}px;${style || ''}`}>${children}</div>
  </div>`
}
