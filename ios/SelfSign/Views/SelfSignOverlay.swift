import SwiftUI

/// Global SelfSign prompts hosted above LiveContainer's tab bar.
/// Kept as a separate view so `LCTabView` stays close to upstream source.
struct SelfSignOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let twoFA = store.twoFactorPrompt {
                TwoFactorSheet(params: twoFA)
            } else if let serials = store.certPrompt {
                CertificateLimitSheet(serials: serials)
            }
        }
    }
}
