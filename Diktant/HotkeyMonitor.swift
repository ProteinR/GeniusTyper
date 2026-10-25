import AppKit
import Carbon.HIToolbox

/// Watches the dictation key and reports press / release.
///
/// Kept cheap while idle: a single modifier is watched with an event tap on modifier changes only
/// (not every typed key); a key combination is a Carbon hot key (no tap at all). Every key is
/// watched only while recording, for Esc (cancel) and for "the modifier was part of a shortcut".
/// The taps are active ones (they pass everything through), so they need Accessibility only, which
/// Diktant needs anyway to paste; a listen-only tap would also need Input Monitoring.
@MainActor
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Esc while recording (swallowed).
    var onEscape: () -> Void = {}
    /// Another key or modifier pressed while the dictation modifier is held: it was ⌥+something.
    var onChord: () -> Void = {}

    private(set) var shortcut = Shortcut.load()
    /// Set while the settings window records a new key: presses are not acted on.
    var isPaused = false

    private var modifierTap: CFMachPort?
    private var modifierSource: CFRunLoopSource?
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var modifierDown = false

    var isInstalled: Bool { modifierTap != nil || hotKeyRef != nil }

    func start() {
        install()
        // Accessibility granted later: install then (the notification is posted on every change).
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let self, !self.isInstalled || self.shortcut.isModifierOnly && self.modifierTap == nil else { return }
                    self.install()
                }
            }
        }
    }

    func setShortcut(_ new: Shortcut) {
        shortcut = new
        new.save()
        Log.info("Dictation key: \(new.title)", "keys")
        install()
    }

    /// (Re)installs the watcher for the current key.
    func install() {
        uninstall()
        modifierDown = false
        if shortcut.isModifierOnly {
            installModifierTap()
        } else {
            installHotKey()
        }
    }

    private func uninstall() {
        if let modifierSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), modifierSource, .commonModes) }
        if let modifierTap { CFMachPortInvalidate(modifierTap) }
        modifierTap = nil
        modifierSource = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    // MARK: - A single modifier

    private func installModifierTap() {
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleModifier(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.warning("Cannot watch \(shortcut.title): Accessibility not granted", "keys")
            return
        }
        modifierTap = tap
        modifierSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), modifierSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Watching \(shortcut.title)", "keys")
    }

    private func handleModifier(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let modifierTap { CGEvent.tapEnable(tap: modifierTap, enable: true) }
            return
        }
        guard type == .flagsChanged, let key = Shortcut.modifierKeys[shortcut.keyCode] else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = event.flags.rawValue & key.deviceMask != 0
        if code == shortcut.keyCode {
            guard isDown != modifierDown else { return }
            modifierDown = isDown
            guard !isPaused else { return }
            isDown ? onPress() : onRelease()
        } else if modifierDown, Shortcut.modifierKeys[code] != nil, !isPaused {
            // ⌥⌘, ⌥⇧…: a shortcut, not dictation.
            onChord()
        }
    }

    // MARK: - A key combination

    private func installHotKey() {
        if hotKeyHandler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let monitor = HotkeyMonitor.shared
                        guard !monitor.isPaused else { return }
                        pressed ? monitor.onPress() : monitor.onRelease()
                    }
                }
                return noErr
            }, 2, &types, nil, &hotKeyHandler)
        }
        var carbon: UInt32 = 0
        let flags = shortcut.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        let id = EventHotKeyID(signature: OSType(0x444B_5459), id: 1) // "DKTY"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbon, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            Log.info("Hot key \(shortcut.title) registered", "keys")
        } else {
            hotKeyRef = nil
            Log.warning("Hot key \(shortcut.title) not registered (\(status)): taken by another app?", "keys")
        }
    }

    // MARK: - While recording

    /// Every key is watched only while recording: Esc cancels, another key while the dictation
    /// modifier is still held means it was ⌥+key.
    func watchKeys(_ on: Bool) {
        if !on {
            if let keySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, .commonModes) }
            if let keyTap { CFMachPortInvalidate(keyTap) }
            keyTap = nil
            keySource = nil
            return
        }
        guard keyTap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { monitor.handleKey(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.warning("Cannot watch Esc: Accessibility not granted", "keys")
            return
        }
        keyTap = tap
        keySource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), keySource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// True = swallow the event.
    private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if code == UInt16(kVK_Escape), Prefs.escCancels {
            onEscape()
            return true
        }
        if modifierDown, shortcut.isModifierOnly { onChord() }
        return false
    }
}
