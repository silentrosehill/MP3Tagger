"""Collect battery levels for wireless devices on macOS.

Three sources are combined:

* ``system_profiler SPBluetoothDataType`` - Bluetooth devices that report
  battery to macOS (AirPods, Beats, many BLE mice/keyboards/headphones,
  game controllers...). AirPods-style devices report Left/Right/Case.
* ``ioreg`` - HID devices exposing ``BatteryPercent`` (Apple Magic
  Keyboard / Mouse / Trackpad and some others).
* ``headsetcontrol`` - USB-dongle gaming headsets (SteelSeries Arctis,
  Logitech G, Corsair, HyperX...). Install with ``brew install headsetcontrol``.

Run this file directly to print what was found:  ``python3 sources.py``
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

SOURCE_BLUETOOTH = "Bluetooth"
SOURCE_HID = "Apple HID"
SOURCE_DONGLE = "USB dongle"


@dataclass
class Device:
    name: str
    level: Optional[int]          # 0-100, or None if unknown / device off
    source: str
    kind: str = ""                # e.g. "Headphones", "Mouse", "Keyboard"
    detail: str = ""              # e.g. "Left", "Case", "Off"
    charging: bool = False

    @property
    def label(self) -> str:
        return f"{self.name} ({self.detail})" if self.detail else self.name


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _run(cmd: List[str], timeout: float = 15) -> Optional[bytes]:
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 and not proc.stdout:
        return None
    return proc.stdout


def _parse_percent(value) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        n = int(value)
    else:
        text = str(value).strip().rstrip("%").strip()
        try:
            n = int(float(text))
        except ValueError:
            return None
    if n < 0:
        return None
    return max(0, min(100, n))


def find_headsetcontrol() -> Optional[str]:
    """GUI apps don't get the shell PATH, so also check Homebrew dirs."""
    found = shutil.which("headsetcontrol")
    if found:
        return found
    for path in ("/opt/homebrew/bin/headsetcontrol", "/usr/local/bin/headsetcontrol"):
        if os.access(path, os.X_OK):
            return path
    return None


# --------------------------------------------------------------------------
# system_profiler (Bluetooth)
# --------------------------------------------------------------------------

_BATTERY_PREFIX = "device_batteryLevel"


def parse_system_profiler(data: dict) -> List[Device]:
    devices: List[Device] = []
    for controller in data.get("SPBluetoothDataType", []) or []:
        for entry in controller.get("device_connected", []) or []:
            if not isinstance(entry, dict):
                continue
            for name, props in entry.items():
                if not isinstance(props, dict):
                    continue
                kind = props.get("device_minorType", "") or ""
                for key in sorted(props):
                    if not key.startswith(_BATTERY_PREFIX):
                        continue
                    level = _parse_percent(props[key])
                    if level is None:
                        continue
                    part = key[len(_BATTERY_PREFIX):]
                    detail = "" if part in ("", "Main") else part
                    devices.append(Device(name, level, SOURCE_BLUETOOTH, kind, detail))
    return devices


def read_system_profiler() -> List[Device]:
    out = _run(["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"], timeout=30)
    if not out:
        return []
    try:
        return parse_system_profiler(json.loads(out))
    except (ValueError, AttributeError):
        return []


# --------------------------------------------------------------------------
# ioreg (Apple HID: Magic Keyboard / Mouse / Trackpad ...)
# --------------------------------------------------------------------------

def _guess_kind(name: str) -> str:
    low = name.lower()
    for word, kind in (("keyboard", "Keyboard"), ("mouse", "Mouse"),
                       ("trackpad", "Trackpad"), ("controller", "Gamepad"),
                       ("headset", "Headphones"), ("headphone", "Headphones"),
                       ("airpods", "Headphones"), ("buds", "Headphones")):
        if word in low:
            return kind
    return ""


def parse_ioreg(raw: bytes) -> List[Device]:
    if not raw or not raw.strip():
        return []
    try:
        items = plistlib.loads(raw)
    except Exception:
        return []
    if isinstance(items, dict):
        items = [items]
    devices: List[Device] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("Product") or item.get("DeviceName") or item.get("Name")
        level = _parse_percent(item.get("BatteryPercent"))
        if not name or level is None:
            continue
        devices.append(Device(str(name), level, SOURCE_HID, _guess_kind(str(name))))
    return devices


def read_ioreg() -> List[Device]:
    return parse_ioreg(_run(["/usr/sbin/ioreg", "-r", "-a", "-k", "BatteryPercent"]) or b"")


# --------------------------------------------------------------------------
# headsetcontrol (USB dongle headsets, e.g. SteelSeries Arctis)
# --------------------------------------------------------------------------

def parse_headsetcontrol_json(text: str) -> List[Device]:
    data = json.loads(text)
    devices: List[Device] = []
    for dev in data.get("devices", []) or []:
        battery = dev.get("battery")
        if not isinstance(battery, dict):
            continue  # headset doesn't support battery reporting
        name = dev.get("device") or " ".join(
            p for p in (dev.get("vendor"), dev.get("product")) if p) or "Headset"
        status = str(battery.get("status", "")).upper()
        level = _parse_percent(battery.get("level"))
        if status == "BATTERY_UNAVAILABLE":
            devices.append(Device(name, None, SOURCE_DONGLE, "Headphones", "Off"))
            continue
        devices.append(Device(name, level, SOURCE_DONGLE, "Headphones",
                              charging=status == "BATTERY_CHARGING"))
    return devices


def parse_headsetcontrol_compact(text: str) -> List[Device]:
    """Output of older ``headsetcontrol -b -c``: a number, -1 = charging,
    -2 = unavailable/off."""
    try:
        n = int(text.strip().splitlines()[0])
    except (ValueError, IndexError):
        return []
    if n == -1:
        return [Device("Headset", None, SOURCE_DONGLE, "Headphones", charging=True)]
    if n == -2:
        return [Device("Headset", None, SOURCE_DONGLE, "Headphones", "Off")]
    return [Device("Headset", _parse_percent(n), SOURCE_DONGLE, "Headphones")]


def read_headsetcontrol() -> List[Device]:
    exe = find_headsetcontrol()
    if not exe:
        return []
    out = _run([exe, "-b", "-o", "json"])  # HeadsetControl 3.x
    if out:
        try:
            return parse_headsetcontrol_json(out.decode("utf-8", "replace"))
        except (ValueError, AttributeError):
            pass
    out = _run([exe, "-b", "-c"])          # HeadsetControl 2.x fallback
    return parse_headsetcontrol_compact(out.decode("utf-8", "replace")) if out else []


# --------------------------------------------------------------------------

def merge(*groups: List[Device]) -> List[Device]:
    """Combine sources; the same device can show up in more than one."""
    seen = set()
    result: List[Device] = []
    for group in groups:
        for dev in group:
            key = (dev.name.strip().lower(), dev.detail.lower())
            if key in seen:
                continue
            seen.add(key)
            result.append(dev)
    return result


def read_all() -> List[Device]:
    return merge(read_headsetcontrol(), read_system_profiler(), read_ioreg())


if __name__ == "__main__":
    found = read_all()
    if not found:
        print("No devices reporting battery were found.")
        if not find_headsetcontrol():
            print("Tip: `brew install headsetcontrol` for USB-dongle headsets.")
    for d in found:
        pct = "--" if d.level is None else f"{d.level}%"
        extra = " (charging)" if d.charging else ""
        print(f"{d.label:40} {pct:>5}{extra}   [{d.source}]")
