// Builds build/icon.ico (16–256 px PNG entries) from ../Icon/icon_v3_1024.png using macOS sips.
const { execFileSync } = require('child_process')
const fs = require('fs'), path = require('path'), os = require('os')
const src = path.join(__dirname, '..', '..', 'Icon', 'icon_v3_1024.png')
const sizes = [16, 24, 32, 48, 64, 128, 256]
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ico-'))
const pngs = sizes.map(s => {
  const out = path.join(tmp, `${s}.png`)
  execFileSync('sips', ['-z', String(s), String(s), src, '--out', out], { stdio: 'ignore' })
  return fs.readFileSync(out)
})
const head = Buffer.alloc(6 + 16 * sizes.length)
head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(sizes.length, 4)
let offset = head.length
sizes.forEach((s, i) => {
  const e = 6 + 16 * i
  head[e] = s >= 256 ? 0 : s; head[e + 1] = s >= 256 ? 0 : s
  head.writeUInt16LE(1, e + 4); head.writeUInt16LE(32, e + 6)
  head.writeUInt32LE(pngs[i].length, e + 8); head.writeUInt32LE(offset, e + 12)
  offset += pngs[i].length
})
fs.writeFileSync(path.join(__dirname, 'icon.ico'), Buffer.concat([head, ...pngs]))
fs.rmSync(tmp, { recursive: true })
console.log('icon.ico written')
