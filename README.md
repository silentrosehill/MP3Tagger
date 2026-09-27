# MP3 Tagger

hi i made claude make me a mac os mp3 tagger, mostly for spotify, look the screenshot to see how it looks like

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
