import CoreBluetooth
import Foundation

struct DiscoveredPanel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Owns the CBCentralManager: scanning for `LED_BLE_*` panels and keeping
/// the configured panels connected (CoreBluetooth connect requests never time
/// out, so a panel that is switched off reconnects as soon as it comes back).
@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var powerState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredPanel] = []
    @Published private(set) var links: [UUID: PanelLink] = [:]

    private var central: CBCentralManager!
    private var seenPeripherals: [UUID: CBPeripheral] = [:]
    private var wanted: Set<UUID> = []
    private var scanStopTask: Task<Void, Never>?

    /// Fired when a link object is created, so the current picture can be queued on it.
    var onLinksChanged: (() -> Void)?
    /// Fired when a link (re)connects and can take frames.
    var onLinkReady: ((UUID) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isPoweredOn: Bool { powerState == .poweredOn }

    // MARK: Scanning

    func startScan(seconds: Double = 10) {
        guard isPoweredOn else { return }
        discovered.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStopTask?.cancel()
        central.stopScan()
        isScanning = false
    }

    // MARK: Connections

    /// Makes the set of connected panels match `ids`.
    func sync(wanted ids: Set<UUID>) {
        wanted = ids
        for (id, link) in links where !ids.contains(id) {
            central.cancelPeripheralConnection(link.peripheral)
            link.markIdle()
            links[id] = nil
        }
        guard isPoweredOn else { return }
        var created = false
        for id in ids where links[id] == nil {
            guard let peripheral = seenPeripherals[id]
                ?? central.retrievePeripherals(withIdentifiers: [id]).first else { continue }
            let link = PanelLink(peripheral: peripheral)
            link.onNeedsReconnect = { [weak self] link in self?.bounce(link) }
            link.onReady = { [weak self] link in self?.onLinkReady?(link.id) }
            links[id] = link
            connect(link)
            created = true
        }
        if created { onLinksChanged?() }
    }

    func reconnectAll() {
        for link in links.values { bounce(link) }
    }

    func link(for id: UUID) -> PanelLink? { links[id] }

    private func connect(_ link: PanelLink) {
        link.willConnect()
        central.connect(link.peripheral, options: nil)
    }

    private func bounce(_ link: PanelLink) {
        central.cancelPeripheralConnection(link.peripheral)
        // didDisconnectPeripheral re-issues the connect.
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            powerState = central.state
            if central.state == .poweredOn {
                let ids = wanted
                links.removeAll()
                sync(wanted: ids)
            } else {
                for link in links.values { link.didDisconnect(error: nil) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            let name = advName ?? peripheral.name ?? ""
            guard name.hasPrefix(PanelProtocol.namePrefix) else { return }
            seenPeripherals[peripheral.identifier] = peripheral
            let entry = DiscoveredPanel(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
                discovered[index] = entry
            } else {
                discovered.append(entry)
            }
            // A wanted panel that could not be retrieved before can be connected now.
            if wanted.contains(peripheral.identifier), links[peripheral.identifier] == nil {
                sync(wanted: wanted)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            links[peripheral.identifier]?.didConnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard let link = links[peripheral.identifier] else { return }
            link.didFailToConnect(error: error)
            retryLater(link)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard let link = links[peripheral.identifier] else { return }
            link.didDisconnect(error: error)
            retryLater(link)
        }
    }

    private func retryLater(_ link: PanelLink) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isPoweredOn, self.links[link.id] === link else { return }
            self.connect(link)
        }
    }
}
