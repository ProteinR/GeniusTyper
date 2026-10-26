import AppKit
import SwiftUI

@main
struct DiktantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar icon is made by AppDelegate (see StatusItemController); SwiftUI needs at
        // least one scene.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// "0.1.0", shown in the settings window.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var statusItem: StatusItemController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Prefs.register()
        // Writing to the engine helper after it died must fail with an error, not kill Diktant.
        signal(SIGPIPE, SIG_IGN)
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("Diktant \(Self.appVersion) (\(build)) started; engine \(EngineStore.shared.selected.rawValue), key \(HotkeyMonitor.shared.shortcut.title)")
        let statusItem = StatusItemController()
        self.statusItem = statusItem
        Dictation.shared.onPhase = { statusItem.show($0) }
        Dictation.shared.start()

        // First launch: the model and the permissions.
        let store = EngineStore.shared
        if store.selected.isLocal, store.local == .missing { store.downloadLocal() }
        if !Paster.isTrusted || AudioRecorder.permission == .notDetermined {
            SettingsWindow.shared.show()
        }
        if AudioRecorder.permission == .notDetermined {
            Task { _ = await AudioRecorder.requestPermission() }
        }
        if !Paster.isTrusted { Paster.askForAccessibility() }

        // `--open-settings [general|model|history|statistics]`: for screenshots.
        if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let page = CommandLine.arguments.dropFirst(index + 1).first.flatMap(SettingsPage.init(rawValue:))
            SettingsWindow.shared.show(page: page)
        }
        if CommandLine.arguments.contains("--stress-test") { runStressTest() }
        // `--menu [voices|history]`: the left-click panel, optionally with a side column open.
        if let index = CommandLine.arguments.firstIndex(of: "--menu") {
            let side = CommandLine.arguments.dropFirst(index + 1).first
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { statusItem.openPanel(side: side) }
        }
        if CommandLine.arguments.contains("--indicator-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Indicator.shared.demo() }
        }
        if CommandLine.arguments.contains("--voices") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { VoicePanel.shared.show() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe-file"), index + 1 < CommandLine.arguments.count {
            transcribeFile(CommandLine.arguments[index + 1])
        }
        Memory.giveBackSoon()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Diktant quit")
    }

    /// Opened again from Spotlight or Finder: show the settings (the icon may be hidden).
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    /// `--stress-test`: three rounds of opening every page of the settings window, then loading and
    /// transcribing 5 s of silence with the local model and unloading it, logging the memory
    /// footprint after each step. Growing every round = a leak.
    @MainActor
    private func runStressTest() {
        var cycle = 0
        @MainActor func round() {
            guard cycle < 3 else {
                Log.info("Stress test done: footprint \(Self.footprintMB()) MB", "stress")
                return
            }
            cycle += 1
            var pages = SettingsPage.allCases
            @MainActor func nextPage() {
                guard !pages.isEmpty else {
                    SettingsWindow.shared.close()
                    model()
                    return
                }
                let page = pages.removeFirst()
                let start = CACurrentMediaTime()
                SettingsWindow.shared.show(page: page)
                SettingsWindow.shared.layoutNow()
                let took = (CACurrentMediaTime() - start) * 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        Log.info(String(format: "Stress round %d: %@ opened in %.0f ms, footprint %@ MB", cycle, page.rawValue, took, Self.footprintMB()), "stress")
                        nextPage()
                    }
                }
            }
            @MainActor func model() {
                guard ParakeetEngine.isDownloaded else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { round() } }
                    return
                }
                Task { @MainActor in
                    let start = Date()
                    let text = (try? await EngineStore.shared.transcribe([Float](repeating: 0, count: 16_000 * 5))) ?? "error"
                    let helper = await EngineStore.shared.parakeet.helperFootprintMB ?? 0
                    Log.info(String(format: "Stress round %d: model loaded and ran in %.2f s (\"%@\"), footprint %@ MB + helper %.1f MB", cycle,
                                    Date().timeIntervalSince(start), text, Self.footprintMB(), helper), "stress")
                    EngineStore.shared.unloadNow()
                    try? await Task.sleep(for: .seconds(4))
                    Log.info("Stress round \(cycle): model unloaded, footprint \(Self.footprintMB()) MB", "stress")
                    round()
                }
            }
            nextPage()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                Log.info("Stress test start: footprint \(Self.footprintMB()) MB", "stress")
                round()
            }
        }
    }

    /// `--transcribe-file <audio>`: transcribes a file with the current engine (no microphone, no
    /// paste) and logs the text, the time and the footprint; for checking the model on prepared
    /// speech (`say -v Milena -o test.aiff "…"`).
    @MainActor
    private func transcribeFile(_ path: String) {
        Task { @MainActor in
            do {
                let samples = try AudioRecorder.samples(fromFile: URL(fileURLWithPath: path))
                Log.info("Transcribe file: \(path), \(samples.count / 16_000) s, footprint \(Self.footprintMB()) MB", "test")
                for run in 1...2 {
                    let start = Date()
                    let text = try await EngineStore.shared.transcribe(samples)
                    let helper = await EngineStore.shared.parakeet.helperFootprintMB ?? 0
                    Log.info(String(format: "Transcribe file run %d: %.2f s, footprint %@ MB + helper %.1f MB: %@", run,
                                    Date().timeIntervalSince(start), Self.footprintMB(), helper, text), "test")
                }
            } catch {
                Log.error("Transcribe file failed: \(Log.describe(error))", "test")
            }
        }
    }

    /// The memory footprint, as Activity Monitor shows it.
    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }
}

/// After a window closes or the model unloads, the freed memory stays with the allocator for
/// reuse; this hands it back to macOS so the footprint drops back (as in MXCtl).
enum Memory {
    @MainActor
    static func giveBackSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let freed = malloc_zone_pressure_relief(nil, 0)
            Log.debug("Memory given back: \(freed / 1024) KB, footprint now \(AppDelegate.footprintMB()) MB", "memory")
        }
    }
}
