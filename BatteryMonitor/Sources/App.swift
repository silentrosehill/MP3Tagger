import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

struct BatteryMonitorApp: App {
    @StateObject private var store = BatteryStore.shared

    var body: some Scene {
        MenuBarExtra {
            DeviceListView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

// MARK: - State

@MainActor
final class BatteryStore: ObservableObject {
    static let shared = BatteryStore()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var loaded = false
    @Published private(set) var refreshing = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var hasHeadsetControl = true
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    private var timer: Timer?
    private var lowNotified = Set<String>()

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { BatteryStore.shared.refresh() }
        }
    }

    /// Lowest known level: what the menu bar shows.
    var lowest: Device? { devices.filter { $0.level != nil }.min { $0.level! < $1.level! } }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let found = DeviceReader.readAll()
            let hasHC = DeviceReader.headsetControlPath() != nil
            await MainActor.run { BatteryStore.shared.apply(found, hasHeadsetControl: hasHC) }
        }
    }

    private func apply(_ found: [Device], hasHeadsetControl: Bool) {
        devices = found
        self.hasHeadsetControl = hasHeadsetControl
        loaded = true
        refreshing = false
        lastUpdate = Date()
        openAtLogin = SMAppService.mainApp.status == .enabled
        notifyLow()
    }

    /// One notification when a device hits 20%; again only after it's been charged above 30%.
    private func notifyLow() {
        for d in devices {
            guard let level = d.level, !d.charging else { continue }
            if level <= lowBatteryLevel, !lowNotified.contains(d.label) {
                lowNotified.insert(d.label)
                let content = UNMutableNotificationContent()
                content.title = "Low battery"
                content.body = "\(d.label) is at \(level)%"
                content.sound = .default
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { _ in }
            } else if level > lowBatteryLevel + 10 {
                lowNotified.remove(d.label)
            }
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change Open at Login. Move the app to Applications first."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @ObservedObject var store: BatteryStore

    var body: some View {
        if let d = store.lowest, let level = d.level {
            HStack(spacing: 3) {
                Image(systemName: d.symbol)
                Text("\(level)%")
            }
        } else {
            Image(systemName: "battery.100")
        }
    }
}

// MARK: - Popup window

struct DeviceListView: View {
    @EnvironmentObject var store: BatteryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery Monitor").font(.headline)
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
            }

            if !store.loaded {
                Text("Looking for devices…").foregroundStyle(.secondary)
            } else if store.devices.isEmpty {
                Text("No devices are reporting their battery right now.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(DeviceSource.allCases, id: \.self) { source in
                let group = store.devices.filter { $0.source == source }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.rawValue.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group, id: \.label) { DeviceRow(device: $0) }
                    }
                }
            }

            if store.loaded && !store.hasHeadsetControl {
                VStack(alignment: .leading, spacing: 4) {
                    Text("For USB-dongle headsets (SteelSeries…), install HeadsetControl in Terminal:")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("brew install sapd/headsetcontrol/headsetcontrol")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin },
                                                  set: { store.setOpenAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if let err = store.loginError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r")
                Spacer()
                if let date = store.lastUpdate {
                    Text("Updated \(date, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            Text("v\(appVersion)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct DeviceRow: View {
    let device: Device

    private var color: Color {
        guard let level = device.level else { return .gray }
        if device.charging { return .green }
        return level <= lowBatteryLevel ? .red : level <= 50 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(device.label).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    if device.charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                    Text(device.statusText)
                        .monospacedDigit()
                        .foregroundStyle(device.isLow ? Color.red : Color.primary)
                }
                if let level = device.level {
                    ProgressView(value: Double(level), total: 100)
                        .progressViewStyle(.linear)
                        .tint(color)
                        .controlSize(.small)
                }
            }
        }
    }
}
