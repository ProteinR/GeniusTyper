import AVFoundation
import SwiftUI

/// Диктовка: the switch, the key and how recording behaves, the model (on this Mac or by API) and
/// the Telegram voice messages. While dictation is off the rest is grey and nothing records.
struct DictationPage: View {
    @AppStorage("dictationEnabled") private var enabled = false
    @AppStorage("dictationSounds") private var sounds = true
    @AppStorage("escCancels") private var escCancels = true
    @AppStorage("dictationYo") private var yo = true
    @AppStorage("voicesEnabled") private var voices = true
    @AppStorage("voicesKeepDays") private var keepDays = 7
    @AppStorage("mascot") private var mascot = Mascot.none.rawValue

    var body: some View {
        Form {
            Section {
                ModuleSwitch(title: "Диктовка",
                             detail: enabled ? "Говорите — текст вставляется в приложение, где стоит курсор"
                                             : "Пока выключено, приложение не трогает микрофон и не загружает модель",
                             isOn: Binding(get: { enabled }, set: { Dictation.shared.setEnabled($0) }))
            }
            Section("Запись") {
                ShortcutRow(kind: .dictation)
                Toggle(isOn: $escCancels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Esc отменяет запись")
                        Text("Текст не вставляется").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $sounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Звуки")
                        Text("Начало записи, вставка текста, ошибка").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $yo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ставить ё в надиктованном")
                        Text("Модель почти всегда пишет «е»: «еще» → «ещё», как при наборе").font(.caption).foregroundStyle(.secondary)
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
            .active(enabled)
            ModelSections()
                .active(enabled)
            Section {
                Toggle(isOn: Binding(get: { voices }, set: { voices = $0; HotkeyMonitor.shared.installVoices() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Голосовые из Telegram")
                        Text("Расшифровка последних голосовых: в панели по клику на значок и по сочетанию клавиш")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ShortcutRow(kind: .voices)
                    .active(voices)
                LabeledContent {
                    Menu {
                        ForEach([1, 3, 7, 30], id: \.self) { days in
                            Button(Self.daysTitle(days)) { keepDays = days }
                        }
                    } label: {
                        Text(Self.daysTitle(keepDays))
                    }
                    .fixedSize()
                } label: {
                    Text("Хранить расшифровки")
                    Text("Показываются сразу; новые голосовые за это время расшифровываются при открытии")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .active(voices)
            } footer: {
                Text("Голосовые берутся из кеша приложения Telegram. Чтобы туда не попадали голосовые из групп, в Telegram → Настройки → Данные и память → Автозагрузка медиа оставьте голосовые только для личных чатов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .active(enabled)
        }
        .formStyle(.grouped)
        .toggleStyle(LightSwitchStyle())
    }

    static func daysTitle(_ days: Int) -> String {
        switch days {
        case 1: return String(localized: "1 день")
        case 3: return String(localized: "3 дня")
        default: return String(localized: "\(days) дней")
        }
    }
}

/// A macOS permission: granted (a check) or not (a warning and a button to System Settings).
struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var granted = false
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Есть").foregroundStyle(.secondary)
            } else {
                Button("Разрешить", action: action)
            }
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
