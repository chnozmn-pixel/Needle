import SwiftUI
import LocalAuthentication
import NeedleCore

/// Optional LocalAuthentication gate shown before the Settings window content.
/// It uses `deviceOwnerAuthentication`, so Touch ID is used when available and
/// the Mac account password is accepted on every supported Mac.
struct SettingsLockView: View {
    let onUnlock: () -> Void

    @State private var message = ""
    @State private var isAuthenticating = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text(L("Ayarlar kilitli"))
                .font(.headline)
            Text(L("Ayarları görüntülemek için Touch ID veya parolanızı kullanın."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button(L("Kilidi Aç")) { authenticate() }
                .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { authenticate() }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = error?.localizedDescription ?? L("Bu cihazda kimlik doğrulama kullanılamıyor.")
            return
        }

        isAuthenticating = true
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: L("Needle ayarlarını açmak için kimlik doğrulayın.")
        ) { success, error in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onUnlock()
                } else {
                    message = error?.localizedDescription ?? L("Kimlik doğrulama başarısız.")
                }
            }
        }
    }
}
