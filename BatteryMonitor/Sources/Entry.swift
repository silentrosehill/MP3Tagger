import Foundation

/// Normal launch opens the menu bar app. For troubleshooting, run the binary from Terminal with
/// --debug to print what every source finds:
///   "/Applications/Battery Monitor.app/Contents/MacOS/BatteryMonitor" --debug
@main @MainActor
enum Entry {
    static func main() {
        guard CommandLine.arguments.contains("--debug") else {
            BatteryMonitorApp.main()
            return
        }
        print("Battery Monitor \(appVersion) — debug report\n")

        func show(_ title: String, _ devices: [Device]) {
            print("[\(title)]")
            if devices.isEmpty { print("  (nothing)") }
            for d in devices {
                print("  \(d.label): \(d.statusText)\(d.charging ? " (charging)" : "")  kind=\(d.kind)")
            }
            print("")
        }

        print("[Razer protocol log]")
        let razer = RazerReader.read { print("  " + $0) }
        print("")
        show("Razer", razer)
        print("HeadsetControl: \(DeviceReader.headsetControlPath() ?? "not installed")")
        show("HeadsetControl", DeviceReader.readHeadsetControl())
        show("Bluetooth (system_profiler)", DeviceReader.readSystemProfiler())
        show("Apple accessories (ioreg)", DeviceReader.readIORegistry())
    }
}
