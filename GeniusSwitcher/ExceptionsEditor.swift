import AppKit
import SwiftUI

/// A window to edit the user's exceptions dictionary: one word per line. Its own window, not a
/// sheet: the panel is a transient popover and closes as soon as a text field takes focus elsewhere.
@MainActor
enum ExceptionsEditor {
    private static var window: NSWindow?

    static func show() {
        let window = window ?? make()
        Self.window = window
        window.contentViewController = NSHostingController(rootView: ExceptionsEditorView { window.close() })
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Мои исключения"
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct ExceptionsEditorView: View {
    let close: () -> Void
    @State private var text = Observer.shared.userExceptions.text

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Эти слова никогда не исправляются автоматически. По одному в строке, как вы их печатаете (git, ок, имена). Регистр не важен.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 240)
                .border(Color.secondary.opacity(0.3))
            Text("Хранится только в настройках Genius Switcher, в журнал не попадает.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Слов: \(UserExceptions(text: text).words.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    Observer.shared.setUserExceptions(text)
                    close()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 360)
    }
}
