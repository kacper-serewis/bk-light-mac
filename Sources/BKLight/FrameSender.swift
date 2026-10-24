import Foundation

/// Sends frames to the panels so the wall changes as one picture where possible.
/// Each panel uploads its newest tile on its own; after its upload is acknowledged it waits
/// briefly for the other panels uploading the same frame, so they all commit (validate) together.
/// The wait is capped: the panels drop a transaction whose validation comes too late
/// (they answer `05 00 01 80 03` and ignore the next handshake), and a slow panel must not
/// hold up the others.
@MainActor
final class FrameSender {
    /// Longest a panel waits for its peers before committing anyway.
    private static let maxPeerWait: Duration = .milliseconds(250)
    /// Gap between frame ack and validation, as in the Python reference.
    private static let minCommitDelay: Duration = .milliseconds(100)

    private let bluetooth: BluetoothManager
    private var generation = 0
    private var latest: [UUID: (generation: Int, png: Data)] = [:]   // newest tile per panel
    private var dirty: Set<UUID> = []                                // panels whose newest tile isn't shown yet
    private var uploading: [UUID: Int] = [:]                         // panel → generation it is uploading
    private var loops: [UUID: Task<Void, Never>] = [:]

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
        bluetooth.onLinkReady = { [weak self] id in self?.linkBecameReady(id) }
    }

    /// True when no panel is uploading or about to.
    var isIdle: Bool { loops.isEmpty }

    func submit(_ tiles: [UUID: Data]) {
        generation += 1
        for (id, png) in tiles where latest[id]?.png != png {
            latest[id] = (generation, png)
            dirty.insert(id)
        }
        for id in latest.keys where tiles[id] == nil {
            latest[id] = nil
            dirty.remove(id)
        }
        for id in dirty { pump(id) }
    }

    /// A panel that (re)connects gets the current picture again.
    private func linkBecameReady(_ id: UUID) {
        guard latest[id] != nil else { return }
        dirty.insert(id)
        pump(id)
    }

    private func pump(_ id: UUID) {
        guard loops[id] == nil, let link = bluetooth.link(for: id), link.state == .ready else { return }
        loops[id] = Task { [weak self] in
            await self?.run(link)
            self?.loops[id] = nil
        }
    }

    private func run(_ link: PanelLink) async {
        while dirty.contains(link.id), let item = latest[link.id], link.state == .ready {
            dirty.remove(link.id)
            uploading[link.id] = item.generation
            let uploaded = (try? await link.upload(png: item.png)) != nil
            uploading[link.id] = nil
            if uploaded {
                await waitForPeers(generation: item.generation)
                if link.commit() { continue }
            }
            // Retry with whatever is newest for this panel by then.
            if latest[link.id] != nil { dirty.insert(link.id) }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func waitForPeers(generation: Int) async {
        let clock = ContinuousClock()
        let acked = clock.now
        while uploading.values.contains(generation), clock.now < acked + Self.maxPeerWait {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let remaining = Self.minCommitDelay - acked.duration(to: clock.now)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
    }
}
