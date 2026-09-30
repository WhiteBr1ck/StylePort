import SwiftUI

@main
struct StylePortApp: App {
    @State private var preferences = AppPreferences()
    @State private var photoLibrary = PhotoLibraryStore()
    @State private var conversion = BatchConversionCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(preferences)
                .environment(photoLibrary)
                .environment(conversion)
                .environment(\.locale, preferences.language.locale ?? .current)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }
}
