import AVFoundation
import SwiftUI

/// Основное: login, the menu bar icon, and every permission the app needs in one place.
struct GeneralPage: View {
    @ObservedObject private var observer = Observer.shared
    @ObservedObject private var icon = MenuBarIcon.shared
    @AppStorage("dictationEnabled") private var dictation = false
    @State private var microphone = AudioRecorder.permission

    var body: some View {
        Form {
            Section("Система") {
                LoginItemToggle()
                Toggle(isOn: $icon.isShown) {
                    Text("Значок в строке меню")
                    Text("Без значка всё продолжает работать; настройки открываются повторным запуском из Spotlight или Finder")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    Menu {
                        ForEach(MenuBarIcon.LanguageMark.allCases) { mark in
                            Button(mark.title) { icon.languageMark = mark }
                        }
                    } label: {
                        Text(icon.languageMark.title)
                    }
                    .fixedSize()
                } label: {
                    Text("Язык на значке")
                    Text("Заменяет системный значок языка: его можно убрать в Системных настройках → Клавиатура → Источники ввода")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $icon.showsSymbol) {
                    Text("Язык рядом с иконкой")
                    Text("Выключено — на значке только язык, крупно").font(.caption).foregroundStyle(.secondary)
                }
                .active(icon.languageMark != .none)
            }
            Section("Разрешения") {
                PermissionRow(title: "Мониторинг ввода", detail: "Чтобы видеть нажатия: Caps Lock, исправление раскладки",
                              granted: observer.hasPermission) { observer.requestPermission() }
                PermissionRow(title: "Универсальный доступ", detail: "Чтобы исправлять текст, вставлять из буфера и надиктованное",
                              granted: observer.canPost) { observer.requestPostPermission() }
                if dictation {
                    PermissionRow(title: "Микрофон", detail: "Чтобы записывать голос для диктовки",
                                  granted: microphone == .authorized) {
                        if microphone == .notDetermined {
                            Task { _ = await AudioRecorder.requestPermission(); microphone = AudioRecorder.permission }
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                } else {
                    LabeledContent("Микрофон") {
                        Text("не нужен, пока диктовка выключена").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(LightSwitchStyle())
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Input Monitoring and Accessibility are polled by the Observer; the microphone is read here.
    private func refresh() {
        microphone = AudioRecorder.permission
    }
}

/// Раскладка: Caps Lock (works even when fixing is off), then fixing with its own switch.
struct TypingPage: View {
    @ObservedObject private var observer = Observer.shared

    var body: some View {
        Form {
            Section {
                ModuleSwitch(title: "Исправлять текст",
                             detail: observer.paused
                                 ? "Выключено: ничего не исправляется и не пишется в журнал"
                                 : "Слова не в той раскладке и ё — сразу после пробела",
                             isOn: Binding(get: { !observer.paused }, set: { observer.paused = !$0 }))
                if !observer.paused && (observer.autoFix || observer.yoFix) && !observer.canPost {
                    PermissionRow(title: "Нужен «Универсальный доступ»", detail: "Без него текст не исправляется") {
                        observer.requestPostPermission()
                    }
                }
            }
            Section {
                Toggle(isOn: $observer.autoFix) {
                    Text("Исправлять раскладку")
                    Text("«ghbdtn» → «привет»: слово, набранное не в той раскладке, перепечатывается после пробела")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $observer.yoFix) {
                    Text("Ставить ё")
                    Text("«еще» → «ещё», только где ё точно нужна (не в «все», «узнаем»)").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Изменить…") { ExceptionsEditor.show(.apps) }
                } label: {
                    Text("Не исправлять в приложениях")
                    Text(appsSummary).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Изменить…") { ExceptionsEditor.show(.words) }
                } label: {
                    Text("Слова-исключения")
                    Text(wordsSummary).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("**⇧ + пробел** — не исправлять это слово · **Caps Lock** сразу после исправления — отменить его")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .active(!observer.paused)
            Section {
                Toggle(isOn: $observer.capsLockSwitching) {
                    Text("Переключать раскладку клавишей Caps Lock")
                    Text("Одно нажатие — другой язык. Заглавные буквы — ⇧ + Caps Lock").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Caps Lock")
            } footer: {
                if observer.capsLockSwitching {
                    Text("Посреди слова Caps Lock ещё и перепечатывает набранное в другой раскладке, дважды подряд — всю фразу. Это работает, пока включено «Исправлять текст».")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(LightSwitchStyle())
    }

    private var appsSummary: String {
        let count = observer.autoOffApps.count
        return count == 0 ? "нет" : "\(count) — терминалы, редакторы кода и ваши"
    }

    private var wordsSummary: String {
        let words = observer.userExceptions.words
        if words.isEmpty { return "нет" }
        let shown = words.prefix(6).joined(separator: ", ")
        return words.count > 6 ? "\(shown) и ещё \(words.count - 6)" : shown
    }
}

/// Буфер обмена: the history's switch, its shortcut and size.
struct ClipboardPage: View {
    @ObservedObject private var clipboard = ClipboardStore.shared
    @State private var confirmClear = false

    /// Two apps can register the same global shortcut; the one registered last gets it.
    private var maccyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.p0deje.Maccy").isEmpty
    }

    var body: some View {
        Form {
            Section {
                ModuleSwitch(title: "История буфера обмена",
                             detail: clipboard.enabled ? "Всё скопированное хранится на этом Mac; пароли и данные из менеджеров паролей — нет"
                                                       : "Выключено: скопированное не сохраняется",
                             isOn: $clipboard.enabled)
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        HotKeyRecorder(clipboard: clipboard)
                        Button("Открыть") { ClipboardWindow.show() }
                    }
                } label: {
                    Text("Открывать")
                    Text("Сочетание работает в любой раскладке").font(.caption).foregroundStyle(.secondary)
                }
                if maccyRunning {
                    Label("Запущен Maccy: он тоже открывается по ⇧⌘C и перехватывает это сочетание. Закройте его или выберите другое",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if clipboard.hotKeyTaken {
                    Label("\(clipboard.hotKey.title) занято другим приложением: выберите другое сочетание",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Хранить до") {
                    Menu {
                        ForEach(ClipboardStore.limits, id: \.self) { limit in
                            Button("\(limit) МБ") { clipboard.limitMB = limit }
                        }
                    } label: {
                        Text("\(clipboard.limitMB) МБ")
                    }
                    .fixedSize()
                }
                ClipboardUsageRow(usage: clipboard.usage) { confirmClear = true }
            } footer: {
                Text("В истории: ⏎ — вставить, ⌥⏎ — только скопировать, ⇧⏎ — без оформления, ⌘1…9, ⌥⌫ — удалить")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .active(clipboard.enabled)
        }
        .formStyle(.grouped)
        .toggleStyle(LightSwitchStyle())
        .alert("Очистить историю буфера?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { clipboard.clear() }
            Button("Отмена", role: .cancel) {}
        }
    }
}

/// The shortcut as a button: click, then press the new combination (Esc cancels).
private struct HotKeyRecorder: View {
    @ObservedObject var clipboard: ClipboardStore
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Нажмите сочетание…" : clipboard.hotKey.title) {
            recording ? stop() : start()
        }
        .help("Нажмите и введите новое сочетание: нужна ⌘, ⌥ или ⌃. Esc — отмена")
        .onDisappear { if recording { stop() } }
        // The window lost the focus while recording: the old shortcut comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        HotKey.unregister()  // pressing the current one now must not open the window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combo = KeyCombo(keyCode: event.keyCode,
                                 modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            MainActor.assumeIsolated { record(combo) }
            return nil
        }
    }

    private func record(_ combo: KeyCombo) {
        if combo.keyCode == 53 && combo.flags.isEmpty {  // Esc
            stop()
        } else if combo.isUsable {
            clipboard.hotKey = combo
            stop()
        } else {
            NSSound.beep()
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        clipboard.registerHotKey()
    }
}

/// "1,5 МБ, 70 записей · Очистить…": the only part of the page that changes with every copy.
private struct ClipboardUsageRow: View {
    @ObservedObject var usage: ClipboardUsage
    let clear: () -> Void

    var body: some View {
        LabeledContent("Занято") {
            HStack(spacing: 8) {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(usage.value.bytes), countStyle: .file)), \(usage.value.count) зап.")
                    .foregroundStyle(.secondary)
                Button("Очистить…", action: clear)
                    .disabled(usage.value.count == 0)
            }
        }
    }
}

/// Статистика: typing (the journal) or dictation (the history).
struct StatisticsPage: View {
    enum Kind: String { case typing, dictation }
    @AppStorage("statsKind") private var kind = Kind.typing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segments(items: [(Kind.typing, "Печать"), (.dictation, "Диктовка")], selection: $kind)
                .padding([.horizontal, .top], 18)
            switch kind {
            case .typing: ScrollView { TypingStatsView() }
            case .dictation: DictationStatsView()
            }
        }
    }
}
