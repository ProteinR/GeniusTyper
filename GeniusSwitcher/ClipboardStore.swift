import AppKit
import CryptoKit

/// The clipboard history (replaces Maccy): watches the pasteboard, keeps text, images and files up
/// to a size limit in MB, and puts an entry back on the pasteboard to paste it.
///
/// Unlike the journal, the history holds the copied content itself: that is its purpose. It never
/// leaves the Mac: `~/Library/Application Support/GeniusSwitcher/clipboard/`, readable only by the
/// user. Copies from password managers, "do not watch" apps and private pasteboard types are skipped.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    static let directory = Journal.directory.deletingLastPathComponent().appendingPathComponent("clipboard", isDirectory: true)
    private static let indexFile = directory.appendingPathComponent("index.json")
    static let limits = [50, 100, 200, 500]

    @Published private(set) var items: [ClipboardItem] = []

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "clipboardHistory")
            enabled ? start() : stop()
        }
    }

    /// The size limit of the history, MB.
    @Published var limitMB: Int {
        didSet {
            UserDefaults.standard.set(limitMB, forKey: "clipboardLimitMB")
            apply(ClipboardRules.trim(items, limit: limitBytes))
        }
    }

    /// ⇧⌘C could not be registered: another app (Maccy) holds it.
    @Published private(set) var hotKeyTaken = false

    var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }
    private var limitBytes: Int { limitMB * 1_048_576 }

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var loaded = false
    /// Disk writes, off the main thread, in order.
    private let io = DispatchQueue(label: "clipboard.io", qos: .utility)
    private var thumbnails: [UUID: NSImage] = [:]
    private var icons: [String: NSImage] = [:]

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "clipboardHistory") as? Bool ?? true
        limitMB = defaults.object(forKey: "clipboardLimitMB") as? Int ?? 100
    }

    func start() {
        guard enabled, timer == nil else { return }
        if !loaded { load() }
        lastChange = NSPasteboard.general.changeCount
        // There is no "pasteboard changed" notification: every clipboard manager polls changeCount.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardStore.shared.poll() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        hotKeyTaken = !HotKey.register(keyCode: 8, modifiers: [.command, .shift]) {  // ⇧⌘C
            MainActor.assumeIsolated { ClipboardWindow.toggle() }
        }
        Log.info("Clipboard history: \(items.count) items, \(totalBytes / 1024) KB, hot key \(hotKeyTaken ? "taken" : "ok")", "clipboard")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        HotKey.unregister()
        hotKeyTaken = false
        ClipboardWindow.hide()
    }

    // MARK: Reading the pasteboard

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard !types.isEmpty, types.isDisjoint(with: ClipboardRules.ignoredTypes) else { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app, Observer.shared.excludedApps.contains(app) { return }
        guard let (item, payload) = capture(pasteboard, app: app) else { return }
        add(item, payload: payload)
    }

    /// The entry and the data to save next to it, by pasteboard type.
    private func capture(_ pasteboard: NSPasteboard, app: String?) -> (ClipboardItem, [String: Data])? {
        let id = UUID()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            return (ClipboardItem(id: id, date: Date(), kind: .files, app: app, text: paths, stored: [:],
                                  hash: Self.hash(Data(paths.utf8), kind: "files")), [:])
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            guard !ClipboardRules.isSecret(text) else { return nil }
            // Formatting, to paste it as it was copied.
            var payload: [String: Data] = [:]
            for type in [NSPasteboard.PasteboardType.rtf, .html] {
                if let data = pasteboard.data(forType: type), data.count < 5_000_000 { payload[type.rawValue] = data }
            }
            return (ClipboardItem(id: id, date: Date(), kind: .text, app: app, text: text,
                                  stored: payload.mapValues(\.count), hash: Self.hash(Data(text.utf8), kind: "text")), payload)
        }
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("public.heic"), .tiff] {
            guard var data = pasteboard.data(forType: type) else { continue }
            var stored = type
            // TIFF from the pasteboard is uncompressed (a 800×600 screenshot is 1.9 MB as TIFF, 0.4 MB as PNG).
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
                stored = .png
            }
            let size = Self.pixelSize(data)
            return (ClipboardItem(id: id, date: Date(), kind: .image, app: app, text: nil, stored: [stored.rawValue: data.count],
                                  width: size?.width, height: size?.height, hash: Self.hash(data, kind: "image")),
                    [stored.rawValue: data])
        }
        return nil
    }

    private static func hash(_ data: Data, kind: String) -> String {
        kind + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    // MARK: Changing the history

    private func add(_ item: ClipboardItem, payload: [String: Data]) {
        let folder = Self.folder(item.id)
        if !payload.isEmpty {
            io.async {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (type, data) in payload { try? data.write(to: folder.appendingPathComponent(type)) }
            }
        }
        apply(ClipboardRules.insert(item, into: items, limit: limitBytes))
    }

    func delete(_ item: ClipboardItem) {
        apply((items.filter { $0.id != item.id }, [item]))
    }

    func clear() {
        apply(([], items))
    }

    private func apply(_ change: (items: [ClipboardItem], removed: [ClipboardItem])) {
        items = change.items
        // An entry used again keeps its id: its folder stays.
        let kept = Set(items.map(\.id))
        let removed = change.removed.filter { !kept.contains($0.id) }
        let folders = removed.map { Self.folder($0.id) }
        removed.forEach { thumbnails[$0.id] = nil }
        save(removing: folders)
    }

    private func save(removing folders: [URL] = []) {
        let snapshot = items
        io.async {
            folders.forEach { try? FileManager.default.removeItem(at: $0) }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.indexFile, options: .atomic)
        }
    }

    private func load() {
        loaded = true
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: Self.indexFile),
           let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            items = saved
        }
        // Folders of entries the index does not know (the app quit before saving): leftovers.
        let known = Set(items.map(\.id.uuidString))
        let folders = (try? manager.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.hasDirectoryPath && !known.contains(folder.lastPathComponent) {
            try? manager.removeItem(at: folder)
        }
    }

    private static func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func data(_ item: ClipboardItem, type: String) -> Data? {
        try? Data(contentsOf: Self.folder(item.id).appendingPathComponent(type))
    }

    // MARK: Pasting

    /// Puts the entry on the pasteboard (it moves to the top, as a new copy) and, if `paste`,
    /// presses ⌘V in the app in front. `plain`: text without its formatting.
    func use(_ item: ClipboardItem, paste: Bool, plain: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            let entry = NSPasteboardItem()
            if !plain {
                for type in item.stored.keys {
                    if let data = data(item, type: type) { entry.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                }
            }
            entry.setString(item.text ?? "", forType: .string)
            pasteboard.writeObjects([entry])
        case .image:
            for type in item.stored.keys {
                if let data = data(item, type: type) { pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            }
        case .files:
            let urls = (item.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pasteboard.writeObjects(urls)
        }
        lastChange = pasteboard.changeCount
        var moved = item
        moved.date = Date()
        apply(ClipboardRules.insert(moved, into: items, limit: limitBytes))
        if paste {
            // After the history window is gone, so ⌘V goes to the app the user was in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { KeyPoster.pressPaste() }
        }
    }

    // MARK: Pictures for the window

    /// A small picture of an image entry for the list (cached), or a bigger one for the preview.
    func thumbnail(_ item: ClipboardItem, maxPixels: Int = 120) -> NSImage? {
        let cache = maxPixels <= 120
        if cache, let image = thumbnails[item.id] { return image }
        guard let type = item.stored.keys.first,
              let source = CGImageSourceCreateWithURL(Self.folder(item.id).appendingPathComponent(type) as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        if cache { thumbnails[item.id] = image }
        return image
    }

    func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[bundleID] = icon
        return icon
    }

    func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
