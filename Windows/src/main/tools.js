// Finds and installs the two download tools: yt-dlp (fetches the audio) and ffmpeg (MP3 conversion,
// limiter boost). On Windows they're downloaded into the app's data folder; on a Mac (development) Homebrew's are used.
const fs = require('fs')
const path = require('path')
const { spawn } = require('child_process')
const { net } = require('electron')
const { dataDir } = require('./store')

const isWin = process.platform === 'win32'
const exe = name => (isWin ? name + '.exe' : name)
const toolsDir = () => path.join(dataDir(), 'tools')

const YTDLP_URL = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
const FFMPEG_URL = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'

function searchDirs() {
  const dirs = [toolsDir()]
  if (!isWin) dirs.push('/opt/homebrew/bin', '/usr/local/bin', path.join(require('os').homedir(), '.local/bin'), '/usr/bin')
  if (isWin && process.env.LOCALAPPDATA) dirs.push(path.join(process.env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links'))
  for (const d of (process.env.PATH || process.env.Path || '').split(path.delimiter)) if (d) dirs.push(d)
  return dirs
}

function find(name) {
  for (const d of searchDirs()) {
    const p = path.join(d, exe(name))
    try { if (fs.statSync(p).isFile()) return p } catch {}
  }
  return null
}

function status() {
  return { ytdlp: find('yt-dlp'), ffmpeg: find('ffmpeg'), brew: isWin ? null : find('brew'), platform: process.platform }
}

/** Environment for tool processes: UTF-8 output, and the tools folder on PATH. */
function env() {
  const e = { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUTF8: '1' }
  const extra = isWin ? [toolsDir()] : [toolsDir(), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']
  // Windows spells it "Path"; keep exactly one key, whatever its case
  const key = Object.keys(e).find(k => k.toUpperCase() === 'PATH') || 'PATH'
  e[key] = [...extra, e[key] || ''].join(path.delimiter)
  return e
}

async function download(url, dest, onProgress) {
  const r = await net.fetch(url)
  if (!r.ok) throw new Error(`Download failed (HTTP ${r.status})`)
  const total = Number(r.headers.get('content-length')) || 0
  const tmp = dest + '.part'
  const out = fs.createWriteStream(tmp)
  let got = 0, lastPct = -1
  const reader = r.body.getReader()
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    got += value.length
    if (!out.write(Buffer.from(value))) await new Promise(res => out.once('drain', res))
    const pct = total ? Math.floor(got / total * 100) : -1
    if (pct !== lastPct && pct % 5 === 0) { lastPct = pct; onProgress(pct) }
  }
  await new Promise((res, rej) => out.end(err => (err ? rej(err) : res())))
  fs.renameSync(tmp, dest)
}

function run(cmd, args, log) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { env: env(), windowsHide: true })
    const onData = d => log(d.toString())
    p.stdout.on('data', onData); p.stderr.on('data', onData)
    p.on('error', reject)
    p.on('close', code => (code === 0 ? resolve() : reject(new Error(`${path.basename(cmd)} exited with code ${code}`))))
  })
}

/** Installs whatever is missing. `log` gets progress text. */
async function install(log) {
  if (!isWin) {
    const brew = find('brew')
    if (!brew) throw new Error('Install Homebrew from brew.sh first, then run: brew install yt-dlp ffmpeg')
    log('$ brew install yt-dlp ffmpeg\n')
    return run(brew, ['install', 'yt-dlp', 'ffmpeg'], log)
  }
  const dir = toolsDir()
  fs.mkdirSync(dir, { recursive: true })
  if (!find('yt-dlp')) {
    log('Downloading yt-dlp…\n')
    await download(YTDLP_URL, path.join(dir, 'yt-dlp.exe'), p => log(p >= 0 ? `  yt-dlp ${p}%\n` : ''))
  }
  if (!find('ffmpeg')) {
    log('Downloading ffmpeg (about 200 MB, this can take a few minutes)…\n')
    const zip = path.join(dir, 'ffmpeg.zip')
    await download(FFMPEG_URL, zip, p => log(p >= 0 ? `  ffmpeg ${p}%\n` : ''))
    log('Unpacking ffmpeg…\n')
    const unpack = path.join(dir, 'ffmpeg-unpack')
    fs.rmSync(unpack, { recursive: true, force: true })
    fs.mkdirSync(unpack, { recursive: true })
    // Windows 10 and 11 come with tar.exe, which reads zip files
    const tar = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe')
    await run(fs.existsSync(tar) ? tar : 'tar', ['-xf', zip, '-C', unpack], log)
    const bin = findFile(unpack, 'ffmpeg.exe')
    if (!bin) throw new Error("ffmpeg.exe wasn't in the download")
    for (const name of ['ffmpeg.exe', 'ffprobe.exe']) {
      const src = path.join(path.dirname(bin), name)
      if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dir, name))
    }
    fs.rmSync(unpack, { recursive: true, force: true })
    fs.rmSync(zip, { force: true })
  }
  log('Done.\n')
}

function findFile(dir, name) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) { const hit = findFile(p, name); if (hit) return hit }
    else if (e.name.toLowerCase() === name) return p
  }
  return null
}

/** Gets the newest yt-dlp (fixes most download errors after YouTube changes something). */
async function updateYtDlp(log) {
  if (!isWin) {
    const brew = find('brew')
    if (!brew) throw new Error('Homebrew not found')
    log('$ brew upgrade yt-dlp\n')
    return run(brew, ['upgrade', 'yt-dlp'], log)
  }
  fs.mkdirSync(toolsDir(), { recursive: true })
  log('Downloading the latest yt-dlp…\n')
  await download(YTDLP_URL, path.join(toolsDir(), 'yt-dlp.exe'), p => log(p >= 0 ? `  ${p}%\n` : ''))
  log('Done.\n')
}

module.exports = { status, find, env, install, updateYtDlp, isWin }
