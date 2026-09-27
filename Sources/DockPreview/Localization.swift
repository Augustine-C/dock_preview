import Foundation
import PreviewCore

enum L10n {
    static func text(_ key: String) -> String {
        let preference = InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .system
        let language = preference.resolved(preferredLanguages: Locale.preferredLanguages)
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        return bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}

extension Notification.Name {
    static let interfaceLanguageDidChange = Notification.Name("DockPreview.interfaceLanguageDidChange")
}
