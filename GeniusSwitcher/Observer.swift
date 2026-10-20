import AppKit
import Carbon

/// Watches typing (listen-only, needs Input Monitoring), switches layouts with Caps Lock, fixes
/// words typed in the wrong layout (needs Accessibility to type) and writes the behaviour journal.
@MainActor
final class Observer: ObservableObject {
    static let shared = Observer()

    @Published private(set) var hasPermission = CGPreflightListenEventAccess()
    /// Changes with every word: watched only by the statistics window, not by the panel.
    let typing = TypingStats()
    /// The app typed in last (not Genius Switcher itself), for "do not watch in …".
    @Published private(set) var lastApp: (id: String, name: String)?

    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            reset()
            write([JournalEntry(t: Date(), kind: paused ? .pause : .resume)])
        }
    }

    @Published var capsLockSwitching: Bool {
        didSet {
            UserDefaults.standard.set(capsLockSwitching, forKey: "capsLockSwitching")
            capsLockSwitching ? CapsLockSwitch.install() : CapsLockSwitch.uninstall()
        }
    }

    /// Fix words typed in the wrong layout right after the space.
    @Published var autoFix: Bool {
        didSet {
            UserDefaults.standard.set(autoFix, forKey: "autoFix")
            if autoFix && !canPost { requestPostPermission() }
        }
    }

    /// Restore ё after the space: "еще" → "ещё" (`Yoficator`).
    @Published var yoFix: Bool {
        didSet {
            UserDefaults.standard.set(yoFix, forKey: "yoFix")
            if yoFix && !canPost { requestPostPermission() }
        }
    }

    /// Accessibility: Genius Switcher may type (needed for auto-fix only).
    @Published private(set) var canPost = KeyPoster.canPost

    /// Apps where auto-fix is off (the journal still runs there).
    @Published private(set) var autoOffApps: Set<String> {
        didSet { UserDefaults.standard.set(Array(autoOffApps), forKey: "autoOffApps") }
    }

    @Published private(set) var exceptionCount = 0

    /// The user's own exceptions dictionary (edited in the panel).
    @Published private(set) var userExceptions: UserExceptions {
        didSet { UserDefaults.standard.set(userExceptions.words, forKey: "userExceptions") }
    }

    @Published private(set) var excludedApps: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedApps), forKey: "excludedApps") }
    }

    /// Password managers: never watched.
    static let defaultExcluded: Set<String> = [
        "com.bitwarden.desktop", "com.yubico.yubioath", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7",
    ]

    let layouts = SystemLayouts()
    private var tracker: WordTracker
    private var recorder: Recorder
    private let journal = Journal()
    private var tap: CFMachPort?
    /// Swallows F18 (Caps Lock) so the focused app does not beep at an unknown key; needs Accessibility.
    private var capsTap: CFMachPort?
    private var timers: [Timer] = []
    private var currentApp: String?
    private var lastKeyTime: TimeInterval = 0
    private var knownLanguage: String?
    /// When Genius Switcher itself switched the layout (Caps Lock), to tell its switches from others.
    private var capsSwitchTime: TimeInterval = 0
    private var statsDay = Journal.file(for: Date()).lastPathComponent
    private var autoSwitchTime: TimeInterval = 0
    /// Logged once per launch, the mismatch itself is expected after every auto-switch.
    private var loggedEventMismatch = false
    private var lastFix: LastFix?
    private var skips = SkipCounter()
    private var exceptions: FixExceptions {
        didSet {
            UserDefaults.standard.set(Array(exceptions.hashes), forKey: "fixExceptions")
            exceptionCount = exceptions.hashes.count
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        paused = defaults.bool(forKey: "paused")
        capsLockSwitching = defaults.object(forKey: "capsLockSwitching") as? Bool ?? true
        excludedApps = (defaults.array(forKey: "excludedApps") as? [String]).map(Set.init) ?? Self.defaultExcluded
        autoFix = defaults.object(forKey: "autoFix") as? Bool ?? true
        yoFix = defaults.object(forKey: "yoFix") as? Bool ?? true
        autoOffApps = (defaults.array(forKey: "autoOffApps") as? [String]).map(Set.init) ?? AutoFixRules.defaultOff
        exceptions = FixExceptions(hashes: Set(defaults.array(forKey: "fixExceptions") as? [String] ?? []))
        exceptionCount = exceptions.hashes.count
        userExceptions = UserExceptions(words: defaults.stringArray(forKey: "userExceptions") ?? [])
        tracker = WordTracker(renderer: layouts)
        recorder = Recorder(renderer: layouts, detector: .system)
    }

    func start() {
        Journal.prune()
        Journal.load(Date()).forEach { typing.stats.add($0) }
        loadWeek()
        knownLanguage = layouts.currentLanguage()
        MenuBarIcon.shared.language = knownLanguage
        currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if capsLockSwitching { CapsLockSwitch.install() }
        write([JournalEntry(t: Date(), kind: .start)])

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.appActivated(app) }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // The hidutil mapping does not always survive sleep with a new keyboard attached.
            MainActor.assumeIsolated { if self.capsLockSwitching { CapsLockSwitch.install() } }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.layoutChanged() }
        }
        distributed.addObserver(forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.layouts.reload() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { self.write(self.recorder.expire(now: Date().timeIntervalSince1970)) }
        })

        Log.info("Permissions: Input Monitoring \(hasPermission ? "yes" : "no"), Accessibility \(canPost ? "yes" : "no"), auto-fix \(autoFix ? "on" : "off"), ё \(yoFix ? "on" : "off")", "keys")
        if (autoFix || yoFix) && !canPost { CGRequestPostEventAccess() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let can = KeyPoster.canPost
                if can != self.canPost {
                    self.canPost = can
                    Log.info("Accessibility (typing for auto-fix): \(can ? "granted" : "revoked")", "auto")
                    if can && self.hasPermission { self.installCapsTap() }
                }
            }
        })

        if hasPermission {
            installTap()
        } else {
            CGRequestListenEventAccess()
            timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard CGPreflightListenEventAccess() else { return }
                    timer.invalidate()
                    self.hasPermission = true
                    self.installTap()
                }
            })
        }
    }

    func stop() {
        if capsLockSwitching { CapsLockSwitch.uninstall() }
    }

    func requestPermission() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func loadWeek() {
        var week = DayStats()
        for day in 0..<7 {
            Journal.load(Date().addingTimeInterval(-Double(day) * 86_400)).forEach { week.add($0) }
        }
        typing.weekStats = week
    }

    func requestPostPermission() {
        CGRequestPostEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setAutoOff(_ bundleID: String, _ off: Bool) {
        if off { autoOffApps.insert(bundleID) } else { autoOffApps.remove(bundleID) }
    }

    func clearExceptions() {
        exceptions = FixExceptions()
    }

    func addUserException(_ text: String) {
        userExceptions.add(text)
        Log.info("User exceptions: \(userExceptions.words.count) words", "auto")
    }

    func removeUserException(_ word: String) {
        userExceptions.remove(word)
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        if excluded { excludedApps.insert(bundleID) } else { excludedApps.remove(bundleID) }
        reset()
    }

    func deleteJournal() {
        journal.deleteAll()
        typing.stats = DayStats()
        typing.weekStats = DayStats()
        typing.recentFixes = []
        Log.info("Journal deleted by the user", "journal")
    }

    // MARK: - Events

    private func installTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let observer = Unmanaged<Observer>.fromOpaque(refcon!).takeUnretainedValue()
            MainActor.assumeIsolated { observer.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("Cannot create the key tap (Input Monitoring missing?)", "keys")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Key tap installed; layouts \(layouts.summary)", "keys")
        installCapsTap()
    }

    /// A filtering tap ahead of the listen-only one, for F18 only: handles it and drops it, so it
    /// never reaches the app (text fields beep at F18). Without Accessibility it cannot be made;
    /// the listen-only tap then handles F18 and the app may beep.
    private func installCapsTap() {
        guard capsTap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue) | CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let observer = Unmanaged<Observer>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let tap = observer.capsTap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            guard UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == CapsLockSwitch.f18KeyCode,
                  event.getIntegerValueField(.eventSourceUserData) != KeyPoster.marker else {
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard observer.capsLockSwitching else { return false }
                if type == .keyDown { observer.handle(type: type, event: event) }
                return true
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.warning("Cannot create the Caps Lock tap (Accessibility missing?): F18 may beep", "caps")
            return
        }
        capsTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Caps Lock tap installed (F18 swallowed)", "caps")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Genius Switcher's own typing (auto-fix, undo).
        if event.getIntegerValueField(.eventSourceUserData) == KeyPoster.marker { return }
        guard type == .keyDown else {
            lastFix = nil
            reset()
            return
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if code == CapsLockSwitch.f18KeyCode {
            guard capsLockSwitching, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            if flags.contains(.maskShift) {
                CapsLockSwitch.toggleCapsLock()
            } else if undoLastFix() {
                return
            } else if retypeCurrentWord() {
                return
            } else {
                capsSwitchTime = Date().timeIntervalSince1970
                CapsLockSwitch.switchLayout(renderer: layouts)
            }
            return
        }

        guard !paused, !isExcluded else { return }
        let now = Date().timeIntervalSince1970
        lastKeyTime = now
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Shortcuts (⌘Z, ⌘V, ⌘⌫…) change the text in ways keys alone do not show.
            reset()
            return
        }
        var outputs: [TrackerOutput] = []
        var separator: (key: TypedKey, typed: String)?
        switch code {
        case 51:  // delete
            outputs = flags.contains(.maskAlternate) ? tracker.deleteWord(time: now) : tracker.backspace(time: now)
        case 49:
            separator = (TypedKey(code: code, shift: flags.contains(.maskShift), caps: false), " ")
            outputs = tracker.separator(" ", time: now)
        case 36, 76:
            outputs = tracker.separator("\n", time: now)
        case 48:
            outputs = tracker.separator("\t", time: now)
        case 117, 123, 124, 125, 126, 115, 119, 116, 121, 53:  // forward delete, arrows, home/end, page, esc
            outputs = tracker.reset(time: now)
        default:
            guard !flags.contains(.maskAlternate) else {
                // ⌥ + key types symbols outside both layouts.
                outputs = tracker.reset(time: now)
                break
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return }
            let typed = String(utf16CodeUnits: chars, count: length)
            let key = TypedKey(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            // The selected layout decides. The character in the event is not reliable: after a
            // switch made by another process (Switcher's own auto-fix) it keeps coming in the old
            // layout while the app already types in the new one.
            let eventLanguage = layouts.language(typing: typed, with: key)
            guard let language = layouts.currentLanguage() ?? eventLanguage ?? knownLanguage else {
                outputs = tracker.reset(time: now)
                break
            }
            if let eventLanguage, eventLanguage != language, !loggedEventMismatch {
                loggedEventMismatch = true
                Log.debug("Event character says \(eventLanguage), selected layout is \(language): using the layout", "keys")
            }
            if !layouts.isWordKey(key) { separator = (key, typed) }
            outputs = tracker.key(key, typed: typed, language: language, time: now)
        }
        write(recorder.record(outputs, app: currentApp))
        if let separator {
            // ⇧+Space: a plain space, the word stays as typed.
            let keep = code == 49 && flags.contains(.maskShift)
            autoFixIfNeeded(outputs, separator: separator, keep: keep, time: now)
        }
    }

    // MARK: - Auto-fix

    private func autoFixIfNeeded(_ outputs: [TrackerOutput], separator: (key: TypedKey, typed: String), keep: Bool, time: TimeInterval) {
        guard canPost, !(currentApp.map(autoOffApps.contains) ?? false) else { return }
        guard let word = outputs.lazy.compactMap({ output -> FinishedWord? in
            if case let .word(word) = output { return word } else { return nil }
        }).first,
              !word.mixed, AutoFixRules.fixes(after: word.endedBy) else { return }
        if autoFix, let target = layouts.other(than: word.language),
           !exceptions.contains(word.keys, language: word.language),
           !userExceptions.contains(word.keys, language: word.language, renderer: layouts),
           LayoutDetector.system.verdict(word.keys, language: word.language, renderer: layouts, trimEdges: false) == .fix {
            if keep {
                var entry = JournalEntry(t: Date(timeIntervalSince1970: time), kind: .autoSkip, app: currentApp)
                entry.from = word.language
                entry.len = word.keys.count
                write([entry])
                if skips.register(FixExceptions.hash(word.keys, language: word.language)) {
                    suggestException(word.keys, language: word.language)
                }
            } else {
                fixLayout(word, to: target, separator: separator, time: time)
            }
        } else if !keep {
            restoreYo(word, separator: separator, time: time)
        }
    }

    private func fixLayout(_ word: FinishedWord, to target: String, separator: (key: TypedKey, typed: String), time: TimeInterval) {
        let original = layouts.text(word.keys, language: word.language) + separator.typed
        let fixedSeparator = layouts.character(separator.key, language: target).map(String.init) ?? separator.typed
        let fixedWord = layouts.text(word.keys, language: target)
        let fixed = ((target == "ru" ? withYo(fixedWord) : nil) ?? fixedWord) + fixedSeparator
        recorder.markAutoFixed(word.id)
        // The text changed behind the tracker's back: start a fresh line.
        tracker = WordTracker(renderer: layouts)
        lastFix = LastFix(keys: word.keys, originalLanguage: word.language, fixedLanguage: target,
                          original: original, fixed: fixed, time: time)
        autoSwitchTime = time
        // A moment later, so the separator has reached the app before it is erased.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            KeyPoster.change(from: original, to: fixed)
            CapsLockSwitch.select(target, renderer: self.layouts)
        }
        var entry = JournalEntry(t: Date(timeIntervalSince1970: time), kind: .autoFix, app: currentApp)
        entry.from = word.language
        entry.to = target
        entry.len = word.keys.count
        write([entry])
        Log.debug("Auto-fix \(word.language)→\(target), \(word.keys.count) keys", "auto")
    }

    /// The Russian word with ё restored, unless ё is off or the word is in the exceptions.
    private func withYo(_ word: String) -> String? {
        guard yoFix, !userExceptions.contains(word) else { return nil }
        return Yoficator.shared.restore(word)
    }

    /// A Russian word typed with е where ё is always right: only the letters from the first ё on
    /// are retyped. Caps Lock right after puts е back, like an auto-fix.
    private func restoreYo(_ word: FinishedWord, separator: (key: TypedKey, typed: String), time: TimeInterval) {
        guard word.language == "ru" else { return }
        let typed = layouts.text(word.keys, language: word.language)
        guard typed.count == word.keys.count, let restored = withYo(typed) else { return }
        let original = typed + separator.typed
        let fixed = restored + separator.typed
        tracker = WordTracker(renderer: layouts)
        lastFix = LastFix(keys: word.keys, originalLanguage: word.language, fixedLanguage: word.language,
                          original: original, fixed: fixed, time: time)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            KeyPoster.change(from: original, to: fixed)
        }
        var entry = JournalEntry(t: Date(timeIntervalSince1970: time), kind: .yoFix, app: currentApp)
        entry.len = word.keys.count
        write([entry])
        Log.debug("ё restored, \(word.keys.count) keys", "yo")
    }

    /// Caps Lock right after an auto-fix, before any other key: puts the word back, returns to the
    /// original layout and offers to add the word to the exceptions.
    private func undoLastFix() -> Bool {
        let now = Date().timeIntervalSince1970
        guard let fix = lastFix, now - fix.time < LastFix.undoWindow, lastKeyTime <= fix.time else { return false }
        lastFix = nil
        capsSwitchTime = now
        KeyPoster.change(from: fix.fixed, to: fix.original)
        if fix.fixedLanguage != fix.originalLanguage { CapsLockSwitch.select(fix.originalLanguage, renderer: layouts) }
        suggestException(fix.keys, language: fix.originalLanguage)
        var entry = JournalEntry(t: Date(), kind: fix.fixedLanguage == fix.originalLanguage ? .yoUndo : .autoUndo, app: currentApp)
        entry.from = fix.fixedLanguage
        entry.to = fix.originalLanguage
        entry.len = fix.keys.count
        write([entry])
        Log.info("Auto-fix undone", "auto")
        return true
    }

    /// Caps Lock in the middle of a word: the letters typed so far are retyped in the other layout
    /// and the layout is switched, so the word goes on in the right one.
    private func retypeCurrentWord() -> Bool {
        guard canPost, !paused, !isExcluded, let word = tracker.currentWord,
              let target = layouts.other(than: word.language) else { return false }
        let typed = layouts.text(word.keys, language: word.language)
        let retyped = layouts.text(word.keys, language: target)
        guard typed.count == word.keys.count, retyped.count == word.keys.count else { return false }
        let now = Date().timeIntervalSince1970
        capsSwitchTime = now
        lastFix = nil
        KeyPoster.replace(deleting: typed.count, with: retyped)
        CapsLockSwitch.select(target, renderer: layouts)
        tracker.retypeCurrentWord(in: target)
        var entry = JournalEntry(t: Date(timeIntervalSince1970: now), kind: .capsFix, app: currentApp)
        entry.from = word.language
        entry.to = target
        entry.len = word.keys.count
        write([entry])
        Log.debug("Caps Lock mid-word: \(word.keys.count) keys retyped \(word.language)→\(target)", "auto")
        return true
    }

    /// A small window that does not take the focus: "«rtl» — в исключения?". The word exists only
    /// in memory until the user adds it.
    private func suggestException(_ keys: [TypedKey], language: String) {
        guard let word = UserExceptions.normalize(layouts.text(keys, language: language)),
              !userExceptions.contains(word) else { return }
        ExceptionSuggestion.show(word: word) { self.addUserException(word) }
    }

    private func layoutChanged() {
        let language = layouts.currentLanguage()
        MenuBarIcon.shared.language = language
        guard let language, language != knownLanguage else { return }
        let now = Date().timeIntervalSince1970
        let previous = knownLanguage
        knownLanguage = language
        guard !paused, !isExcluded else { return }
        var entry = JournalEntry(t: Date(), kind: .switchLayout, app: currentApp)
        entry.from = previous
        entry.to = language
        entry.method = now - autoSwitchTime < 1 ? "auto" : now - capsSwitchTime < 1 ? "caps" : "other"
        entry.context = tracker.position
        if lastKeyTime > 0 { entry.sinceKeySec = ((now - lastKeyTime) * 10).rounded() / 10 }
        write([entry])
    }

    private func appActivated(_ app: NSRunningApplication?) {
        lastFix = nil
        reset()
        currentApp = app?.bundleIdentifier
        if let app, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            lastApp = (id, app.localizedName ?? id)
        }
    }

    private var isExcluded: Bool {
        currentApp.map(excludedApps.contains) ?? false
    }

    private func reset() {
        write(recorder.record(tracker.reset(time: Date().timeIntervalSince1970), app: currentApp))
    }

    private func write(_ entries: [JournalEntry]) {
        guard !entries.isEmpty else { return }
        journal.append(entries)
        let today = Journal.file(for: Date()).lastPathComponent
        if today != statsDay {
            statsDay = today
            typing.stats = DayStats()
            loadWeek()
        }
        entries.forEach { typing.stats.add($0); typing.weekStats.add($0) }
        if recorder.recentFixes != typing.recentFixes { typing.recentFixes = recorder.recentFixes }
    }
}

/// Today's and the week's numbers and the last fixes, for the statistics window.
@MainActor
final class TypingStats: ObservableObject {
    @Published var stats = DayStats()
    /// The last 7 days including today.
    @Published var weekStats = DayStats()
    @Published var recentFixes: [String] = []
}
