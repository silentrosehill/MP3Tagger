"""Menu bar app that shows the battery level of your wireless devices.

Run:  python3 app.py
"""

from __future__ import annotations

import subprocess
import threading
from typing import Dict, List, Optional

import rumps

import sources
from sources import Device

REFRESH_SECONDS = 60
LOW_BATTERY = 20        # notify at or below this %
LOW_BATTERY_RESET = 30  # notify again only after going back above this %

KIND_ICONS = {
    "headphones": "🎧", "headset": "🎧", "speaker": "🔊",
    "mouse": "🖱", "trackpad": "🖱", "keyboard": "⌨️",
    "gamepad": "🎮", "game controller": "🎮",
}


def icon_for(dev: Device) -> str:
    return KIND_ICONS.get(dev.kind.lower(), "🔋")


def describe(dev: Device) -> str:
    if dev.level is None:
        state = "charging" if dev.charging else "off / unavailable"
    else:
        state = f"{dev.level}%" + (" ⚡" if dev.charging else "")
    return f"{icon_for(dev)}  {dev.label} — {state}"


def notify(title: str, message: str) -> None:
    # osascript works without a bundled app (rumps.notification needs one).
    esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.Popen(["osascript", "-e",
                      f'display notification "{esc(message)}" with title "{esc(title)}"'])


class BatteryApp(rumps.App):
    def __init__(self) -> None:
        super().__init__("Battery Monitor", title="🔋 …", quit_button=None)
        self._lock = threading.Lock()
        self._pending: Optional[List[Device]] = None
        self._busy = False
        self._low_notified: Dict[str, bool] = {}
        self.menu = [rumps.MenuItem("Looking for devices…")]

        # Results are collected on a worker thread and applied on the main
        # thread (AppKit menus must only be touched from the main thread).
        rumps.Timer(self._apply_pending, 1).start()
        rumps.Timer(self._refresh, REFRESH_SECONDS).start()
        self._refresh(None)

    # -- data collection ---------------------------------------------------
    def _refresh(self, _sender) -> None:
        with self._lock:
            if self._busy:
                return
            self._busy = True
        threading.Thread(target=self._worker, daemon=True).start()

    def _worker(self) -> None:
        try:
            devices = sources.read_all()
        except Exception as exc:  # never let the menu bar app die
            print("battery read failed:", exc)
            devices = []
        with self._lock:
            self._pending = devices
            self._busy = False

    # -- UI ------------------------------------------------------------------
    def _apply_pending(self, _sender) -> None:
        with self._lock:
            devices, self._pending = self._pending, None
        if devices is None:
            return
        self._update_title(devices)
        self._rebuild_menu(devices)
        self._check_low(devices)

    def _update_title(self, devices: List[Device]) -> None:
        known = [d for d in devices if d.level is not None]
        if not known:
            self.title = "🔋 –"
            return
        lowest = min(known, key=lambda d: d.level)
        self.title = f"{icon_for(lowest)} {lowest.level}%"

    def _rebuild_menu(self, devices: List[Device]) -> None:
        self.menu.clear()
        items: list = []
        if not devices:
            items.append(rumps.MenuItem("No devices reporting battery"))
        for source in (sources.SOURCE_DONGLE, sources.SOURCE_BLUETOOTH, sources.SOURCE_HID):
            group = [d for d in devices if d.source == source]
            if not group:
                continue
            if items:
                items.append(rumps.separator)
            items.append(rumps.MenuItem(source.upper()))
            items.extend(rumps.MenuItem(describe(d)) for d in group)
        if not sources.find_headsetcontrol():
            items += [rumps.separator,
                      rumps.MenuItem("Dongle headsets: run `brew install headsetcontrol`")]
        items += [rumps.separator,
                  rumps.MenuItem("Refresh Now", callback=self._refresh, key="r"),
                  rumps.MenuItem("Quit", callback=rumps.quit_application, key="q")]
        self.menu.update(items)

    def _check_low(self, devices: List[Device]) -> None:
        for d in devices:
            if d.level is None or d.charging:
                continue
            key = d.label
            if d.level <= LOW_BATTERY and not self._low_notified.get(key):
                self._low_notified[key] = True
                notify("Low battery", f"{d.label} is at {d.level}%")
            elif d.level > LOW_BATTERY_RESET:
                self._low_notified[key] = False


def _hide_dock_icon() -> None:
    try:
        from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
        NSApplication.sharedApplication().setActivationPolicy_(
            NSApplicationActivationPolicyAccessory)
    except Exception:
        pass


if __name__ == "__main__":
    _hide_dock_icon()
    BatteryApp().run()
