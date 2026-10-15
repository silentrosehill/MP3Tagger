// Official tags from Apple's catalog (iTunes Search API, no key needed). Port of Lookup.swift.
const { net } = require('electron')
const id3 = require('./id3')
const { jpegCover } = require('./images')

const year = m => (m.releaseDate || '').slice(0, 4)
const seconds = m => (m.trackTimeMillis ? m.trackTimeMillis / 1000 : null)
const trackText = m => (m.trackNumber ? (m.trackCount ? `${m.trackNumber}/${m.trackCount}` : String(m.trackNumber)) : '')
const artwork = (url, side) => (url ? url.replace('100x100bb', `${side}x${side}bb`) : null)

/** "Runaway (Video Version) ft. Pusha T" → "runaway" (keepWords keeps casing/spaces for the search term). */
function simplify(s, keepWords) {
  let t = s || ''
  t = t.replace(/\s*[([][^)\]]*[)\]]/gi, '')
  t = t.replace(/\s+(ft\.?|feat\.?|featuring|with)\s+.*$/i, '')
  t = t.replace(/\s+-\s+(remaster(ed)?|single|radio edit).*$/i, '')
  if (keepWords) return t.trim()
  return t.toLowerCase().normalize('NFC').replace(/[^\p{L}\p{N}]/gu, '')
}

/** "Kanye West, Travis Scott" / "Kanye West & Jay-Z" → "Kanye West" */
function primaryArtist(s) {
  return ((s || '').split(/[,&]/)[0] || '').replace(/\s+(x|feat\.?|ft\.?)\s+.*$/i, '').trim()
}

const cleanAlbum = s => (s || '').replace(/\s+-\s+(Single|EP)$/, '')

function overlap(a, b) {
  const grams = s => { const c = [...s]; if (c.length < 2) return new Set([s]); const g = new Set(); for (let i = 0; i < c.length - 1; i++) g.add(c[i] + c[i + 1]); return g }
  const ga = grams(a), gb = grams(b)
  let n = 0
  for (const g of ga) if (gb.has(g)) n++
  return 2 * n / (ga.size + gb.size)
}

/** 0…1+: title similarity dominates, artist must overlap, duration and "not a cover/karaoke" nudge. */
function score(m, title, artist, duration) {
  const want = simplify(title, false), got = simplify(m.trackName, false)
  if (!want || !got) return 0
  let s
  if (want === got) s = 0.7
  else if (got.startsWith(want) || want.startsWith(got)) s = 0.55
  else if (got.includes(want) || want.includes(got)) s = 0.45
  else s = 0.7 * overlap(want, got)

  const wa = simplify(artist, false), ga = simplify(m.artistName, false)
  if (wa) s += ga.includes(wa) || wa.includes(ga) || overlap(wa, ga) >= 0.5 ? 0.3 : -0.3
  else s += 0.1

  const md = seconds(m)
  if (duration && md) {
    const diff = Math.abs(duration - md)
    s += diff < 4 ? 0.1 : diff < 20 ? 0.05 : diff > 90 ? -0.1 : 0
  }
  const wantedText = (title || '').toLowerCase(), gotText = m.trackName.toLowerCase()
  for (const v of ['remix', 'live', 'slowed', 'sped up', 'acoustic', 'instrumental', 'mashup', 'edit', 'version', 'demo']) {
    if (wantedText.includes(v) !== gotText.includes(v)) s -= v === 'version' || v === 'edit' ? 0.1 : 0.35
  }
  if (wantedText.includes(' x ') && !gotText.includes(' x ')) s -= 0.35
  const junk = ['karaoke', 'tribute', 'cover', 'instrumental', 'made famous', 'originally performed']
  const all = `${m.trackName} ${m.artistName} ${m.collectionName || ''}`.toLowerCase()
  if (junk.some(j => all.includes(j)) && !wantedText.includes('instrumental')) s -= 0.4
  return s
}

async function getJSON(url) {
  const r = await net.fetch(url)
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
}

/** Top catalog matches for a title/artist, best first. */
async function search(title, artist, duration, limit = 8) {
  const term = [primaryArtist(artist), simplify(title, true)].filter(Boolean).join(' ')
  if (!term) return []
  let found
  try {
    found = (await getJSON(`https://itunes.apple.com/search?${new URLSearchParams({ term, entity: 'song', limit: '25' })}`)).results || []
  } catch { return [] }
  return found.map(m => [m, score(m, title, artist, duration)]).sort((a, b) => b[1] - a[1]).slice(0, limit).map(x => x[0])
}

async function best(title, artist, duration) {
  const top = (await search(title, artist, duration, 1))[0]
  return top && score(top, title, artist, duration) >= 0.75 ? top : null
}

async function fetchBuffer(url) {
  const r = await net.fetch(url)
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return Buffer.from(await r.arrayBuffer())
}

/** 1000 px JPEG of the match's artwork. */
async function coverData(m) {
  try { return jpegCover(await fetchBuffer(artwork(m.artworkUrl100, 1200))) } catch { return null }
}

/** Fills a tag from a match (keeps loudness info and extra frames). */
function apply(m, tag, cover) {
  tag.title = m.trackName
  tag.artist = m.artistName
  if (m.collectionName) tag.album = cleanAlbum(m.collectionName)
  tag.albumArtist = m.collectionArtistName || m.artistName
  if (year(m)) tag.year = year(m)
  if (trackText(m)) tag.track = trackText(m)
  if (m.primaryGenreName) tag.genre = m.primaryGenreName
  if (cover) { tag.cover = cover; tag.coverMime = 'image/jpeg' }
  return tag
}

/** Rewrites a downloaded song's tags and cover from a convincing match. Returns the new title or null. */
async function fillOfficialTags(file, duration) {
  let tag
  try { tag = id3.read(file) } catch { return null }
  const title = tag.title || require('path').parse(file).name
  const m = await best(title, tag.artist, duration)
  if (!m) return null
  apply(m, tag, await coverData(m))
  try { id3.write(tag, file, file) } catch { return null }
  return tag.title
}

/** Albums for the cover search. */
async function searchAlbums(query) {
  const term = query.replace(/\bcover\b/gi, '').trim()
  const r = await getJSON(`https://itunes.apple.com/search?${new URLSearchParams({ term, entity: 'album', limit: '40' })}`)
  return (r.results || []).map(a => ({ id: a.collectionId, name: a.collectionName, artist: a.artistName, art: a.artworkUrl100 }))
}

/** Plain objects for the renderer. */
const forUI = m => ({
  id: m.trackId, title: m.trackName, artist: m.artistName, album: m.collectionName ? cleanAlbum(m.collectionName) : '',
  year: year(m), seconds: seconds(m), thumb: artwork(m.artworkUrl100, 120), raw: m,
})

module.exports = { search, best, apply, coverData, fillOfficialTags, searchAlbums, simplify, primaryArtist, forUI, fetchBuffer, artwork }
