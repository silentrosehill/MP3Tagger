import Foundation

/// Where a battery reading came from (also the order sections appear in the menu).
enum DeviceSource: String, CaseIterable, Sendable {
    case dongle = "USB Dongle"
    case bluetooth = "Bluetooth"
    case hid = "Apple Accessories"
}

struct Device: Hashable, Sendable {
    var name: String
    var level: Int?          // 0–100, nil = unknown / turned off
    var source: DeviceSource
    var kind = ""            // "Headphones", "Mouse", "Keyboard"…
    var detail = ""          // "Left", "Right", "Case", "Off"
    var charging = false

    /// "Off" / "Asleep" describe the state, not a part like AirPods' "Left": show them as the status.
    private var detailIsState: Bool { level == nil && !charging && !detail.isEmpty }

    var label: String { detail.isEmpty || detailIsState ? name : "\(name) (\(detail))" }
    var isLow: Bool { (level ?? 100) <= lowBatteryLevel && !charging }

    var statusText: String {
        if let level { return "\(level)%" }
        if charging { return "Charging" }
        return detail.isEmpty ? "Off" : detail
    }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods") { return detail == "Case" ? "airpods.chargingcase" : "airpods" }
        switch kind.lowercased() {
        case "headphones", "headset": return "headphones"
        case "mouse": return "computermouse"
        case "keyboard": return "keyboard"
        case "trackpad": return "hand.point.up.left"
        case "gamepad", "game controller", "joystick": return "gamecontroller"
        case "speaker": return "hifispeaker"
        default: return "battery.100"
        }
    }
}

let lowBatteryLevel = 20

/// Reads battery levels from HeadsetControl, Razer mice, and what macOS itself reports.
/// Everything here is blocking: call it off the main thread.
enum DeviceReader {
    static func readAll() -> [Device] {
        merge(readHeadsetControl(), RazerReader.read(), readSystemProfiler(), readIORegistry())
    }

    /// The same device can show up in more than one source; keep the first.
    static func merge(_ groups: [Device]...) -> [Device] {
        var seen = Set<String>()
        var result: [Device] = []
        for dev in groups.joined() {
            let key = dev.name.trimmingCharacters(in: .whitespaces).lowercased() + "|" + dev.detail.lowercased()
            if seen.insert(key).inserted { result.append(dev) }
        }
        return result
    }

    // MARK: Bluetooth (system_profiler)

    static func readSystemProfiler() -> [Device] {
        guard let data = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 30) else { return [] }
        return parseSystemProfiler(data)
    }

    static func parseSystemProfiler(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let prefix = "device_batteryLevel"
        var devices: [Device] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let kind = props["device_minorType"] as? String ?? ""
                    for key in props.keys.sorted() where key.hasPrefix(prefix) {
                        guard let level = percent(props[key]) else { continue }
                        let part = String(key.dropFirst(prefix.count))
                        devices.append(Device(name: name, level: level, source: .bluetooth, kind: kind,
                                              detail: part == "Main" ? "" : part))
                    }
                }
            }
        }
        return devices
    }

    // MARK: Apple HID accessories (ioreg BatteryPercent)

    static func readIORegistry() -> [Device] {
        guard let data = run("/usr/sbin/ioreg", ["-r", "-a", "-k", "BatteryPercent"]) else { return [] }
        return parseIORegistry(data)
    }

    static func parseIORegistry(_ data: Data) -> [Device] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        let items = plist as? [[String: Any]] ?? (plist as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            guard let name = (item["Product"] ?? item["DeviceName"]) as? String,
                  let level = percent(item["BatteryPercent"]) else { return nil }
            return Device(name: name, level: level, source: .hid, kind: guessKind(name))
        }
    }

    static func guessKind(_ name: String) -> String {
        let n = name.lowercased()
        for (word, kind) in [("keyboard", "Keyboard"), ("mouse", "Mouse"), ("trackpad", "Trackpad"),
                             ("controller", "Gamepad"), ("headset", "Headphones"), ("headphone", "Headphones")]
        where n.contains(word) { return kind }
        return ""
    }

    // MARK: USB-dongle headsets (HeadsetControl, e.g. SteelSeries Arctis)

    /// Apps don't get the Terminal's PATH, so look in Homebrew's folders directly.
    static func headsetControlPath() -> String? {
        ["/opt/homebrew/bin/headsetcontrol", "/usr/local/bin/headsetcontrol"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func readHeadsetControl() -> [Device] {
        guard let exe = headsetControlPath() else { return [] }
        if let data = run(exe, ["-b", "-o", "json"]), let devices = parseHeadsetControlJSON(data) {
            return devices                                   // HeadsetControl 3.x
        }
        guard let data = run(exe, ["-b", "-c"]) else { return [] }  // HeadsetControl 2.x
        return parseHeadsetControlCompact(String(decoding: data, as: UTF8.self))
    }

    /// nil = not valid JSON (older HeadsetControl).
    static func parseHeadsetControlJSON(_ data: Data) -> [Device]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var devices: [Device] = []
        for dev in root["devices"] as? [[String: Any]] ?? [] {
            guard let battery = dev["battery"] as? [String: Any] else { continue }  // no battery support
            let fallback = [dev["vendor"], dev["product"]].compactMap { $0 as? String }.joined(separator: " ")
            let name = dev["device"] as? String ?? (fallback.isEmpty ? "Headset" : fallback)
            let status = (battery["status"] as? String ?? "").uppercased()
            if status == "BATTERY_UNAVAILABLE" {
                devices.append(Device(name: name, level: nil, source: .dongle, kind: "Headphones", detail: "Off"))
            } else {
                devices.append(Device(name: name, level: percent(battery["level"]), source: .dongle,
                                      kind: "Headphones", charging: status == "BATTERY_CHARGING"))
            }
        }
        return devices
    }

    /// `headsetcontrol -b -c` prints a number: -1 = charging, -2 = off/unavailable.
    static func parseHeadsetControlCompact(_ text: String) -> [Device] {
        guard let line = text.split(whereSeparator: \.isNewline).first,
              let n = Int(line.trimmingCharacters(in: .whitespaces)) else { return [] }
        switch n {
        case -1: return [Device(name: "Headset", level: nil, source: .dongle, kind: "Headphones", charging: true)]
        case ..<0: return [Device(name: "Headset", level: nil, source: .dongle, kind: "Headphones", detail: "Off")]
        default: return [Device(name: "Headset", level: min(n, 100), source: .dongle, kind: "Headphones")]
        }
    }

    // MARK: Helpers

    /// "80%", 80, or 80.0 → 80. Negative / unparsable → nil.
    static func percent(_ value: Any?) -> Int? {
        var parsed: Int?
        if let i = value as? Int { parsed = i }
        else if let d = value as? Double { parsed = Int(d) }
        else if let s = value as? String {
            parsed = Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)).map { Int($0) }
        }
        guard let n = parsed, n >= 0 else { return nil }
        return min(n, 100)
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before waiting: big outputs fill the pipe
        p.waitUntilExit()
        killer.cancel()
        return data.isEmpty ? nil : data
    }
}
