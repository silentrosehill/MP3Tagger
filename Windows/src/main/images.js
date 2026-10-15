const { nativeImage } = require('electron')

/**
 * Crops to a centred square, scales to at most `maxSide` and encodes as JPEG — the format/size combo
 * Spotify shows reliably for local files. Returns null if the image can't be read.
 */
function jpegCover(buf, maxSide = 1000) {
  const img = nativeImage.createFromBuffer(Buffer.from(buf))
  if (img.isEmpty()) return null
  const { width, height } = img.getSize()
  const side = Math.min(width, height)
  let sq = img.crop({ x: Math.floor((width - side) / 2), y: Math.floor((height - side) / 2), width: side, height: side })
  const out = Math.min(side, maxSide)
  if (out !== side) sq = sq.resize({ width: out, height: out, quality: 'best' })
  return sq.toJPEG(90)
}

module.exports = { jpegCover }
