# MP3 Tagger

hi i made claude make me a mac os mp3 tagger, mostly for spotify, look the screenshot to see how it looks like

## Features

**Tag editing**
- Edit title, artist, album, album artist, year, track number, genre and cover art
- Saves as ID3v2.3, the version Spotify's local files read best
- Drag and drop songs or whole folders; Save, Save As, and Save All to a folder
- "Apply Album & Cover to All" for tagging a whole album at once

**Cover art**
- Drag an image onto the cover, or pick one from a file
- Built-in search: official album art from Apple's catalog, or web image search (right-click → Use as Cover Art)
- Liquid glass "pour" animation when the cover changes

**Loudness**
- Measures loudness in LUFS (the EBU R128 / BS.1770 method)
- "Match Spotify" sets songs to −14 LUFS, like Spotify plays them, or adjust in ±1.5 dB steps
- Lossless (MP3Gain-style): the audio isn't re-encoded, and Reset restores the original exactly

**Playback**
- Picture-in-picture mini player: drag it anywhere, it snaps to the corners
- A spinning vinyl record (33⅓ RPM) or CD (real CD speed, Yeezus-style reflections) slides out from behind the cover
- Play/pause, song position slider, slide-out volume with mute, and a ✕ to close

**Download**
- Paste a video link and get a tagged MP3 (uses yt-dlp and ffmpeg from Homebrew; install/update from the app)
- In-app YouTube browser with a built-in ad blocker; stays signed in
- Automatic cover, title cleanup and optional Spotify loudness matching
- Downloaded songs stay in the Files list across launches

**History and changelog**
- History tab of every song you saved; click a cover to play it
- Changelog tab listing every version

**Themes**
- Liquid Glass style with 9 color presets, a custom color, sidebar tint, or colors that match the album cover
- Mavericks style: an OS X 10.9-inspired skeuomorphic look with the same layout
- Theme picker also switches the player disc between vinyl and CD

![Files](Screenshots/files.png)
![History](Screenshots/history.png)
![Download](Screenshots/download.png)
![Theme and mini player](Screenshots/theme.png)

## Build and install

```bash
./build.sh
ditto "MP3 Tagger.app" "/Applications/MP3 Tagger.app"
```

Needs only the Xcode Command Line Tools (`xcode-select --install`). The downloader also needs
`yt-dlp` and `ffmpeg` (`brew install yt-dlp ffmpeg`, or the Install button in the app's Download tab).

## Layout

- `Sources/` — the app (SwiftUI). `ID3.swift` reads/writes tags, `Loudness.swift` measures and adjusts volume.
- `Icon/` — icon drawing scripts (`make_icon_v3.swift` is the current icon) and the `.icns` files.
- `CHANGELOG.md` — every version; bundled into the app's Changelog tab.
