import SwiftUI
import UIKit

@main
struct SelfSignApp: App {
    @State private var store = AppStore.shared
    @State private var shortcutRouter = ShortcutRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(shortcutRouter)
                .onOpenURL { url in
                    shortcutRouter.handle(url)
                }
                .onAppear {
                    selfSignInit()
                }
        }
    }
}
