import AppKit
import FTPKit
import SwiftUI

/// UserDefaults keys for the settings window.
enum Prefs {
    static let appearance = "appearance"
    static let language = "language"
    static let connectBehavior = "connectBehavior"
    static let checkUpdates = "checkUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let skippedUpdateVersion = "skippedUpdateVersion"
    static let notifyTransfers = "notifyTransfers"
    static let dockProgress = "dockProgress"
    static let downloadLimit = "downloadLimitKB"
    static let uploadLimit = "uploadLimitKB"
    static let previewLimitMB = "previewLimitMB"
    static let preserveTimes = "preserveTimes"
    static let syncPolicy = "syncPolicy"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appearance: Appearance.system.rawValue,
            language: AppLanguage.system.rawValue,
            connectBehavior: ConnectBehavior.ask.rawValue,
            checkUpdates: true,
            notifyTransfers: true,
            dockProgress: true,
            downloadLimit: 0,
            uploadLimit: 0,
            previewLimitMB: 50,
            preserveTimes: true,
            syncPolicy: ExistsPolicy.ifNewer.rawValue,
        ])
        AppLanguage.atLaunch = AppLanguage(rawValue: UserDefaults.standard.string(forKey: language) ?? "") ?? .system
    }

    /// Pushes the saved transfer speed limits to FTPKit.
    static func applySpeedLimits() {
        let d = UserDefaults.standard
        TransferLimits.shared.set(download: Int64(max(0, d.integer(forKey: downloadLimit))) * 1024,
                                  upload: Int64(max(0, d.integer(forKey: uploadLimit))) * 1024)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applySaved() {
        (Appearance(rawValue: UserDefaults.standard.string(forKey: Prefs.appearance) ?? "") ?? .system).apply()
    }
}

/// What "Bağlan" does when the current tab is already connected.
enum ConnectBehavior: String, CaseIterable, Identifiable {
    case ask, newTab, sameTab
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .ask: return "Her seferinde sor"
        case .newTab: return "Yeni sekmede aç"
        case .sameTab: return "Bu sekmedeki bağlantıyı değiştir"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Sistem dili"
        case .tr: return "Türkçe"
        case .en: return "English"
        }
    }

    var flag: String {
        switch self {
        case .system: return "🌐"
        case .tr: return "🇹🇷"
        case .en: return "🇬🇧"
        }
    }

    /// The translation MacZilla will use when it starts with this choice, so
    /// the restart prompt can speak the language being switched to.
    var bundle: Bundle {
        var preferences = [rawValue]
        if self == .system {
            preferences = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
        }
        let code = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        return code.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .main
    }

    /// Stores the choice where Bundle reads it on the next launch.
    func save() {
        let d = UserDefaults.standard
        d.set(rawValue, forKey: Prefs.language)
        if self == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([rawValue], forKey: "AppleLanguages") }
    }

    /// The choice in effect for the running app (read once at launch).
    nonisolated(unsafe) static var atLaunch = AppLanguage.system
}
