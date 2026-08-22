import Foundation

/// Hard privacy boundary for local builds that delegate all Codex account usage requests to the
/// official Codex CLI. The app bundle flag cannot be disabled through user settings, so stale
/// OAuth/PAT/Web preferences cannot silently restore direct CodexBar network access.
public enum CodexNetworkPrivacyMode {
    public static let environmentKey = "CODEXBAR_CODEX_CLI_ONLY"
    public static let infoPlistKey = "CodexBarCodexCLIOnly"

    public static var isCLIOnly: Bool {
        self.isCLIOnly(environment: ProcessInfo.processInfo.environment)
    }

    public static func isCLIOnly(environment: [String: String]) -> Bool {
        if self.isTruthy(environment[self.environmentKey]) {
            return true
        }
        if let enabled = Bundle.main.object(forInfoDictionaryKey: self.infoPlistKey) as? Bool {
            return enabled
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: self.infoPlistKey) as? String {
            return self.isTruthy(raw)
        }
        return false
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }
}
