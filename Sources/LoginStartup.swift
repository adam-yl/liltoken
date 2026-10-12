// Codex-owned. Native login registration; changes only on an explicit user action.
import ServiceManagement

enum LoginStartup {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "app unavailable"
        @unknown default: return "unknown"
        }
    }

    static func enable() throws { try SMAppService.mainApp.register() }
    static func disable() throws { try SMAppService.mainApp.unregister() }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
