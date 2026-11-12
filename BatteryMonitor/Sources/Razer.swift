import Foundation
import IOKit
import IOKit.hid

/// Battery for Razer wireless mice (Viper Ultimate, DeathAdder V2 Pro, Basilisk Ultimate…).
/// Razer Synapse doesn't exist on macOS, so this talks to the mouse / dongle directly using
/// Razer's 90-byte feature-report protocol, as documented by the OpenRazer project:
///   battery level   = class 0x07, command 0x80 → arg[1] is 0–255
///   charging status = class 0x07, command 0x84 → arg[1] is 1 when charging
enum RazerReader {
    static let vendorID = 0x1532

    /// Different Razer models answer to different transaction IDs; the Viper Ultimate uses 0xFF.
    static let transactionIDs: [UInt8] = [0xFF, 0x1F, 0x3F]

    private enum Status: UInt8 {
        case new = 0x00, busy = 0x01, success = 0x02, failure = 0x03, timeout = 0x04, unsupported = 0x05
    }

    static func read(log: ((String) -> Void)? = nil) -> [Device] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if opened != kIOReturnSuccess { log?(String(format: "IOHIDManagerOpen returned 0x%08x", opened)) }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            log?("No Razer mouse or dongle found.")
            return []
        }

        // A dongle can show up as several HID interfaces; one answer per physical device.
        var results: [String: Device] = [:]
        let devices = set.sorted { location($0) < location($1) }
        for hid in devices {
            let pid = intProp(hid, kIOHIDProductIDKey)
            let key = "\(location(hid))-\(pid)"
            if let done = results[key], done.level != nil { continue }

            let product = (IOHIDDeviceGetProperty(hid, kIOHIDProductKey as CFString) as? String) ?? "Razer Mouse"
            let name = product.replacingOccurrences(of: " Dongle", with: "")
                .replacingOccurrences(of: " (Wireless)", with: "")
                .replacingOccurrences(of: " (Wired)", with: "")
            log?(String(format: "%@  PID 0x%04x  location 0x%08x", product, pid, location(hid)))

            var asleep = false
            for txn in transactionIDs {
                guard let reply = query(hid, txn: txn, command: 0x80, log: log) else { continue }
                if reply.status == Status.success.rawValue {
                    let level = Int((Double(reply.args[1]) / 255 * 100).rounded())
                    let charging = query(hid, txn: txn, command: 0x84, log: log)
                        .map { $0.status == Status.success.rawValue && $0.args[1] == 1 } ?? false
                    log?("  → battery \(level)%\(charging ? ", charging" : "")")
                    results[key] = Device(name: name, level: level, source: .dongle, kind: "Mouse", charging: charging)
                    break
                }
                if reply.status == Status.timeout.rawValue || reply.status == Status.busy.rawValue {
                    asleep = true  // dongle is there but the mouse didn't answer
                }
            }
            if results[key] == nil && asleep {
                results[key] = Device(name: name, level: nil, source: .dongle, kind: "Mouse", detail: "Asleep")
            }
        }
        return results.keys.sorted().compactMap { results[$0] }
    }

    /// Sends one command and waits for the answer. nil = the report couldn't be sent / read at all.
    private static func query(_ hid: IOHIDDevice, txn: UInt8, command: UInt8,
                              log: ((String) -> Void)?) -> (status: UInt8, args: [UInt8])? {
        var report = [UInt8](repeating: 0, count: 90)
        report[1] = txn      // transaction id
        report[5] = 0x02     // data size
        report[6] = 0x07     // command class: misc / power
        report[7] = command
        report[88] = report[2..<88].reduce(0, ^)   // checksum: XOR of bytes 2…87

        let sent = IOHIDDeviceSetReport(hid, kIOHIDReportTypeFeature, 0, report, report.count)
        guard sent == kIOReturnSuccess else {
            log?(String(format: "  txn 0x%02x cmd 0x%02x: send failed 0x%08x", txn, command, sent))
            return nil
        }
        var last: UInt8 = Status.busy.rawValue
        for _ in 0..<6 {
            usleep(60_000)   // wireless receivers need ~60 ms to relay the answer
            var buf = [UInt8](repeating: 0, count: 90)
            var length = CFIndex(buf.count)
            let got = IOHIDDeviceGetReport(hid, kIOHIDReportTypeFeature, 0, &buf, &length)
            guard got == kIOReturnSuccess else {
                log?(String(format: "  txn 0x%02x cmd 0x%02x: read failed 0x%08x", txn, command, got))
                return nil
            }
            last = buf[0]
            if last == Status.busy.rawValue || last == Status.new.rawValue { continue }
            guard buf[6] == 0x07, buf[7] == command else { continue }  // stale answer to something else
            log?(String(format: "  txn 0x%02x cmd 0x%02x: status 0x%02x arg1 %d", txn, command, last, buf[9]))
            return (last, Array(buf[8..<88]))
        }
        log?(String(format: "  txn 0x%02x cmd 0x%02x: no answer (last status 0x%02x)", txn, command, last))
        return (last, [UInt8](repeating: 0, count: 80))
    }

    private static func intProp(_ hid: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(hid, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func location(_ hid: IOHIDDevice) -> Int { intProp(hid, kIOHIDLocationIDKey) }
}
