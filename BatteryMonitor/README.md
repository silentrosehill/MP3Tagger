# Battery Monitor (macOS)

A menu bar app that shows the battery % of your wireless devices:

| Device type | How it's read |
|---|---|
| USB-dongle headsets (SteelSeries Arctis / Arctis Nova, Logitech G, Corsair, HyperX…) | [HeadsetControl](https://github.com/Sapd/HeadsetControl) |
| Bluetooth headphones, AirPods (left/right/case), mice, keyboards, controllers | `system_profiler SPBluetoothDataType` |
| Apple Magic Keyboard / Mouse / Trackpad | `ioreg` (`BatteryPercent`) |

The menu bar shows the **lowest** battery level. Click it to see every device.
You get a notification when a device drops to 20% or below. The app refreshes every 60 seconds, or right away with *Refresh Now*.

## Setup

```bash
brew install headsetcontrol      # needed for the SteelSeries dongle headset
pip3 install -r requirements.txt
```

Check that your devices are detected:

```bash
python3 sources.py
headsetcontrol -b                # should print your headset's battery
```

Run the app:

```bash
python3 app.py
```

### Make it a real .app (optional)

```bash
pip3 install py2app
python3 setup.py py2app
```

Drag `dist/Battery Monitor.app` into Applications. To start it automatically, add it under
System Settings → General → Login Items.

## Notes

- The headset must be turned on and its dongle plugged in. When it's off, it shows "off / unavailable".
- If `headsetcontrol` says your headset isn't supported, check its
  [supported devices list](https://github.com/Sapd/HeadsetControl#supported-headsets).
- A Bluetooth device only shows up if it reports battery to macOS. Some cheaper ones don't.
- Tests: `python3 -m unittest discover -s tests`
