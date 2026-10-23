import CoreBluetooth
import SwiftUI

struct MainView: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                PanelsSection()
                ScanSection()
            }
            .formStyle(.grouped)
            .frame(minWidth: 400)
            Form {
                PreviewSection()
                DisplaySection()
                SourceSection()
            }
            .formStyle(.grouped)
            .frame(minWidth: 360)
        }
        .frame(minWidth: 780, minHeight: 620)
    }
}

// MARK: Preview

struct PreviewSection: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Section("Now showing") {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let preview = controller.preview {
                        Image(nsImage: preview).resizable().interpolation(.none)
                    } else {
                        Color.black
                    }
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.content.label).font(.headline)
                    if controller.nowPlaying.isPlaying {
                        Text(controller.nowPlaying.title).lineLimit(1)
                        Text(controller.nowPlaying.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("Brightness \(Int(controller.appliedBrightness * 100))%")
                        .foregroundStyle(.secondary).font(.caption)
                    Text(controller.sourceStatus).foregroundStyle(.secondary).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: Display settings

struct DisplaySection: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Section("Display") {
            Picker("Mode", selection: $controller.settings.mode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Layout", selection: $controller.settings.layout) {
                ForEach(Layout.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Brightness") {
                Slider(value: $controller.settings.brightness, in: 0.05...1)
            }
            Toggle("Dim the clock at night", isOn: $controller.settings.dynamicBrightness)
            LaunchAtLoginToggle()
            Button("Identify panels") { controller.identify() }
                .help("Shows 1–4 with a white bar on top for 8 seconds, to check placement and rotation.")
        }
    }
}

// MARK: Source settings

struct SourceSection: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Section("Music source") {
            Picker("Source", selection: $controller.settings.source) {
                ForEach(MediaSource.allCases) { Text($0.label).tag($0) }
            }
            if controller.settings.source == .homeAssistant {
                TextField("URL", text: $controller.settings.haBaseURL, prompt: Text("https://homeassistant.local:8123"))
                SecureField("Long-lived token", text: $controller.haToken)
                TextField("Entity", text: $controller.settings.haEntityID, prompt: Text("media_player.spotify_you"))
            }
            Stepper("Keep cover \(Int(controller.settings.idleGrace)) s after pause",
                    value: $controller.settings.idleGrace, in: 0...60)
        }
    }
}

// MARK: Panels

struct PanelsSection: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Section {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    SlotCard(slot: .topLeft)
                    SlotCard(slot: .topRight)
                }
                GridRow {
                    SlotCard(slot: .bottomLeft)
                    SlotCard(slot: .bottomRight)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Text(bluetoothStatus).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Reconnect all") { controller.bluetooth.reconnectAll() }
                    .disabled(controller.settings.panels.isEmpty)
            }
        } header: {
            Text("Panels (as seen from the front)")
        }
    }

    private var bluetoothStatus: String {
        switch controller.bluetooth.powerState {
        case .poweredOn: "Bluetooth on"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied — allow it in System Settings › Privacy & Security › Bluetooth"
        case .unsupported: "Bluetooth LE not supported"
        default: "Bluetooth starting…"
        }
    }
}

struct SlotCard: View {
    @EnvironmentObject var controller: DisplayController
    let slot: Slot

    var body: some View {
        let config = controller.settings.panel(in: slot)
        VStack(alignment: .leading, spacing: 6) {
            Text(slot.label).font(.caption).foregroundStyle(.secondary)
            if let config {
                Text(config.name).font(.headline).lineLimit(1)
                if let link = controller.bluetooth.links[config.id] {
                    LinkStatus(link: link)
                } else {
                    Label("Not seen yet — run a scan", systemImage: "circle.dashed").font(.caption)
                }
                HStack {
                    Picker("Rotation", selection: Binding(
                        get: { config.rotation },
                        set: { controller.setRotation($0, for: slot) }
                    )) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Spacer()
                    Button(role: .destructive) { controller.unassign(slot) } label: { Image(systemName: "xmark") }
                        .help("Remove panel from this slot")
                }
            } else {
                Text("Empty").font(.headline).foregroundStyle(.tertiary)
                Text("Scan, then assign a panel here").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

struct LinkStatus: View {
    @ObservedObject var link: PanelLink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(link.state.rawValue.capitalized).font(.caption)
                if link.framesSent > 0 {
                    Text("· \(link.framesSent) frames").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = link.lastError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private var color: Color {
        switch link.state {
        case .ready, .sending: .green
        case .connecting, .discovering: .orange
        case .idle, .disconnected: .red
        }
    }
}

struct ScanSection: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Section {
            if controller.bluetooth.discovered.isEmpty {
                Text(controller.bluetooth.isScanning ? "Searching for LED_BLE_* panels…" : "No panels found yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.bluetooth.discovered) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text("\(device.rssi) dBm · \(device.id.uuidString.prefix(8))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let assigned = controller.settings.panels.first(where: { $0.id == device.id }) {
                        Text(assigned.slot.label).foregroundStyle(.secondary)
                    }
                    Menu("Assign") {
                        ForEach(Slot.allCases) { slot in
                            Button(slot.label) { controller.assign(device, to: slot) }
                        }
                    }
                    .fixedSize()
                }
            }
        } header: {
            HStack {
                Text("Nearby panels")
                Spacer()
                if controller.bluetooth.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { controller.bluetooth.stopScan() }
                } else {
                    Button("Scan") { controller.bluetooth.startScan() }
                        .disabled(!controller.bluetooth.isPoweredOn)
                }
            }
        }
    }
}

// MARK: Menu bar

struct MenuBarView: View {
    @EnvironmentObject var controller: DisplayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let ready = controller.settings.panels.filter { controller.bluetooth.links[$0.id]?.state.isUsable == true }.count
        Text("\(ready)/\(controller.settings.panels.count) panels connected")
        Text(controller.content.label)
        Divider()
        Picker("Mode", selection: $controller.settings.mode) {
            ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
        }
        Button("Identify panels") { controller.identify() }
        Button("Reconnect all") { controller.bluetooth.reconnectAll() }
        LaunchAtLoginToggle()
        Divider()
        Button("Open BK Light…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
