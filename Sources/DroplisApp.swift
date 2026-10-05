import SwiftUI

@main
struct DroplisApp: App {
    var body: some Scene {
        WindowGroup {
            GameWebView()
                .background(Color("LaunchBackground"))
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}
