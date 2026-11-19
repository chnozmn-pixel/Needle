import Foundation
import ServiceManagement
import NeedleCore

/// Manages the macOS 13 login-item registration for Needle. Registration only
/// works for the bundled app; running from a checkout reports the underlying
/// error so Settings can explain it to the user.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private var service: SMAppService { SMAppService.mainApp }

    init() {}

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            errorMessage = nil
        case .requiresApproval:
            isEnabled = false
            errorMessage = L("Giriş öğesi onayı gerekiyor: Sistem Ayarları → Genel → Açılış Öğeleri.")
        case .notFound, .notRegistered:
            isEnabled = false
            errorMessage = nil
        @unknown default:
            isEnabled = false
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = L("Giriş öğesi ayarlanamadı: %@", error.localizedDescription)
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
