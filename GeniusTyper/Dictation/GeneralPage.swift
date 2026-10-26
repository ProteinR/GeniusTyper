import AVFoundation
import SwiftUI

struct GeneralPage: View {
    @AppStorage("sounds") private var sounds = true
    @AppStorage("escCancels") private var escCancels = true
    @AppStorage("mascot") private var mascot = Mascot.none.rawValue
    @State private var accessibility = Paster.isTrusted
    @State private var microphone = AudioRecorder.permission

    var body: some View {
        Form {
            Section("Диктовка") {
                ShortcutRow(kind: .dictation)
                Toggle(isOn: $sounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Звуки диктовки")
                        Text("Начало записи, вставка текста, ошибка").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $escCancels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Esc отменяет запись")
                        Text("Текст не вставляется").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(Mascot.allCases) { item in
                                Button(item.title) { mascot = item.rawValue }
                            }
                        } label: {
                            Text((Mascot(rawValue: mascot) ?? .none).title)
                        }
                        .fixedSize()
                        Button("Показать") { Indicator.shared.demo() }
                    }
                } label: {
                    Text("Анимация")
                    Text("Персонаж над индикатором печатает, пока вы говорите").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ShortcutRow(kind: .voices)
            } header: {
                Text("Голосовые из Telegram")
            } footer: {
                Text("Показывает расшифровку последних голосовых из Telegram. Чтобы туда не попадали голосовые из групп, в Telegram → Настройки → Данные и память → Автозагрузка медиа оставьте голосовые только для личных чатов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// A key setting: the current key and "Изменить", which waits for a new one. The dictation key:
/// a modifier pressed and released alone (right ⌥, right ⌘, Fn…), a key with ⌃/⌥/⌘, or an F-key
/// alone. "Голосовые из Telegram": a key with ⌃/⌥/⌘ or an F-key (a hot key, no single modifier).
private struct ShortcutRow: View {
    enum Kind { case dictation, voices }

    let kind: Kind
    @State private var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?

    init(kind: Kind) {
        self.kind = kind
        _shortcut = State(initialValue: kind == .dictation ? HotkeyMonitor.shared.shortcut : HotkeyMonitor.shared.voicesShortcut)
    }

    private var defaultShortcut: Shortcut { kind == .dictation ? .rightOption : .voicesDefault }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(recording ? "Нажмите клавишу…" : shortcut.title)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Button(recording ? "Отмена" : "Изменить") { recording ? stop() : start() }
                if shortcut != defaultShortcut && !recording {
                    Button("Сбросить") { save(defaultShortcut) }
                }
            }
        } label: {
            if kind == .dictation {
                Text("Клавиша")
                Text("Удерживайте — диктовка, пока держите. Нажмите коротко — до следующего нажатия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Сочетание клавиш")
            }
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
        if kind == .dictation {
            HotkeyMonitor.shared.setShortcut(new)
        } else {
            HotkeyMonitor.shared.setVoicesShortcut(new)
        }
    }

    /// True = the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            guard kind == .dictation, let key = Shortcut.modifierKeys[event.keyCode] else { return false }
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
