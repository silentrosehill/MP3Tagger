# MP3 Tagger — Changelog

Version numbers: minor = a new feature, patch = a fix. The build number counts every update.

## 3.19.0 (build 55)
- Undo and Redo (⌘Z / ⇧⌘Z) for changes you haven't saved yet: tags, cover, Official Tags, loudness and trim. Typing in a field counts as one step, and the Edit menu says what will be undone. Saving starts fresh.

## 3.18.0 (build 54)
- Trim: cut the talking intro or outro of a song, losslessly (whole MP3 frames, no re-encoding). Play the song and click Here at the right moment, or nudge by 0.5 s, then preview with ▶︎. It applies when you save, and Save As keeps the original. The song's length info and LAME/Xing header are updated so players show the right duration.

## 3.17.0 (build 53)
- Queue: when a song ends, the next one in the list you started it from (Files or History) plays.
- Mini player: ⏮ and ⏭ buttons. ⏮ restarts the song, or goes back one if it only just started.
- Keyboard: Space = play/pause (or plays the selected song), ← / → = previous / next. These are ignored while you're typing. There's also a new Playback menu (⌘← / ⌘→).

## 3.16.0 (build 52)
- Update check: once a day the app asks GitHub whether there's a newer release and offers to download it ("Later" skips that version). You can also check any time from MP3 Tagger menu → Check for Updates….

## 3.15.0 (build 51)
- Rename from tags: turn a messy file name into "Artist - Title.mp3". Click the link under the file path, or right-click a song → Rename from Tags / Rename All from Tags. History, downloads and the player follow the new name. Name clashes become "… 2.mp3".

## 3.14.0 (build 50)
- Official tags: downloads (Auto and Download) are looked up in Apple Music's catalog, and on a clear match they get the official title, artist, album, album artist, year, track number, genre and a high-res cover. Remixes, mashups, slowed versions and unclear matches are left alone. You can turn this off in the Download tab.
- Editor: a new ✨ Official Tags button to pick the right song from Apple Music and fill everything in.

## 3.13.0 (build 49)
- New ⓘ button next to the theme button: it explains what each tab, the mini player and the theme do. Click a tab in it to jump there.

## 3.12.0 (build 48)
- Match album cover: when no song is selected (empty Files or History, Auto, Download, Changelog), the colors follow the song playing in the mini player. They go back to your theme when you close the player.

## 3.11.0 (build 47)
- Mini player: a Dynamic Island-style audio visualizer next to the song title. Six bars move with the song's real bass, mids and treble, in the album cover's colors, and settle into dots when paused.

## 3.10.1 (build 46)
- The Find tab is now a full tab called Auto, and Download is now an icon tab (⬇︎) next to it.

## 3.10.0 (build 45)
- Find tab: click a thumbnail to hear the first 30 seconds of that result, with a progress ring and a stop button. Click again (or pick another) to stop. It follows the app's volume and pauses your own song.

## 3.9.0 (build 44)
- New Find tab (🔍 next to Download): type a song and artist to see YouTube matches with their thumbnail, length, channel and views.
- Pick one and it downloads (with tag cleanup and Spotify loudness), then opens straight in the editor so you can fix the cover and tags.

## 3.8.2 (build 43)
- Fix: the window can't be made smaller than 1045 × 607, so the layout never gets squeezed.

## 3.8.1 (build 41)
- Fix: the CD reflections stay put with the light again, like in 3.6.0. They only shimmer and wobble a little and keep the Yeezus colours. The disc still spins at real CD speed underneath.

## 3.8.0 (build 40)
- The mini player has a small ✕ in its top-right corner. It stops the song and closes the player.

## 3.7.1 (build 39)
- The CD now looks like the Yeezus disc: bold white and icy-blue wedges against dark brown-black ones, with green, cyan, orange and yellow fringes where they meet. A thin cyan streak and white glints drift around it.
- A black ring around a clear plastic hub, a clear rim, and a ring of small print near the edge.

## 3.7.0 (build 38)
- Wider mini player. Play/pause now sits left of the time bar and volume sits right of it. The stop button is gone.
- The CD spins at real audio-CD speed: about 500 RPM at the start of a song, slowing down as it plays, the way a real disc does.
- New Yeezus-style CD reflections: chrome white with a faint icy blue, pink and gold sheen instead of a rainbow. They turn with the disc, drift around and fade in and out.

## 3.6.0 (build 37)
- Theme → Player disc: choose a vinyl record or a CD. The CD shows real-looking rainbow reflections that stay with the light and shimmer as it spins.

## 3.5.0 (build 36)
- Mini player: volume is now an icon under the pause button; click it to slide out a horizontal volume slider (with mute). It tucks away after a few seconds.

## 3.4.2 (build 35)
- Fix: switching from Mavericks back to Liquid Glass left the sidebar and main area stuck in light mode.

## 3.4.1 (build 34)
- The app icon now shows next to the app name in the toolbar.

## 3.4.0 (build 33)
- New app icon: a clear vinyl record on black, with a tag tied to the centre hole.

## 3.3.0 (build 32)
- Bigger mini player (320×130) with twice-as-large cover art.
- A vinyl record slides out from behind the cover when playing and spins at 33⅓ RPM in step with the song; it stops and slides back in on pause.
- Fix: titles that overflow by less than a point now scroll instead of being cut off with "…".

## 3.2.1 (build 31)
- Mini player: volume is now a vertical slider on the left (louder at the top), with mute underneath.

## 3.2.0 (build 30)
- New Mavericks style (Theme → Style): OS X 10.9-inspired skeuomorphic look — Aqua buttons, classic segmented control, source-list sidebar, iTunes-style LCD mini player, bevelled panels, framed covers. Same layout as Liquid Glass.

## 3.1.0 (build 29)
- Song position slider in the mini player (under volume): elapsed / remaining time, drag to skip through.
- Long titles in the Files, History and Download lists scroll when you hover over or select a song.

## 3.0.0 (build 28)
- Performance: loudness measuring rewritten with Accelerate — 797 ms → 350 ms per song, and instant when reopening a song (results are remembered).
- Performance: sidebar covers use cached thumbnails — 5.8 ms → 0.09 ms per redraw, so scrolling and the volume slider stay smooth.
- Performance: the volume slider no longer redraws every song row; faster duplicate checks when adding big folders; optimized build.
- Fix: quitting the app now stops any running downloads (yt-dlp no longer keeps running in the background).

## 2.5.0 (build 27)
- Changelog tab in the app (the list icon next to Download).

## 2.4.1 (build 26)
- Fix: clicking into a field no longer marks the song as having unsaved changes.

## 2.4.0 (build 25)
- New app icon: purple Liquid Glass with a download badge.
- Version shown in the window title and About window.

## 2.3.0 (24)
- Loudness card in the editor: measure (LUFS), Match Spotify (−14 LUFS), ±1.5 dB, Reset.
- Lossless, exactly reversible volume change (MP3Gain-style); downloads can auto-match Spotify loudness.

## 2.2.0 (23)
- Songs downloaded in the app always appear in Files, across launches, with a ⬇︎ badge; Remove from List.

## 2.1.0 (22)
- In-app YouTube browser (click the empty link box); Download Audio button and right-click menu.
- Built-in ad blocker; stay signed in between launches.

## 2.0.0 (21)
- Download tab: video link → tagged MP3 (yt-dlp + ffmpeg via Homebrew), progress, cancel, auto cover and title cleanup.

## 1.11.0 (20)
- Theme can follow the album cover being viewed ("Match album cover").

## 1.10.1 (19)
- Fix: saving in protected folders (Downloads/Desktop/Documents) no longer fails with a permission error.

## 1.10.0 (18)
- Theme picker: 9 presets, custom color, sidebar tint strength.

## 1.9.1 (17)
- Narrower mini player; long titles scroll.

## 1.9.0 (16)
- Picture-in-picture mini player: drag it anywhere, snaps to corners.

## 1.8.0 (15)
- Now Playing bar with volume slider and mute.

## 1.7.3 (14)
- Fix: status bar no longer covers the sidebar's Clear History button.

## 1.7.2 (13)
- Toolbar buttons back to standard macOS Liquid Glass.

## 1.7.1 (12)
- Cover buttons (search web, choose image, remove) are now icons.

## 1.7.0 (11)
- Purple glass theme: tinted translucent sidebar, glass buttons and switch.

## 1.6.0 (10)
- Cover search: official album art (Apple's catalog) and in-app web image search.

## 1.5.0 (9)
- Save… lets you choose where to save (Save As); Save All… saves to a folder.

## 1.4.0 (8)
- History tab of saved songs; click a cover to play.

## 1.3.0 (7)
- Translucent sidebar.

## 1.2.0 (6)
- Liquid glass "pour" animation when the cover changes.

## 1.1.x (2–5)
- App icon, then Liquid Glass icon variants (green, purple).

## 1.0.0 (1)
- MP3 tag editor: title, artist, album, album artist, year, track, genre, cover art (ID3v2.3 for Spotify).
