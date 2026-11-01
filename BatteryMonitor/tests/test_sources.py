import json
import os
import plistlib
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import sources  # noqa: E402


class SystemProfilerTests(unittest.TestCase):
    def test_parses_main_and_airpods_parts(self):
        data = {"SPBluetoothDataType": [{
            "controller_properties": {"controller_address": "x"},
            "device_connected": [
                {"AirPods Pro": {"device_minorType": "Headphones",
                                 "device_batteryLevelLeft": "80%",
                                 "device_batteryLevelRight": "75%",
                                 "device_batteryLevelCase": "50%"}},
                {"MX Master 3": {"device_minorType": "Mouse",
                                 "device_batteryLevelMain": "60%"}},
                {"Speaker": {"device_minorType": "Speaker"}},
            ],
            "device_not_connected": [
                {"Old": {"device_batteryLevelMain": "10%"}},
            ],
        }]}
        devs = sources.parse_system_profiler(data)
        labels = {d.label: d.level for d in devs}
        self.assertEqual(labels, {
            "AirPods Pro (Case)": 50, "AirPods Pro (Left)": 80,
            "AirPods Pro (Right)": 75, "MX Master 3": 60,
        })

    def test_empty(self):
        self.assertEqual(sources.parse_system_profiler({}), [])


class IoregTests(unittest.TestCase):
    def test_parses_plist_array(self):
        raw = plistlib.dumps([
            {"Product": "Magic Keyboard", "BatteryPercent": 42},
            {"Product": "No battery"},
        ])
        devs = sources.parse_ioreg(raw)
        self.assertEqual(len(devs), 1)
        self.assertEqual((devs[0].name, devs[0].level, devs[0].kind),
                         ("Magic Keyboard", 42, "Keyboard"))

    def test_empty_output(self):
        self.assertEqual(sources.parse_ioreg(b""), [])
        self.assertEqual(sources.parse_ioreg(b"garbage"), [])


class HeadsetControlTests(unittest.TestCase):
    def _json(self, battery):
        dev = {"status": "success", "device": "SteelSeries Arctis Nova 7",
               "vendor": "SteelSeries", "product": "Arctis Nova 7"}
        if battery is not None:
            dev["battery"] = battery
        return json.dumps({"name": "HeadsetControl", "device_count": 1, "devices": [dev]})

    def test_available(self):
        d, = sources.parse_headsetcontrol_json(
            self._json({"status": "BATTERY_AVAILABLE", "level": 85}))
        self.assertEqual((d.name, d.level, d.charging), ("SteelSeries Arctis Nova 7", 85, False))

    def test_charging(self):
        d, = sources.parse_headsetcontrol_json(
            self._json({"status": "BATTERY_CHARGING", "level": 40}))
        self.assertTrue(d.charging)
        self.assertEqual(d.level, 40)

    def test_off(self):
        d, = sources.parse_headsetcontrol_json(
            self._json({"status": "BATTERY_UNAVAILABLE", "level": -1}))
        self.assertIsNone(d.level)
        self.assertEqual(d.detail, "Off")

    def test_no_battery_capability(self):
        self.assertEqual(sources.parse_headsetcontrol_json(self._json(None)), [])

    def test_compact(self):
        self.assertEqual(sources.parse_headsetcontrol_compact("77\n")[0].level, 77)
        self.assertTrue(sources.parse_headsetcontrol_compact("-1")[0].charging)
        self.assertEqual(sources.parse_headsetcontrol_compact("-2")[0].detail, "Off")
        self.assertEqual(sources.parse_headsetcontrol_compact(""), [])


class MergeTests(unittest.TestCase):
    def test_dedupes_by_name_and_part(self):
        a = sources.Device("Magic Mouse", 50, sources.SOURCE_BLUETOOTH)
        b = sources.Device("magic mouse", 51, sources.SOURCE_HID)
        c = sources.Device("AirPods", 10, sources.SOURCE_BLUETOOTH, detail="Left")
        merged = sources.merge([a, c], [b])
        self.assertEqual(merged, [a, c])


if __name__ == "__main__":
    unittest.main()
