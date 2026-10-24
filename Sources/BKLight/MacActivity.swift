import AppKit
import IOKit
import IOKit.pwr_mgt

/// Tracks whether someone is at the Mac: screen locked, displays asleep, screensaver running
/// or the system going to sleep all count as "away".
@MainActor
final class MacActivity {
    private(set) var isLocked = false
    private(set) var displaysAsleep = false
    private(set) var screensaverRunning = false
    private(set) var systemSleeping = false
    var isAway: Bool { isLocked || displaysAsleep || screensaverRunning || systemSleeping }

    var onChange: (() -> Void)?
    /// Called before system sleep; call `done` once the wall shows what it should (the Mac
    /// waits for it, up to the deadline set in `SleepGuard`).
    var onWillSleep: ((_ done: @escaping () -> Void) -> Void)?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleepGuard: SleepGuard?

    init() {
        isLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.isLocked = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isLocked = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaverRunning = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screensaverRunning = false }

        sleepGuard = SleepGuard(
            willSleep: { [weak self] done in
                guard let self else { return done() }
                self.systemSleeping = true
                self.onChange?()
                if let onWillSleep = self.onWillSleep { onWillSleep(done) } else { done() }
            },
            didWake: { [weak self] in
                guard let self else { return }
                self.systemSleeping = false
                self.onChange?()
            }
        )
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (MacActivity) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.onChange?()
            }
        }
        observers.append((center, token))
    }
}

/// Lets the app delay system sleep briefly (IORegisterForSystemPower), so a last frame
/// can reach the panels before Bluetooth goes down.
@MainActor
private final class SleepGuard {
    // iokit_common_msg() values from IOKit/IOMessage.h, which Swift doesn't import.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300
    private static let maxDelay: Duration = .seconds(5)

    private let willSleep: (@escaping () -> Void) -> Void
    private let didWake: () -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(willSleep: @escaping (@escaping () -> Void) -> Void, didWake: @escaping () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notifyPort, { refcon, _, type, argument in
            guard let refcon else { return }
            let guardObject = Unmanaged<SleepGuard>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { guardObject.handle(type: type, argument: argument) }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, .main)
        }
    }

    private func handle(type: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch type {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            var allowed = false
            let allow = { [weak self] in
                guard let self, !allowed else { return }
                allowed = true
                IOAllowPowerChange(self.rootPort, token)
            }
            willSleep(allow)
            Task {
                try? await Task.sleep(for: Self.maxDelay)
                allow()
            }
        case Self.systemHasPoweredOn:
            didWake()
        default:
            break
        }
    }
}
