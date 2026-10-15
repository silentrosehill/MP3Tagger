// Checks GitHub for a newer release (at launch at most once a day, or from the ⓘ panel).
const { net, app } = require('electron')
const { settings } = require('./store')

const REPO = 'silentrosehill/MP3Tagger'

/** "3.10.0" > "3.9.2" (numeric, part by part). */
function isNewer(a, b) {
  const x = a.split('.').map(n => parseInt(n, 10) || 0), y = b.split('.').map(n => parseInt(n, 10) || 0)
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const p = x[i] || 0, q = y[i] || 0
    if (p !== q) return p > q
  }
  return false
}

/** Returns {title, message, url?, version?} to show, or null when there's nothing to say. */
async function check(manual) {
  if (!manual) {
    const last = settings.get('updateLastCheck', 0)
    if (Date.now() - last < 24 * 3600 * 1000) return null
  }
  settings.set('updateLastCheck', Date.now())
  const current = app.getVersion()
  let rel
  try {
    const r = await net.fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    if (!r.ok) throw new Error()
    rel = await r.json()
  } catch {
    return manual ? { title: "Couldn't check for updates", message: "GitHub didn't answer. Check your connection and try again." } : null
  }
  const latest = String(rel.tag_name || '').replace(/^[vV]/, '')
  if (isNewer(latest, current)) {
    if (!manual && settings.get('updateSkipped') === latest) return null
    return { title: `MP3 Tagger ${latest} is available`, version: latest, url: rel.html_url,
      message: `You have ${current}. Download the Windows zip from GitHub, unzip it and replace your MP3 Tagger folder.` }
  }
  return manual ? { title: "You're up to date", message: `MP3 Tagger ${current} is the latest version.` } : null
}

module.exports = { check, skip: v => settings.set('updateSkipped', v) }
