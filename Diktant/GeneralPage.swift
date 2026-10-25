import AVFoundation
import SwiftUI

struct GeneralPage: View {
    @AppStorage("sounds") private var sounds = true
    @AppStorage("escCancels") private var escCancels = true
    @State private var accessibility = Paster.isTrusted
    @State private var microphone = AudioRecorder.permission

    var body: some View {
        Form {
            Section("Диктовка") {
                ShortcutRow()
                Toggle("Звук начала и конца записи", isOn: $sounds)
                Toggle(isOn: $escCancels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Esc отменяет запись")
                        Text("Текст не вставляется").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !accessibility || microphone != .authorized {
                Section("Доступ") {
                    if !accessibility {
                        PermissionRow(title: "Универсальный доступ",
                                      detail: "Нужен, чтобы видеть клавишу диктовки и вставлять текст") {
                            Paster.askForAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    if microphone != .authorized {
                        PermissionRow(title: "Микрофон", detail: "Чтобы записывать голос") {
                            if microphone == .notDetermined {
                                Task { _ = await AudioRecorder.requestPermission(); refresh() }
                            } else {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            }
                        }
                    }
                }
            }
            Section("Система") {
                LoginItemToggle()
                LabeledContent("Язык приложения") {
                    Menu {
                        Button("Русский") {}
                        Button("English (позже)") {}.disabled(true)
                    } label: {
                        Text("Русский")
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(LightSwitchStyle())
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        accessibility = Paster.isTrusted
        microphone = AudioRecorder.permission
        if accessibility, !HotkeyMonitor.shared.isInstalled { HotkeyMonitor.shared.install() }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Разрешить", action: action)
        }
    }
}

/// "Клавиша": the current key and "Изменить", which waits for a new one: a modifier pressed and
/// released alone (right ⌥, right ⌘, Fn…), a key with ⌃/⌥/⌘, or an F-key alone.
private struct ShortcutRow: View {
    @State private var shortcut = HotkeyMonitor.shared.shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(recording ? "Нажмите клавишу…" : shortcut.title)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Button(recording ? "Отмена" : "Изменить") { recording ? stop() : start() }
                if shortcut != .rightOption && !recording {
                    Button("Сбросить") { save(.rightOption) }
                }
            }
        } label: {
            Text("Клавиша")
            Text("Удерживайте — диктовка, пока держите. Нажмите коротко — до следующего нажатия.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        pendingModifier = nil
        HotkeyMonitor.shared.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event) ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        pendingModifier = nil
        HotkeyMonitor.shared.isPaused = false
    }

    private func save(_ new: Shortcut) {
        shortcut = new
        HotkeyMonitor.shared.setShortcut(new)
    }

    /// True = the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            guard let key = Shortcut.modifierKeys[event.keyCode] else { return false }
            let down = UInt64(event.modifierFlags.rawValue) & key.deviceMask != 0
            if down {
                // A second modifier while one is held: a combination is coming, not a single key.
                pendingModifier = pendingModifier == nil ? event.keyCode : nil
            } else if pendingModifier == event.keyCode {
                save(Shortcut(keyCode: event.keyCode))
                stop()
            }
            return false
        }
        pendingModifier = nil
        if event.keyCode == 53 { // Esc
            stop()
            return true
        }
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        if !flags.isDisjoint(with: [.control, .option, .command]) || Shortcut.isUsableAlone(event.keyCode) {
            save(Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue))
            stop()
        } else {
            NSSound.beep()
        }
        return true
    }
}
