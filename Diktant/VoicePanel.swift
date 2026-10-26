import AppKit
import Combine
import SwiftUI

/// The "Голосовые из Telegram" popup: the latest voice messages and their text, in a small panel
/// near the top centre of the screen with the pointer. Built on show and released on close; Esc,
/// a click elsewhere or the hot key again closes it. Does not take the focus from Telegram.
@MainActor
final class VoicePanel {
    static let shared = VoicePanel()

    private var panel: Panel?
    private var host: NSHostingView<VoicesView>?
    private var monitors: [Any] = []
    private var changes: AnyCancellable?

    var isShown: Bool { panel != nil }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        if panel == nil { build() }
        VoiceTranscripts.shared.refresh()
        fit(anchorTop: false)
        panel?.makeKeyAndOrderFront(nil)
        watchForClose()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        changes = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        VoiceTranscripts.shared.clear()
        Memory.giveBackSoon()
    }

    private func build() {
        let host = NSHostingView(rootView: VoicesView(close: { [weak self] in self?.close() }))
        let size = host.fittingSize
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.panel = panel
        self.host = host
        // The text arrives after opening: grow with it, keeping the top edge in place.
        changes = VoiceTranscripts.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit(anchorTop: true) } }
        }
    }

    private func fit(anchorTop: Bool) {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if anchorTop {
            guard size != panel.frame.size else { return }
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let top = visible.maxY - visible.height * 0.18
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// A click anywhere else or Esc closes it, like a menu.
    private func watchForClose() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { self?.close(); return nil } // Esc
                return event
            }
        }) { monitors.append(local) }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

struct VoicesView: View {
    let close: () -> Void
    @ObservedObject private var model = VoiceTranscripts.shared
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Голосовые из Telegram").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Закрыть (Esc)")
            }
            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Ищу голосовые…").foregroundStyle(.secondary)
                }
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                VoiceRow(item: item, expanded: index == 0 || expanded == item.id) {
                    expanded = expanded == item.id ? nil : item.id
                }
            }
            Text("Новое сверху · \(HotkeyMonitor.shared.voicesShortcut.title)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 460)
    }
}

private struct VoiceRow: View {
    let item: VoiceTranscripts.Item
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if case .done(let text) = item.text, !text.isEmpty {
                    Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Скопировать")
                }
            }
            switch item.text {
            case .waiting:
                Text("В очереди…").foregroundStyle(.secondary)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Распознаю…").foregroundStyle(.secondary)
                }
            case .done(let text):
                Text(text.isEmpty ? String(localized: "Речь не распознана") : text)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
    }

    private var meta: String {
        let seconds = Int(item.file.duration.rounded())
        let time = item.file.date.formatted(.relative(presentation: .named))
        return "\(time) · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sounds.play(.success)
    }
}
