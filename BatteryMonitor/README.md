# Battery Monitor

A menu bar app for macOS that shows the battery % of your wireless devices. Click the icon in the menu bar to see every device with a battery bar.

| Device type | How it's read |
|---|---|
| USB-dongle headsets (SteelSeries Arctis / Arctis Nova, Logitech G, Corsair, HyperX…) | [HeadsetControl](https://github.com/Sapd/HeadsetControl) |
| Razer wireless mice with a USB dongle (Viper Ultimate, DeathAdder V2 Pro, Basilisk Ultimate…) | Razer's own protocol, read directly (no Synapse needed) |
| Bluetooth headphones, AirPods (left / right / case), mice, keyboards, controllers | macOS Bluetooth info (`system_profiler`) |
| Apple Magic Keyboard / Mouse / Trackpad | `ioreg` (`BatteryPercent`) |

- The menu bar shows the device with the **lowest** battery.
- You get a notification when a device drops to 20%.
- Refreshes every minute, and whenever you click Refresh (⌘R).
- "Open at Login" switch built in.
- Lives in the menu bar only (no Dock icon).

## Install

You need the Xcode Command Line Tools (`xcode-select --install`), same as for MP3 Tagger.

For the SteelSeries / USB-dongle headset, also install HeadsetControl:

```bash
brew install sapd/headsetcontrol/headsetcontrol
```

Then build the app and put it in Applications:

```bash
./build.sh install
```

`./build.sh` on its own just builds `Battery Monitor.app` in this folder.

Built for macOS 14 or newer.

## Notes

- Something missing? Run this in Terminal and send the output to Claude:
  `"/Applications/Battery Monitor.app/Contents/MacOS/BatteryMonitor" --debug`

- The headset has to be on and its dongle plugged in, or it shows "Off".
- If the headset doesn't show up, run `headsetcontrol -b` in Terminal. If that doesn't show a battery level, HeadsetControl doesn't support that model yet
  ([supported headsets](https://github.com/Sapd/HeadsetControl#supported-headsets)).
- A Bluetooth device only shows up if it reports its battery to macOS. Some cheaper ones don't.
- `Icon/make_icon.swift` draws the icon. Delete `Icon/AppIcon.icns` and rebuild to redraw it.
