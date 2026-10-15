// Runs in a worker thread: decodes MP3s (mpg123 compiled to WebAssembly) and measures them —
// BS.1770 / EBU R128 integrated loudness and sample peak, and the visualizer's frequency bands.
const { parentPort } = require('worker_threads')
const fs = require('fs')
const { MPEGDecoder } = require('mpg123-decoder')

let decoder
async function decode(file) {
  if (!decoder) { decoder = new MPEGDecoder(); await decoder.ready }
  else await decoder.reset()
  const data = new Uint8Array(fs.readFileSync(file))
  // decode in chunks so huge files don't need one giant WebAssembly buffer
  const chunks = [], step = 1 << 20
  let rate = 0, channels = 0, total = 0
  for (let o = 0; o < data.length; o += step) {
    const r = decoder.decode(data.subarray(o, o + step))
    if (r.samplesDecoded) {
      rate = r.sampleRate; channels = r.channelData.length
      chunks.push(r.channelData); total += r.samplesDecoded
    }
  }
  if (!total) throw new Error('No audio found in this file.')
  const out = []
  for (let c = 0; c < channels; c++) {
    const a = new Float32Array(total)
    let at = 0
    for (const ch of chunks) { a.set(ch[c], at); at += ch[c].length }
    out.push(a)
  }
  return { channels: out, sampleRate: rate }
}

/** Integrated loudness (LUFS) and sample peak, like the Mac app's vDSP meter (same K-weighting as libebur128). */
function measure({ channels, sampleRate: fs_ }) {
  const f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
  const K = Math.tan(Math.PI * f0 / fs_)
  const Vh = Math.pow(10, G / 20), Vb = Math.pow(Vh, 0.4996667741545416)
  const a0 = 1 + K / Q + K * K
  const s1 = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
  const f1 = 38.13547087602444, Q1 = 0.5003270373238773
  const K1 = Math.tan(Math.PI * f1 / fs_), a01 = 1 + K1 / Q1 + K1 * K1
  const s2 = [1, -2, 1, 2 * (K1 * K1 - 1) / a01, (1 - K1 / Q1 + K1 * K1) / a01]

  const seg = Math.max(Math.floor(fs_ * 0.1), 1)
  const n = channels[0].length
  const nseg = Math.floor(n / seg)
  const segs = channels.map(() => new Float64Array(nseg))
  let peak = 0
  channels.forEach((x, ch) => {
    for (let i = 0; i < n; i++) { const a = x[i] < 0 ? -x[i] : x[i]; if (a > peak) peak = a }
    // two biquads (direct form I), then the mean square of each complete 100 ms segment
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0, w1 = 0, w2 = 0, u1 = 0, u2 = 0
    const sums = segs[ch]
    for (let s = 0; s < nseg; s++) {
      let acc = 0
      for (let i = s * seg, e = i + seg; i < e; i++) {
        const v = x[i]
        const y = s1[0] * v + s1[1] * x1 + s1[2] * x2 - s1[3] * y1 - s1[4] * y2
        x2 = x1; x1 = v; y2 = y1; y1 = y
        const z = y - 2 * w1 + w2 - s2[3] * u1 - s2[4] * u2
        w2 = w1; w1 = y; u2 = u1; u1 = z
        acc += z * z
      }
      sums[s] = acc / seg
    }
  })
  // 400 ms blocks = 4 consecutive segments (75% overlap), absolute (−70) and relative (−10) gates
  const lufs = z => -0.691 + 10 * Math.log10(z)
  const blocks = []
  for (let i = 0; i + 4 <= nseg; i++) {
    let z = 0
    for (const sg of segs) z += (sg[i] + sg[i + 1] + sg[i + 2] + sg[i + 3]) / 4
    blocks.push(z)
  }
  const abs = blocks.filter(z => z > 0 && lufs(z) > -70)
  if (!abs.length) return { lufs: -70, peak }
  const rel = lufs(abs.reduce((a, b) => a + b, 0) / abs.length) - 10
  const gated = abs.filter(z => lufs(z) > rel)
  return { lufs: lufs(gated.reduce((a, b) => a + b, 0) / Math.max(gated.length, 1)), peak }
}

/** Six frequency bands every 1/30 s (2048-point FFT, Hann window, mono), each scaled over the song. */
function spectrum({ channels, sampleRate: sr }) {
  const FPS = 30, BANDS = 6, edges = [30, 110, 300, 850, 2200, 5500, 14000]
  const N = 2048, hop = Math.max(1, Math.floor(sr / FPS))
  const len = channels[0].length
  const mono = new Float32Array(len)
  for (const c of channels) for (let i = 0; i < len; i++) mono[i] += c[i] / channels.length
  const win = new Float32Array(N)
  for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / N)
  const binHz = sr / N
  const bins = []
  for (let b = 0; b < BANDS; b++) {
    const lo = Math.max(1, Math.floor(edges[b] / binHz)), hi = Math.min(N / 2, Math.max(lo + 1, Math.floor(edges[b + 1] / binHz)))
    bins.push([lo, hi])
  }
  // bit-reversal table and twiddles for an in-place radix-2 FFT
  const rev = new Uint16Array(N)
  for (let i = 0, j = 0; i < N; i++) {
    rev[i] = j
    let bit = N >> 1
    while (j & bit) { j ^= bit; bit >>= 1 }
    j |= bit
  }
  const cos = new Float32Array(N / 2), sin = new Float32Array(N / 2)
  for (let i = 0; i < N / 2; i++) { cos[i] = Math.cos(-2 * Math.PI * i / N); sin[i] = Math.sin(-2 * Math.PI * i / N) }
  const re = new Float32Array(N), im = new Float32Array(N)

  const frames = Math.max(0, Math.floor((len - N) / hop) + 1)
  const db = new Float32Array(frames * BANDS)
  for (let f = 0; f < frames; f++) {
    const o = f * hop
    for (let i = 0; i < N; i++) { re[rev[i]] = mono[o + i] * win[i]; im[rev[i]] = 0 }
    for (let size = 2; size <= N; size <<= 1) {
      const half = size >> 1, step = N / size
      for (let s = 0; s < N; s += size) {
        for (let k = 0; k < half; k++) {
          const tr = cos[k * step], ti = sin[k * step]
          const a = s + k, b = a + half
          const xr = re[b] * tr - im[b] * ti, xi = re[b] * ti + im[b] * tr
          re[b] = re[a] - xr; im[b] = im[a] - xi
          re[a] += xr; im[a] += xi
        }
      }
    }
    for (let b = 0; b < BANDS; b++) {
      const [lo, hi] = bins[b]
      let e = 0
      for (let k = lo; k < hi; k++) e += re[k] * re[k] + im[k] * im[k]
      db[f * BANDS + b] = 10 * Math.log10(e / (hi - lo) + 1e-12)
    }
  }
  // each bar gets its own range (quiet floor → loud peak over the song), so hi-hats move as much as kicks
  const levels = new Uint8Array(frames * BANDS)
  for (let b = 0; b < BANDS; b++) {
    const col = []
    for (let f = 0; f < frames; f++) col.push(db[f * BANDS + b])
    if (!col.length) continue
    col.sort((a, c) => a - c)
    const floor = col[Math.floor((col.length - 1) * 0.15)], top = col[Math.floor((col.length - 1) * 0.985)]
    const span = Math.max(top - floor, 6)
    for (let f = 0; f < frames; f++) {
      const v = Math.min(Math.max((db[f * BANDS + b] - floor) / span, 0), 1)
      levels[f * BANDS + b] = Math.round(Math.pow(v, 1.4) * 255)
    }
  }
  return { fps: FPS, bands: BANDS, levels }
}

let queue = Promise.resolve()
parentPort.on('message', ({ id, kind, file }) => {
  queue = queue.then(async () => {
    try {
      const pcm = await decode(file)
      const result = kind === 'spectrum' ? spectrum(pcm) : measure(pcm)
      parentPort.postMessage({ id, result })
    } catch (e) {
      parentPort.postMessage({ id, error: String(e && e.message || e) })
    }
  })
})
