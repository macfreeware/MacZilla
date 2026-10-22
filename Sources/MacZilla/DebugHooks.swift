#if DEBUG
import AppKit
import FTPKit
import SwiftUI

/// Debug-only UI test hooks driven by environment variables:
///   MACZILLA_AUTOCONNECT=proto:host:port:user:pass  connect on launch
///   MACZILLA_LOCAL=/path                      start the local pane here
///   MACZILLA_DEMO=1                           blank the saved quick-connect fields
///   MACZILLA_SITE_NAME=…                      name shown for the auto-connection
///   MACZILLA_REMOTE_PATH=/dir                 open this remote directory
///   MACZILLA_SCRIPT=download,upload           queue sample transfers
///   MACZILLA_UPLOAD / MACZILLA_DOWNLOAD=a,b   queue these files by name
///   MACZILLA_SELECT_LOCAL / _REMOTE=a,b       select these files by name
///   MACZILLA_SNAPSHOT_DELAY=seconds           wait before the snapshot
///   MACZILLA_ABOUT=Genel|Kullanım|Sistem       open the About window (snapshot shows it)
///   MACZILLA_TRUST=once|reject|quit           answer the certificate prompt (or quit)
///   MACZILLA_SITE_MANAGER=1                   open the Site Manager (MACZILLA_SITES_FILE,
///                                             MACZILLA_SHEET_HEIGHT for test data and size)
///   MACZILLA_TABS=proto:host:port:user:pass;…  open more tabs, one per connection
///   MACZILLA_COMPARE=1 (or dates)             switch on directory comparison
///   MACZILLA_SHEET=sync|bookmarks|settings    open that sheet or window
///   MACZILLA_SETTINGS_TAB=general|transfer    the Settings tab to show
///   MACZILLA_MENUS=/out.txt                   write the menu bar (titles, shortcuts)
///   MACZILLA_IMPORT=/sitemanager.xml          import FileZilla sites
///   MACZILLA_SCENARIO=rebind|sync|edit|limit  scripted checks; results go to MACZILLA_REPORT
///   MACZILLA_REMOTE_NAV / MACZILLA_LOCAL_NAV  open these folders after connecting
///   MACZILLA_QUICKLOOK=name                   Quick Look this remote file
///   MACZILLA_ALERT=title                      press this button of the next modal alert; its text goes
///                                             to MACZILLA_REPORT, its picture to MACZILLA_ALERT_SNAPSHOT
///   MACZILLA_CLOSE=seconds                    close the main window after this delay
///   MACZILLA_CMD_W=seconds                    press ⌘W after this delay; the result goes to MACZILLA_REPORT
///   MACZILLA_SNAPSHOT=/out.png                save the window as PNG, then quit
@MainActor
enum DebugHooks {
    /// The main window can be closed and opened again; the hooks run once.
    private static var didRun = false

    static func run(_ app: AppModel, sites: SiteStore, openWindow: OpenWindowAction,
                    openSettings: OpenSettingsAction) async {
        guard !didRun else { return }
        didRun = true
        let model = app.current
        let env = ProcessInfo.processInfo.environment
        func names(_ key: String) -> Set<String> {
            Set(env[key]?.split(separator: ",").map(String.init) ?? [])
        }
        if env["MACZILLA_DEMO"] != nil {
            // Never show the user's own saved quick-connect values.
            app.quickHost = ""
            app.quickUser = ""
            app.quickPassword = ""
            app.quickPort = ""
        }
        if env["MACZILLA_ABOUT"] != nil { openWindow(id: "about") }
        if env["MACZILLA_SITE_MANAGER"] != nil { app.showSiteManager = true }
        if let local = env["MACZILLA_LOCAL"] { model.local.navigate(toText: local) }
        if let ac = env["MACZILLA_AUTOCONNECT"] {
            let p = ac.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let proto = ServerProtocol(scheme: p[0]) ?? .ftp
            app.quickProtocol = proto
            app.quickHost = p[1]
            app.quickPort = p[2]
            app.quickUser = p[3]
            model.connect(ConnectTarget(config: FTPConfig(host: p[1], port: UInt16(p[2]), user: p[3], password: p[4],
                                                          serverProtocol: proto), name: env["MACZILLA_SITE_NAME"]))
        }
        if let button = env["MACZILLA_ALERT"] {
            answerAlert(button: button, report: env["MACZILLA_REPORT"], snapshot: env["MACZILLA_ALERT_SNAPSHOT"])
        }
        if let delay = env["MACZILLA_CLOSE"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                NSApp.windows.first { $0.isVisible && AppModel.isMainWindow($0) }?.performClose(nil)
            }
        }
        if let delay = env["MACZILLA_CMD_W"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                let w = NSApp.keyWindow
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w?.windowNumber ?? 0,
                                            context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                            isARepeat: false, keyCode: 13) {
                    NSApp.sendEvent(e)
                }
                try? await Task.sleep(for: .seconds(1))
                let main = NSApp.windows.contains { $0.isVisible && AppModel.isMainWindow($0) }
                let line = "cmdW key=\(w?.identifier?.rawValue ?? "nil") mainWindowVisible=\(main) tabs=\(app.sessions.count) "
                    + "connected=\(app.current.isConnected) confirm=\(app.confirm?.title ?? "nil")\n"
                try? line.write(toFile: env["MACZILLA_REPORT"] ?? "/dev/null", atomically: true, encoding: .utf8)
            }
        }
        if let answer = env["MACZILLA_TRUST"] {
            await answerTrust(app, answer: answer, snapshot: env["MACZILLA_SNAPSHOT"])
        }
        if env["MACZILLA_AUTOCONNECT"] != nil {
            for _ in 0..<50 where model.remote.files.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        for spec in env["MACZILLA_TABS"]?.split(separator: ";").map(String.init) ?? [] {
            let p = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 5 else { continue }
            let tab = app.newTab(select: false)
            tab.connect(ConnectTarget(config: FTPConfig(host: p[1], port: UInt16(p[2]), user: p[3], password: p[4],
                                                        serverProtocol: ServerProtocol(scheme: p[0]) ?? .ftp),
                                      name: p.count > 5 ? p[5] : nil))
        }
        if let path = env["MACZILLA_REMOTE_PATH"] {
            await model.loadRemote(path)
        }

        let script = Set(env["MACZILLA_SCRIPT"]?.split(separator: ",").map(String.init) ?? [])
        if script.contains("download") {
            model.download(model.remote.files.filter { $0.isDirectory || $0.name.hasSuffix(".txt") })
        }
        if script.contains("upload") {
            model.upload(model.local.files.filter { !$0.isHidden }.prefix(3).map(\.url))
        }
        if script.contains("select") {
            model.remote.selection = Set(model.remote.files.prefix(2).map(\.id))
        }
        let uploads = names("MACZILLA_UPLOAD"), downloads = names("MACZILLA_DOWNLOAD")
        if !uploads.isEmpty { model.upload(model.local.files.filter { uploads.contains($0.name) }.map(\.url)) }
        if !downloads.isEmpty { model.download(model.remote.files.filter { downloads.contains($0.name) }) }
        let localSel = names("MACZILLA_SELECT_LOCAL"), remoteSel = names("MACZILLA_SELECT_REMOTE")
        if !localSel.isEmpty { model.local.selection = Set(model.local.files.filter { localSel.contains($0.name) }.map(\.id)) }
        if !remoteSel.isEmpty { model.remote.selection = Set(model.remote.files.filter { remoteSel.contains($0.name) }.map(\.id)) }

        if let path = env["MACZILLA_IMPORT"] { app.importFileZilla(from: URL(fileURLWithPath: path), store: sites) }
        if let dir = env["MACZILLA_LOCAL_NAV"] { model.local.navigate(toText: dir) }
        if let dir = env["MACZILLA_REMOTE_NAV"] { await model.loadRemote(dir) }
        if let name = env["MACZILLA_QUICKLOOK"], let f = model.remote.files.first(where: { $0.name == name }) {
            model.quickLook(f)
        }
        if let spec = env["MACZILLA_MENU_AT"] {
            // "x,y" as fractions of the main window: asks the view there for its
            // right-click menu without moving the real mouse.
            try? await Task.sleep(for: .seconds(1))
            let f = spec.split(separator: ",").compactMap { Double($0) }
            var out = "no window"
            if f.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && AppModel.isMainWindow($0) }),
               let content = w.contentView {
                let p = NSPoint(x: content.bounds.width * f[0], y: content.bounds.height * (1 - f[1]))
                let hit = content.hitTest(p)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: content.convert(p, to: nil),
                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)
                var view = hit
                var menu: NSMenu?
                while let v = view, menu == nil, let e = event { menu = v.menu(for: e); view = v.superview }
                out = "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") menu=\(menu?.items.map(\.title) ?? [])"
            }
            try? out.write(toFile: env["MACZILLA_REPORT"] ?? "/dev/null", atomically: true, encoding: .utf8)
        }
        if let scenario = env["MACZILLA_SCENARIO"] {
            await Scenarios.run(scenario, app: app, report: env["MACZILLA_REPORT"] ?? "/dev/null")
        }
        if let mode = env["MACZILLA_COMPARE"] {
            model.compare.enabled = true
            model.compare.useDates = mode == "dates"
        }
        switch env["MACZILLA_SHEET"] {
        case "sync": app.showSync = true
        case "bookmarks": app.showBookmarks = true
        case "settings": openSettings()
        default: break
        }
        if let out = env["MACZILLA_MENUS"] {
            try? await Task.sleep(for: .seconds(1))
            var lines: [String] = []
            func dump(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items where !item.isSeparatorItem {
                    let mods = item.keyEquivalentModifierMask
                    let key = item.keyEquivalent.isEmpty ? "" : " [" + (mods.contains(.control) ? "⌃" : "")
                        + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "")
                        + (mods.contains(.command) ? "⌘" : "") + item.keyEquivalent + "]"
                    lines.append(String(repeating: "  ", count: depth) + item.title + key)
                    if let sub = item.submenu { dump(sub, depth + 1) }
                }
            }
            if let main = NSApp.mainMenu { dump(main, 0) }
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }

        if let out = env["MACZILLA_SNAPSHOT"] {
            let delay = env["MACZILLA_SNAPSHOT_DELAY"].flatMap(Double.init) ?? (script.isEmpty ? 1 : 4)
            try? await Task.sleep(for: .seconds(delay))
            // An inactive window draws its selection grey or black.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderedWindows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if env["MACZILLA_SITE_MANAGER"] != nil || env["MACZILLA_SHEET"] != nil { snapshotAll(to: out) } else { snapshot(to: out) }
            NSApp.terminate(nil)
        }
    }

    /// Waits for the certificate sheet, optionally captures it, then answers.
    /// The sheet is modal; a common-modes timer keeps firing while it is up.
    private static func answerTrust(_ model: AppModel, answer: String, snapshot: String?) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var seenAt: Date?
            let timer = Timer(timeInterval: 0.2, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard let request = model.trustRequest else { return }
                    if seenAt == nil { seenAt = Date(); return }
                    guard Date().timeIntervalSince(seenAt!) > 0.8 else { return }
                    t.invalidate()
                    if let out = snapshot { snapshotAll(to: out.replacingOccurrences(of: ".png", with: "-prompt.png")) }
                    switch answer {
                    case "reject": model.resolveTrust(request, .reject)
                    case "quit": NSApp.terminate(nil)
                    default: model.resolveTrust(request, .once)
                    }
                    done.resume()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Waits for an app-modal alert (runModal), records it, then presses a button.
    private static func answerAlert(button: String, report: String?, snapshot: String?) {
        var seenAt: Date?
        let timer = Timer(timeInterval: 0.2, repeats: true) { t in
            MainActor.assumeIsolated {
                guard let w = NSApp.modalWindow, let content = w.contentView else { return }
                if seenAt == nil { seenAt = Date(); return }
                guard Date().timeIntervalSince(seenAt!) > 0.5 else { return }
                t.invalidate()
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                let views = all(content)
                let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
                let buttons = views.compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
                let line = "alert=\(texts) buttons=\(buttons.map(\.title))\n"
                if let report, let h = FileHandle(forWritingAtPath: report) ?? {
                    FileManager.default.createFile(atPath: report, contents: nil); return FileHandle(forWritingAtPath: report)
                }() {
                    h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                }
                if let snapshot, let view = w.contentView?.superview { write(view, to: snapshot) }
                buttons.first { $0.title == button }?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let main = NSApp.windows.contains { $0.isVisible && AppModel.isMainWindow($0) }
                    guard let report, let h = FileHandle(forWritingAtPath: report) else { return }
                    h.seekToEndOfFile(); h.write(Data("afterAnswer mainWindowVisible=\(main)\n".utf8)); try? h.close()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Saves every visible window (alerts are separate windows) as path-N.png.
    private static func snapshotAll(to path: String) {
        for (i, w) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let view = w.contentView?.superview else { continue }
            write(view, to: path.replacingOccurrences(of: ".png", with: "-\(i).png"))
        }
    }

    private static func snapshot(to path: String) {
        let visible = NSApp.windows.filter(\.isVisible)
        let about = ProcessInfo.processInfo.environment["MACZILLA_ABOUT"] != nil
        // The About window by its scene id, so the title's language does not matter.
        guard let window = visible.first(where: { ($0.identifier?.rawValue.hasPrefix("about") == true) == about }) ?? visible.first,
              let view = window.contentView?.superview else { return }
        write(view, to: path)
    }

    /// Always at 2x, whatever the screen the window is on.
    private static func write(_ view: NSView, to path: String) {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

#if DEBUG
/// Scripted end-to-end checks against local test servers. Each writes
/// "key=value" lines to the report file and leaves the app running.
@MainActor
enum Scenarios {
    static func run(_ name: String, app: AppModel, report: String) async {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s) }
        let tab = app.current
        func waitIdle(_ seconds: Double = 20) async {
            let end = Date().addingTimeInterval(seconds)
            try? await Task.sleep(for: .milliseconds(300))
            while Date() < end, app.queue.pendingCount > 0 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func waitConnected(_ s: Session) async {
            for _ in 0..<100 where !(s.isConnected && !s.remote.isLoading && !s.remote.files.isEmpty) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        switch name {
        case "rebind":
            // Queue a download from server A, drop the connection, connect the
            // same tab to server B, then retry: the file must still come from A.
            guard let f = tab.remote.files.first(where: { $0.name == "foto.jpg" }), let a = tab.config else { break }
            TransferLimits.shared.set(download: 20_000, upload: 0)
            tab.download([f])
            try? await Task.sleep(for: .milliseconds(800))
            tab.disconnect()
            TransferLimits.shared.set(download: 0, upload: 0)
            note("afterDisconnect=\(app.queue.items.map { "\($0.name):\($0.status)" })")
            var b = a
            b.port = 2123
            tab.connect(ConnectTarget(config: b, name: "B"))
            await waitConnected(tab)
            note("tabNowOn=\(tab.config?.port ?? 0)")
            app.queue.retry(Set(app.queue.items.map(\.id)))
            await waitIdle()
            note("afterRetry=\(app.queue.items.map { "\($0.name):\($0.status):\($0.config.port)" })")
        case "sync":
            let policy = ExistsPolicy(rawValue: ProcessInfo.processInfo.environment["MACZILLA_SYNC_POLICY"] ?? "") ?? .ifNewer
            note("candidates=\(tab.syncCandidates(.upload, subfolders: true, policy: policy))")
            tab.synchronize(.upload, subfolders: true, policy: policy)
            await waitIdle()
            note("statuses=\(app.queue.items.map { "\($0.remotePath):\($0.status)" }.sorted())")
        case "download-dir":
            // Downloads a folder; with "keep times" on, local files get the server's times.
            guard let dir = tab.remote.files.first(where: { $0.name == "public_html" }) else { break }
            tab.download([dir])
            await waitIdle()
            note("statuses=\(app.queue.items.map { "\($0.remotePath):\($0.status)" }.sorted())")
        case "edit":
            guard let f = tab.remote.files.first(where: { $0.name == "ortak.txt" }), let cfg = tab.config,
                  let url = await tab.fetchToTemp(tab.remote.fullPath(f), name: f.name, folder: "Edit") else { break }
            app.edits.watch(url, remotePath: tab.remote.fullPath(f), config: cfg, sessionID: tab.id)
            note("local=\(url.path)")
            try? await Task.sleep(for: .seconds(1.5))
            try? "düzenlendi 1\n".write(to: url, atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(3))
            await waitIdle()
            note("uploads=\(app.edits.entries.first?.uploads ?? -1)")
            note("queue=\(app.queue.items.map { "\($0.remotePath):\($0.status)" })")
        case "limit":
            guard let dir = tab.remote.files.first(where: { $0.name == "yedekler" }) else { break }
            await tab.loadRemote(tab.remote.fullPath(dir))
            guard let f = tab.remote.files.first(where: { $0.name == "buyuk.zip" }) else { break }
            TransferLimits.shared.set(download: 400 * 1024, upload: 0)
            let start = Date()
            tab.download([f])
            try? await Task.sleep(for: .seconds(1.5))
            DockProgress.shared.update(queue: app.queue)
            note("dockBadge=\(NSApp.dockTile.badgeLabel ?? "nil") dockView=\(NSApp.dockTile.contentView != nil) progress=\(app.queue.progress)")
            await waitIdle(30)
            DockProgress.shared.update(queue: app.queue)
            note("afterDockBadge=\(NSApp.dockTile.badgeLabel ?? "nil") dockView=\(NSApp.dockTile.contentView != nil)")
            note(String(format: "seconds=%.1f size=%lld", Date().timeIntervalSince(start), f.size))
            TransferLimits.shared.set(download: 0, upload: 0)
        default:
            note("unknown scenario")
        }
        try? lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
}
#endif
