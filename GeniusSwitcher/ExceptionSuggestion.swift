import AppKit
import SwiftUI

/// "«rtl» — больше не исправлять?" in the top right corner. A non-activating panel: typing goes on
/// in the app the user is in; the buttons take a click without stealing the focus. Hides itself.
@MainActor
enum ExceptionSuggestion {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    static let visibleTime: TimeInterval = 8

    static func show(word: String, add: @escaping () -> Void) {
        let panel = panel ?? make()
        Self.panel = panel
        let view = SuggestionView(word: word, add: { add(); hide() }, close: hide)
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 12,
                                         y: visible.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleTime, execute: work)
    }

    static func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private static func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

/// The panel is never key: without this the first click would only "activate" it.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SuggestionView: View {
    let word: String
    let add: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("«\(word)»").font(.callout.monospaced().bold())
                Text("Больше не исправлять это слово?").font(.caption).foregroundStyle(.secondary)
            }
            Button("В исключения", action: add).controlSize(.small)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Не добавлять")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .fixedSize()
    }
}
