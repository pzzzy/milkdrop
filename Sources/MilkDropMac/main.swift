import AppKit
import MetalKit
import MilkDropCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var renderer: MilkDropRenderer!
    private let capture = SystemAudioCapture()
    private var presetURLs: [URL] = []
    private var presetIndex = 0
    private let lockedPresetName = ProcessInfo.processInfo.environment["MILKDROP_PRESET"]
    private let backgroundTest = ProcessInfo.processInfo.environment["MILKDROP_BACKGROUND_TEST"] == "1"
    private lazy var launchPolicy = MilkDropLaunchPolicy(backgroundTest: backgroundTest)
    private let presetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let performanceLabel = NSTextField(labelWithString: "Starting Metal…")
    private var cursorTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(backgroundTest ? .accessory : .regular)
        guard let initial = try? MilkPreset.parse("[preset00]\nfDecay=0.985\nwave_r=0.55\nwave_g=0.8\nwave_b=1.0\nwarp=1.0", name: "MilkDrop Modern") else {
            RuntimeLog.write("FATAL • built-in fallback preset failed to parse")
            NSApp.terminate(nil)
            return
        }
        let view = MTKView(frame: .zero)
        renderer = MilkDropRenderer(view: view, analyzer: capture.analyzer, preset: initial)
        guard renderer != nil else { NSApp.terminate(nil); return }

        // Prefer the largest native desktop surface; on the test system this is the 3840×2160 120 Hz display.
        let targetScreen = NSScreen.screens.max { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }
        let initialFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        window = KeyWindow(contentRect: initialFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false, screen: targetScreen)
        window.title = "MilkDrop for macOS"
        window.contentView = view
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling, .managed]
        window.delegate = self
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .normal
        window.acceptsMouseMovedEvents = true
        if launchPolicy.makesWindowKey { window.makeKeyAndOrderFront(nil) }
        else { window.orderBack(nil) }
        if let targetScreen { renderer.configureDisplay(view: view, screen: targetScreen) }
        if launchPolicy.entersFullscreen {
            DispatchQueue.main.async { [weak self] in self?.enterNativeFullscreen() }
        }

        configureOverlay(in: view)
        installMenus()
        loadPresetLibrary()
        capture.onStatus = { [weak self] in self?.statusLabel.stringValue = $0; RuntimeLog.write("AUDIO \($0)") }
        renderer.onPerformance = { [weak self] in self?.performanceLabel.stringValue = $0; RuntimeLog.write("RENDER \($0)") }
        Task { await capture.start() }
        if launchPolicy.activatesApplication { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationWillTerminate(_ notification: Notification) { capture.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func enterNativeFullscreen() {
        guard !window.styleMask.contains(.fullScreen) else { return }
        RuntimeLog.write("FULLSCREEN REQUEST • native AppKit Space")
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        RuntimeLog.write("FULLSCREEN ENTERED • style fullScreen=1 • frame \(NSStringFromRect(window.frame)) • screen \(window.screen?.localizedName ?? "unknown") • presentation \(NSApp.presentationOptions.rawValue)")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        RuntimeLog.write("FULLSCREEN EXITED")
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.remove([.autoHideDock, .autoHideMenuBar])
        options.formUnion([.fullScreen, .hideDock, .hideMenuBar, .disableCursorLocationAssistance])
        return options
    }

    private func configureOverlay(in view: NSView) {
        let stack = NSStackView(views: [presetLabel, statusLabel, performanceLabel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        for label in [presetLabel, statusLabel, performanceLabel] {
            label.textColor = .white; label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            label.wantsLayer = true; label.layer?.shadowColor = NSColor.black.cgColor; label.layer?.shadowOpacity = 1; label.layer?.shadowRadius = 3
        }
        presetLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28)])
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func installMenus() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); app.addItem(withTitle: "About MilkDrop for macOS", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = app
        let visualItem = NSMenuItem(title: "Visual", action: nil, keyEquivalent: ""); main.addItem(visualItem)
        let visual = NSMenu(title: "Visual")
        visual.addItem(withTitle: "Next Preset", action: #selector(nextPreset), keyEquivalent: " ")
        visual.addItem(withTitle: "Previous Preset", action: #selector(previousPreset), keyEquivalent: "b")
        visual.addItem(withTitle: "Random Preset", action: #selector(randomPreset), keyEquivalent: "r")
        visual.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullscreen), keyEquivalent: "f")
        visualItem.submenu = visual; NSApp.mainMenu = main
    }

    private func loadPresetLibrary() {
        let env = ProcessInfo.processInfo.environment["MILKDROP_PRESETS"].map(URL.init(fileURLWithPath:))
        let candidates = [env, Bundle.main.resourceURL?.appendingPathComponent("Presets"), URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("favorite_presets_2021_01_03")].compactMap { $0 }
        presetURLs = candidates.lazy.map { PresetLibrary.discover(in: $0) }.first { !$0.isEmpty } ?? []
        if let requested = ProcessInfo.processInfo.environment["MILKDROP_PRESET"],
           let index = presetURLs.firstIndex(where: { $0.deletingPathExtension().lastPathComponent == requested }) {
            selectPreset(index)
        } else if !presetURLs.isEmpty {
            selectPreset(Int.random(in: 0..<presetURLs.count))
        } else {
            presetLabel.stringValue = renderer.preset.name
        }
    }

    private func selectPreset(_ index: Int) {
        guard !presetURLs.isEmpty else { return }
        presetIndex = (index % presetURLs.count + presetURLs.count) % presetURLs.count
        do { renderer.preset = try PresetLibrary.load(presetURLs[presetIndex]); presetLabel.stringValue = renderer.preset.name }
        catch { statusLabel.stringValue = "Preset error: \(error.localizedDescription)" }
    }

    @objc func nextPreset() { guard lockedPresetName == nil else { return }; selectPreset(presetIndex + 1) }
    @objc func previousPreset() { guard lockedPresetName == nil else { return }; selectPreset(presetIndex - 1) }
    @objc func randomPreset() { guard lockedPresetName == nil else { return }; if !presetURLs.isEmpty { selectPreset(Int.random(in: 0..<presetURLs.count)) } }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func showAbout() {
        let alert = NSAlert(); alert.messageText = "MilkDrop for macOS"; alert.informativeText = "A native Apple Silicon Metal reimplementation built from the original MilkDrop 2 source.\n\nSystem audio via Core Audio process tap • native 4K high refresh • extended-range Display P3 RGBA16F\n\nPreset compatibility includes per-frame NS-EEL and native custom shapes/waves; advanced per-pixel programs and HLSL shaders are diagnosed while their native translation is still in progress."; alert.runModal()
    }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": NSApp.sendAction(#selector(AppDelegate.nextPreset), to: nil, from: self)
        case "b", "B": NSApp.sendAction(#selector(AppDelegate.previousPreset), to: nil, from: self)
        case "r", "R": NSApp.sendAction(#selector(AppDelegate.randomPreset), to: nil, from: self)
        case "f", "F": toggleFullScreen(nil)
        case "\u{1b}": if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { NSApp.terminate(nil) }
        default: super.keyDown(with: event)
        }
    }
}

let app = NSApplication.shared
// Background render verification must establish accessory status before the
// application finishes launching; setting it in the delegate is too late to
// prevent Launch Services from briefly promoting the process.
if ProcessInfo.processInfo.environment["MILKDROP_BACKGROUND_TEST"] == "1" {
    app.setActivationPolicy(.accessory)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()

enum RuntimeLog {
    static let url = URL(fileURLWithPath: "/tmp/MilkDropMac.log")
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
    }
}
