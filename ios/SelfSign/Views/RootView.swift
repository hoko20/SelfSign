import SwiftUI

/// Root tab shell. iOS 26 Liquid Glass is applied system-wide: the TabBar and
/// NavigationStack adopt the material automatically; we add `.glassEffect()`
/// to custom surfaces and use `.glass` button styles throughout.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Tab = .library

    enum Tab: Hashable { case library, install, settings }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { LibraryView() }
                .tabItem { Label("应用库", systemImage: "square.stack.3d.up") }
                .tag(Tab.library)
            NavigationStack { InstallView() }
                .tabItem { Label("签名", systemImage: "signature") }
                .tag(Tab.install)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .sheet(isPresented: Bindable(store).showingSignIn) {
            SignInView()
        }
        .overlay { overlayLayer }
    }

    /// Global 2FA / certificate prompts and operation progress float above
    /// the tab bar in a Liquid Glass capsule.
    @ViewBuilder
    private var overlayLayer: some View {
        if let twoFA = store.twoFactorPrompt {
            TwoFactorSheet(params: twoFA)
        } else if let serials = store.certPrompt {
            CertificateLimitSheet(serials: serials)
        }
    }
}
