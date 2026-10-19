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

    nonisolated static let directory = Journal.directory.deletingLastPathComponent().appendingPathComponent("clipboard", isDirectory: true)
    nonisolated private static let indexFile = directory.appendingPathComponent("index.json")
    static let limits = [50, 100, 200, 500]

    /// Not published: only the history window reads it, when it opens. The panel watches `usage`.
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            let new = ClipboardUsage.Value(count: items.count, bytes: totalBytes)
            if usage.value != new { usage.value = new }
        }
    }
    let usage = ClipboardUsage()

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

    /// Opens the history window (⇧⌘C, as in Maccy).
    @Published var hotKey: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(hotKey) { UserDefaults.standard.set(data, forKey: "clipboardHotKey") }
            registerHotKey()
        }
    }

    /// The shortcut could not be registered: another app holds it.
    @Published private(set) var hotKeyTaken = false

    var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }
    private var limitBytes: Int { limitMB * 1_048_576 }

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var loaded = false
    /// Disk writes, off the main thread, in order.
    private let io = DispatchQueue(label: "clipboard.io", qos: .utility)
    private var saveWork: DispatchWorkItem?
    /// Pictures of the rows on screen: a few KB each, decoded from the small thumbnail files.
    private let thumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 100
        return cache
    }()
    private var icons: [String: NSImage] = [:]

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "clipboardHistory") as? Bool ?? true
        limitMB = defaults.object(forKey: "clipboardLimitMB") as? Int ?? 100
        hotKey = defaults.data(forKey: "clipboardHotKey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .clipboardDefault
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
        registerHotKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { if ClipboardStore.shared.enabled { ClipboardWindow.prepare() } }
        }
        Log.info("Clipboard history: \(items.count) items, \(totalBytes / 1024) KB, hot key \(hotKey.title) \(hotKeyTaken ? "taken" : "ok")", "clipboard")
    }

    /// Also after recording a new shortcut (recording turns the old one off, so it is not triggered).
    func registerHotKey() {
        guard enabled, timer != nil else { return }
        hotKeyTaken = !HotKey.register(keyCode: UInt32(hotKey.keyCode), modifiers: hotKey.flags) {
            MainActor.assumeIsolated { ClipboardWindow.toggle() }
        }
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
        guard let copied = read(pasteboard) else { return }
        // Hashing, TIFF → PNG and the thumbnail take long for big images: off the main thread.
        let limit = limitBytes
        io.async {
            guard let (item, payload, thumbnail) = Self.process(copied, app: app) else { return }
            Self.write(item.id, payload: payload, thumbnail: thumbnail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = ClipboardStore.shared
                    store.apply(ClipboardRules.insert(item, into: store.items, limit: limit))
                    // Decoding a big image for its thumbnail takes tens of MB for a moment.
                    if item.kind == .image { Memory.giveBackSoon() }
                }
            }
        }
    }

    /// What was copied, as read from the pasteboard (on the main thread, as AppKit wants).
    private enum Copied {
        case files([String])
        case text(String, formats: [String: Data])
        case image(Data, type: String)
    }

    private func read(_ pasteboard: NSPasteboard) -> Copied? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            // Formatting, to paste it as it was copied.
            var formats: [String: Data] = [:]
            for type in [NSPasteboard.PasteboardType.rtf, .html] {
                if let data = pasteboard.data(forType: type), data.count < 5_000_000 { formats[type.rawValue] = data }
            }
            return .text(text, formats: formats)
        }
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("public.heic"), .tiff] {
            if let data = pasteboard.data(forType: type) { return .image(data, type: type.rawValue) }
        }
        return nil
    }

    /// The entry, the data to save next to it by pasteboard type, and a small picture for the list.
    nonisolated private static func process(_ copied: Copied, app: String?) -> (ClipboardItem, [String: Data], Data?)? {
        let id = UUID()
        switch copied {
        case .files(let paths):
            let text = paths.joined(separator: "\n")
            return (ClipboardItem(id: id, date: Date(), kind: .files, app: app, text: text, stored: [:],
                                  hash: hash(Data(text.utf8), kind: "files")), [:], nil)
        case .text(let text, let formats):
            guard !ClipboardRules.isSecret(text) else { return nil }
            return (ClipboardItem(id: id, date: Date(), kind: .text, app: app, text: text,
                                  stored: formats.mapValues(\.count), hash: hash(Data(text.utf8), kind: "text")), formats, nil)
        case .image(var data, var type):
            // TIFF from the pasteboard is uncompressed (a 800×600 screenshot is 1.9 MB as TIFF, 0.4 MB as PNG).
            if type == NSPasteboard.PasteboardType.tiff.rawValue,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
                type = NSPasteboard.PasteboardType.png.rawValue
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return (ClipboardItem(id: id, date: Date(), kind: .image, app: app, text: nil, stored: [type: data.count],
                                  width: properties?[kCGImagePropertyPixelWidth] as? Int,
                                  height: properties?[kCGImagePropertyPixelHeight] as? Int, hash: hash(data, kind: "image")),
                    [type: data], thumbnail(source))
        }
    }

    /// A PNG of at most `thumbnailPixels` on the long side: the list shows it 40 pt high.
    nonisolated static let thumbnailPixels = 160
    nonisolated private static let thumbnailFile = "thumbnail"

    nonisolated private static func thumbnail(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    nonisolated private static func hash(_ data: Data, kind: String) -> String {
        kind + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func write(_ id: UUID, payload: [String: Data], thumbnail: Data?) {
        guard !payload.isEmpty else { return }
        let folder = folder(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (type, data) in payload { try? data.write(to: folder.appendingPathComponent(type)) }
        try? thumbnail?.write(to: folder.appendingPathComponent(thumbnailFile))
    }

    // MARK: Changing the history

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
        removed.forEach { thumbnails.removeObject(forKey: $0.id as NSUUID) }
        save(removing: folders)
    }

    /// Removed entries' folders go at once; the index (all entries with their texts) is written
    /// at most every 2 s, and when the app quits.
    private func save(removing folders: [URL] = []) {
        if !folders.isEmpty {
            io.async { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        }
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = items
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.indexFile, options: .atomic)
        }
    }

    /// Waits for the disk writes (quitting).
    func flush() {
        if saveWork != nil { saveNow() }
        io.sync {}
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

    nonisolated private static func folder(_ id: UUID) -> URL {
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

    /// The small picture of an image entry, for the list.
    func thumbnail(_ item: ClipboardItem) -> NSImage? {
        if let image = thumbnails.object(forKey: item.id as NSUUID) { return image }
        let file = Self.folder(item.id).appendingPathComponent(Self.thumbnailFile)
        if !FileManager.default.fileExists(atPath: file.path) {
            // Entries of 0.6.0 had none.
            guard let type = item.stored.keys.first,
                  let source = CGImageSourceCreateWithURL(Self.folder(item.id).appendingPathComponent(type) as CFURL, nil),
                  let data = Self.thumbnail(source) else { return nil }
            try? data.write(to: file)
        }
        guard let image = image(file, maxPixels: Self.thumbnailPixels) else { return nil }
        thumbnails.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    /// The image of an entry for the preview, downscaled to `maxPixels` (not cached).
    func previewImage(_ item: ClipboardItem, maxPixels: Int) -> NSImage? {
        guard let type = item.stored.keys.first else { return nil }
        return image(Self.folder(item.id).appendingPathComponent(type), maxPixels: maxPixels)
    }

    private func image(_ file: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }

    func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // Drawn once into a 16 pt bitmap: the app's own icon keeps every size up to 1024 px.
        let full = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 16, height: 16)
        let icon = NSImage(size: size, flipped: false) { rect in
            full.draw(in: rect)
            return true
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(16 * scale), pixelsHigh: Int(16 * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            full.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            let small = NSImage(size: size)
            small.addRepresentation(bitmap)
            icons[bundleID] = small
            return small
        }
        icons[bundleID] = icon
        return icon
    }

    func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// How many entries and bytes the history holds: shown in the panel.
@MainActor
final class ClipboardUsage: ObservableObject {
    struct Value: Equatable {
        var count = 0
        var bytes = 0
    }

    @Published var value = Value()
}
