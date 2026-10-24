import Darwin
import Foundation
import IOKit.ps

struct SystemSnapshot: Equatable {
    var cpu = 0.0                  // 0…1, all cores
    var memory = 0.0               // 0…1, like Activity Monitor's "Memory Used"
    var battery: Double?           // 0…1, nil without an internal battery
    var charging = false
    var disk = 0.0                 // 0…1 of the startup volume
    var cpuHistory: [Double] = []  // oldest first
}

/// Samples CPU, memory, battery and disk usage.
@MainActor
final class SystemMonitor {
    nonisolated static let historyLength = 60

    private(set) var snapshot = SystemSnapshot()
    private(set) var generation = 0
    private var previousTicks: (busy: UInt64, total: UInt64)?

    func sample() {
        var next = snapshot
        if let cpu = cpuUsage() {
            next.cpu = cpu
            next.cpuHistory = Array((next.cpuHistory + [cpu]).suffix(Self.historyLength))
        }
        next.memory = memoryUsage() ?? next.memory
        (next.battery, next.charging) = battery()
        next.disk = diskUsage() ?? next.disk
        snapshot = next
        generation += 1
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks   // user, system, idle, nice
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    private func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // App memory (internal − purgeable) + wired + compressed.
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return min(1, Double(pages * UInt64(vm_kernel_page_size)) / Double(ProcessInfo.processInfo.physicalMemory))
    }

    private func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Double(current) / Double(max), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }

    private func diskUsage() -> Double? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, total > 0,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return 1 - Double(available) / Double(total)
    }
}

extension Renderer {
    /// Rows of label, percentage and bar (CPU, memory, battery or disk) and, at 64×64, a CPU history graph.
    static func systemStatus(_ snapshot: SystemSnapshot, size: Int) -> Bitmap {
        var bitmap = Bitmap(width: size, height: size)
        func load(_ value: Double) -> RGB { value < 0.6 ? .green : value < 0.85 ? .orange : .red }
        var rows: [(label: String, value: Double, color: RGB)] = [
            ("CPU", snapshot.cpu, load(snapshot.cpu)),
            ("MEM", snapshot.memory, load(snapshot.memory)),
        ]
        if let battery = snapshot.battery {
            rows.append(("BAT", battery, snapshot.charging ? .cyan : battery > 0.3 ? .green : battery > 0.15 ? .orange : .red))
        } else {
            rows.append(("DSK", snapshot.disk, load(snapshot.disk)))
        }

        let big = size >= 64
        let rowHeight = big ? 16 : 10
        for (i, row) in rows.enumerated() {
            let top = i * rowHeight + 1
            let percent = "\(Int((row.value * 100).rounded()))%"
            if big {
                bitmap.text(row.label, x: 2, y: top + 4, .lightGray)
                bitmap.text(percent, rightAt: size - 2, y: top - 1, scale: 2, .white)
                drawBar(&bitmap, x: 2, y: top + 11, width: size - 4, height: 3, value: row.value, color: row.color)
            } else {
                bitmap.text(row.label, x: 1, y: top, .lightGray)
                bitmap.text(percent, rightAt: size - 1, y: top, .white)
                drawBar(&bitmap, x: 1, y: top + 6, width: size - 2, height: 2, value: row.value, color: row.color)
            }
        }

        if big {
            // CPU history, newest on the right.
            let (left, bottom, height) = (2, size - 2, 12)
            bitmap.fill(x: left, y: bottom, width: SystemMonitor.historyLength, height: 1, .darkGray)
            let history = snapshot.cpuHistory
            for (i, value) in history.enumerated() {
                let x = left + SystemMonitor.historyLength - history.count + i
                let h = Int((value * Double(height)).rounded())
                bitmap.fill(x: x, y: bottom - h, width: 1, height: h, load(value))
            }
        }
        return bitmap
    }

    private static func drawBar(_ bitmap: inout Bitmap, x: Int, y: Int, width: Int, height: Int, value: Double, color: RGB) {
        bitmap.fill(x: x, y: y, width: width, height: height, .darkGray)
        bitmap.fill(x: x, y: y, width: Int((Double(width) * min(1, max(0, value))).rounded()), height: height, color)
    }
}
