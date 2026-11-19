import AVFoundation
import SwiftUI
import ProteinKit

/// The pages of Диктовка opened from its list.
enum DictationSubpage: String {
    case recognition, key, recording, indicator, history, voices

    var title: LocalizedStringKey {
        switch self {
        case .recognition: return "Распознавание"
        case .key: return "Клавиша"
        case .recording: return "Запись и вставка"
        case .indicator: return "Индикатор"
        case .history: return "История диктовок"
        case .voices: return "Голосовые из Telegram"
        }
    }
}

/// Диктовка: the switch, then a list of rows (as in MeetRec and System Settings), each opening its
/// own page, so nothing unfolds in place (asked 2026-11-19 after an interactive mockup). The
/// Telegram voices are one row with their switch; their page opens only while they are on.
/// While dictation is off the rest is grey and nothing records.
struct DictationPage: View {
    @ObservedObject var navigation: SettingsWindow.Navigation
    @ObservedObject private var store = EngineStore.shared
    @AppStorage("dictationEnabled") private var enabled = false
    @AppStorage("dictationSounds") private var sounds = true
    @AppStorage("escCancels") private var escCancels = true
    @AppStorage("dictationYo") private var yo = true
    @AppStorage("voicesEnabled") private var voices = false
    @AppStorage("voicesKeepDays") private var keepDays = 7
    @AppStorage("voicesSenders") private var senders = true
    @AppStorage("dictationKeepDays") private var dictationKeepDays = 0
    /// The stored voice texts and the dictations: how many and how much space, read on opening.
    @State private var stored = (count: 0, bytes: Int64(0))
    @State private var dictations = (count: 0, bytes: Int64(0))
    /// A shorter period chosen for the dictations: asked first, the older ones are deleted for good.
    @State private var shorterKeep: Int?
    @AppStorage("mascot") private var mascot = Mascot.none.rawValue
    @AppStorage("levelStyle") private var levelStyle = LevelStyle.bars.rawValue

    var body: some View {
        Group {
            if let sub = navigation.dictationSub {
                VStack(spacing: 0) {
                    SubpageHeader(back: "Диктовка", title: sub.title) { navigation.dictationSub = nil }
                    subpage(sub)
                }
            } else {
                list
            }
        }
        .toggleStyle(LightSwitchStyle(spreads: true))
        .onAppear(perform: countStored)
        .onChange(of: keepDays) { countStored() }
        .onChange(of: dictationKeepDays) {
            History.shared.prune(keepDays: dictationKeepDays)
            countStored()
        }
        .alert("Хранить диктовки \(Self.daysTitle(shorterKeep ?? 0))?",
               isPresented: Binding(get: { shorterKeep != nil }, set: { if !$0 { shorterKeep = nil } })) {
            Button("Удалить", role: .destructive) {
                if let shorterKeep { dictationKeepDays = shorterKeep }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Более старые удалятся без возврата, вместе со статистикой за то время.")
        }
    }

    private func open(_ sub: DictationSubpage) { navigation.dictationSub = sub }

    private var list: some View {
        Form {
            Section {
                ModuleSwitch(title: "Диктовка",
                             detail: enabled ? "Говорите — текст вставляется в приложение, где стоит курсор"
                                             : "Пока выключено, приложение не трогает микрофон и не загружает модель",
                             isOn: Binding(get: { enabled }, set: { Dictation.shared.setEnabled($0) }))
            }
            Section {
                SettingsLinkRow(symbol: "bolt.fill", tint: .indigo, title: "Распознавание", summary: store.summary) { open(.recognition) }
                SettingsLinkRow(symbol: "keyboard.fill", tint: .blue, title: "Клавиша",
                                summary: HotkeyMonitor.shared.shortcut.title + (escCancels ? String(localized: " · Esc отменяет") : "")) { open(.key) }
                SettingsLinkRow(symbol: "speaker.wave.2.fill", tint: .green, title: "Запись и вставка", summary: recordingSummary) { open(.recording) }
                SettingsLinkRow(symbol: "waveform", tint: .pink, title: "Индикатор", summary: indicatorSummary) { open(.indicator) }
                SettingsLinkRow(symbol: "clock.fill", tint: .orange, title: "История диктовок", summary: historySummary) { open(.history) }
            }
            .active(enabled)
            Section {
                SettingsLinkRow(symbol: "paperplane.fill", tint: .cyan, title: "Голосовые из Telegram",
                                summary: voices ? voicesSummary
                                                : String(localized: "Выключено. Расшифровывает голосовые из Telegram на этом Mac; включите, чтобы настроить"),
                                opens: voices, action: { open(.voices) }) {
                    Toggle("", isOn: voicesBinding).labelsHidden().fixedSize()
                }
            }
            .active(enabled)
        }
        .formStyle(.grouped)
    }

    private var voicesBinding: Binding<Bool> {
        Binding(get: { voices }, set: { voices = $0; HotkeyMonitor.shared.installVoices() })
    }

    private var recordingSummary: String {
        var parts = [sounds ? String(localized: "Звуки") : String(localized: "Без звуков")]
        if yo { parts.append(String(localized: "ё в надиктованном")) }
        return parts.joined(separator: " · ")
    }

    private var indicatorSummary: String {
        let style = (LevelStyle(rawValue: levelStyle) ?? .bars).title
        let animation = Mascot(rawValue: mascot) ?? .none
        return animation == .none ? style : "\(style) · \(animation.title)"
    }

    private var historySummary: String {
        String(localized: "Хранить: \(Self.daysTitle(dictationKeepDays).lowercased()) · диктовок: \(dictations.count) · \(ByteCountFormatter.string(fromByteCount: dictations.bytes, countStyle: .file))")
    }

    private var voicesSummary: String {
        String(localized: "\(HotkeyMonitor.shared.voicesShortcut.title) · хранить: \(Self.daysTitle(keepDays).lowercased()) · расшифровок: \(stored.count)")
    }

    @ViewBuilder
    private func subpage(_ sub: DictationSubpage) -> some View {
        switch sub {
        case .recognition:
            RecognitionPage()
        case .key:
            Form {
                Section {
                    ShortcutRow(kind: .dictation)
                    Toggle(isOn: $escCancels) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Esc отменяет запись")
                            Text("Текст не вставляется").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        case .recording:
            Form {
                Section {
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
                } footer: {
                    Text("Надиктованное, которое не вставилось, есть в окне истории буфера (⇧⌘C) на вкладке «Диктовки».")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .indicator:
            Form {
                Section {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Menu {
                                ForEach(LevelStyle.allCases) { item in
                                    Button(item.title) { levelStyle = item.rawValue }
                                }
                            } label: {
                                Text((LevelStyle(rawValue: levelStyle) ?? .bars).title)
                            }
                            .fixedSize()
                            Button("Показать") { Indicator.shared.demo() }
                        }
                    } label: {
                        Text("Индикатор")
                        Text("Как индикатор показывает громкость голоса").font(.caption).foregroundStyle(.secondary)
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
            }
            .formStyle(.grouped)
        case .history:
            Form {
                Section {
                    LabeledContent {
                        Menu {
                            ForEach([30, 90, 365, 0], id: \.self) { days in
                                Button(Self.daysTitle(days)) {
                                    if days != 0 && (dictationKeepDays == 0 || days < dictationKeepDays) {
                                        shorterKeep = days
                                    } else {
                                        dictationKeepDays = days
                                    }
                                }
                            }
                        } label: {
                            Text(Self.daysTitle(dictationKeepDays))
                        }
                        .fixedSize()
                    } label: {
                        Text("Хранить диктовки")
                        Text("Только текст, без звука. Статистика считается по истории: старые диктовки уходят и из неё")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Диктовок: \(dictations.count) · \(ByteCountFormatter.string(fromByteCount: dictations.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent {
                        Button("Открыть") { SettingsWindow.shared.show(history: .dictations) }
                    } label: {
                        Text("Все диктовки")
                        Text("Поиск, копирование, удаление. Быстрее — ⇧⌘C, вкладка «Диктовки»").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        case .voices:
            Form {
                Section {
                    Toggle(isOn: voicesBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Голосовые из Telegram")
                            Text("Расшифровка последних голосовых: в панели по клику на значок и по сочетанию клавиш")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ShortcutRow(kind: .voices)
                        .active(voices)
                    Toggle(isOn: $senders) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Показывать отправителя")
                            Text("Имя берётся из базы Telegram на этом Mac (только чтение). Не работает, если в Telegram включён код-пароль")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .active(voices)
                    LabeledContent {
                        Menu {
                            ForEach([1, 3, 7, 30, 0], id: \.self) { days in
                                Button(Self.daysTitle(days)) { keepDays = days }
                            }
                        } label: {
                            Text(Self.daysTitle(keepDays))
                        }
                        .fixedSize()
                    } label: {
                        Text("Хранить расшифровки")
                        Text(keepDays == 0
                             ? "Показываются сразу; новые голосовые за последние 7 дней расшифровываются при открытии"
                             : "Показываются сразу; новые голосовые за это время расшифровываются при открытии")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Расшифровок: \(stored.count) · \(ByteCountFormatter.string(fromByteCount: stored.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .active(voices)
                } footer: {
                    Text("Голосовые берутся из кеша приложения Telegram. Чтобы туда не попадали голосовые из групп, в Telegram → Настройки → Данные и память → Автозагрузка медиа оставьте голосовые только для личных чатов.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func countStored() {
        stored = (VoiceTranscripts.shared.storedCount, VoiceTranscripts.storedBytes)
        dictations = (History.shared.count(), History.shared.bytes)
    }

    static func daysTitle(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "Всегда")
        case 1: return String(localized: "1 день")
        case 3: return String(localized: "3 дня")
        case 365: return String(localized: "1 год")
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
