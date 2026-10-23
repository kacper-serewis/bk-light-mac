import CoreBluetooth
import Foundation

enum PanelError: LocalizedError {
    case notReady
    case timeout(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "Panel not connected"
        case .timeout(let step): "Timed out waiting for \(step)"
        case .write(let message): "Write failed: \(message)"
        }
    }
}

/// One BLE connection to one LED panel. Frames are coalesced: only the newest
/// pending image is sent, and the last delivered image is re-sent after a reconnect.
@MainActor
final class PanelLink: NSObject, ObservableObject, Identifiable {
    enum State: String {
        case idle, connecting, discovering, ready, sending, disconnected
        var isUsable: Bool { self == .ready || self == .sending }
    }

    let id: UUID
    let peripheral: CBPeripheral
    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var framesSent = 0

    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var pendingPNG: Data?
    private var lastDeliveredPNG: Data?
    private var sendLoop: Task<Void, Never>?

    private var receivedAcks: [Data] = []
    private var ackWaiter: (matches: [Data], continuation: CheckedContinuation<Void, Error>)?
    private var writeWaiter: CheckedContinuation<Void, Error>?

    /// Called when a send keeps failing so the manager can drop and re-establish the link.
    var onNeedsReconnect: ((PanelLink) -> Void)?

    init(peripheral: CBPeripheral) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    // MARK: Connection lifecycle (driven by BluetoothManager)

    func willConnect() {
        state = .connecting
    }

    func didConnect() {
        state = .discovering
        lastError = nil
        writeChar = nil
        notifyChar = nil
        peripheral.discoverServices(nil)
    }

    func didDisconnect(error: Error?) {
        state = .disconnected
        if let error { lastError = error.localizedDescription }
        writeChar = nil
        notifyChar = nil
        failWaiters(PanelError.notReady)
    }

    func didFailToConnect(error: Error?) {
        state = .disconnected
        lastError = error?.localizedDescription ?? "Failed to connect"
    }

    func markIdle() {
        state = .idle
        failWaiters(PanelError.notReady)
    }

    // MARK: Sending

    func submit(png: Data) {
        pendingPNG = png
        pumpIfPossible()
    }

    private func pumpIfPossible() {
        guard sendLoop == nil, state == .ready, pendingPNG != nil else { return }
        sendLoop = Task { [weak self] in
            await self?.runSendLoop()
        }
    }

    private func runSendLoop() async {
        defer {
            sendLoop = nil
            if state == .sending { state = .ready }
        }
        var failures = 0
        while let png = pendingPNG, state.isUsable {
            pendingPNG = nil
            state = .sending
            do {
                try await deliver(png: png)
                lastDeliveredPNG = png
                framesSent += 1
                lastError = nil
                failures = 0
            } catch {
                lastError = error.localizedDescription
                failures += 1
                // Keep the frame unless something newer arrived meanwhile.
                if pendingPNG == nil { pendingPNG = png }
                if failures >= 3 {
                    onNeedsReconnect?(self)
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// handshake → ack, frame (write-with-response) → ack, validation. Same as send_frame() in Python.
    private func deliver(png: Data) async throws {
        guard let writeChar, state.isUsable else { throw PanelError.notReady }
        let frame = PanelProtocol.buildFrame(png: png)

        receivedAcks.removeAll()
        peripheral.writeValue(PanelProtocol.handshakeFirst, for: writeChar, type: .withoutResponse)
        try await waitForAck(PanelProtocol.ackStageOne, label: "handshake ack")
        try await Task.sleep(for: .milliseconds(100))

        receivedAcks.removeAll()
        // ATT caps one write-with-response at 512 bytes; larger frames go in sequential chunks
        // (the panel reassembles them using the total length in the header).
        let maxChunk = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + maxChunk, frame.count)
            try await writeWithResponse(frame.subdata(in: offset..<end), to: writeChar)
            offset = end
        }
        try await waitForAck(PanelProtocol.ackFrame, label: "frame ack")
        try await Task.sleep(for: .milliseconds(100))
        peripheral.writeValue(PanelProtocol.frameValidation, for: writeChar, type: .withoutResponse)
    }

    private func writeWithResponse(_ data: Data, to characteristic: CBCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeWaiter = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            scheduleTimeout(seconds: 5) { [weak self] in
                guard let self, let waiter = self.writeWaiter else { return }
                self.writeWaiter = nil
                waiter.resume(throwing: PanelError.timeout("write response"))
            }
        }
    }

    private func waitForAck(_ matches: [Data], label: String) async throws {
        if receivedAcks.contains(where: matches.contains) { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ackWaiter = (matches, continuation)
            scheduleTimeout(seconds: 5) { [weak self] in
                guard let self, let waiter = self.ackWaiter else { return }
                self.ackWaiter = nil
                waiter.continuation.resume(throwing: PanelError.timeout(label))
            }
        }
    }

    private var timeoutGeneration = 0

    private func scheduleTimeout(seconds: Double, _ fire: @escaping @MainActor () -> Void) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.timeoutGeneration == generation else { return }
            fire()
        }
    }

    private func failWaiters(_ error: Error) {
        timeoutGeneration += 1
        if let waiter = ackWaiter { ackWaiter = nil; waiter.continuation.resume(throwing: error) }
        if let waiter = writeWaiter { writeWaiter = nil; waiter.resume(throwing: error) }
    }

    private func handleNotification(_ value: Data) {
        receivedAcks.append(value)
        if let waiter = ackWaiter, waiter.matches.contains(value) {
            ackWaiter = nil
            timeoutGeneration += 1
            waiter.continuation.resume()
        }
    }

    private func becameReady() {
        state = .ready
        if pendingPNG == nil { pendingPNG = lastDeliveredPNG }
        pumpIfPossible()
    }
}

extension PanelLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { lastError = error.localizedDescription; return }
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics([PanelProtocol.writeUUID, PanelProtocol.notifyUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == PanelProtocol.writeUUID, writeChar == nil { writeChar = characteristic }
                if characteristic.uuid == PanelProtocol.notifyUUID, notifyChar == nil {
                    notifyChar = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { lastError = "Notify: \(error.localizedDescription)"; return }
            if characteristic.uuid == PanelProtocol.notifyUUID, characteristic.isNotifying, writeChar != nil {
                becameReady()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == PanelProtocol.notifyUUID, let value = characteristic.value else { return }
        MainActor.assumeIsolated { handleNotification(value) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let waiter = writeWaiter else { return }
            writeWaiter = nil
            timeoutGeneration += 1
            if let error {
                waiter.resume(throwing: PanelError.write(error.localizedDescription))
            } else {
                waiter.resume()
            }
        }
    }
}
