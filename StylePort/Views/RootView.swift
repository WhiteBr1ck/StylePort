import SwiftUI

struct RootView: View {
    @Environment(AppPreferences.self) private var preferences

    enum Tab: Hashable {
        case photos
        case inspect
        case settings
    }

    @State private var selectedTab: Tab = .photos
    @State private var imports = PhotoImportSession()
    @State private var inspection = PhotoInspectionSession()

    var body: some View {
        @Bindable var conversion = conversion
        TabView(selection: $selectedTab) {
            NavigationStack {
                PhotosView()
            }
            .tabItem { Label(text("转换", "Convert"), systemImage: "camera.filters") }
            .tag(Tab.photos)

            NavigationStack {
                PhotoInfoView(session: inspection)
            }
            .tabItem { Label(text("查看", "Inspect"), systemImage: "info.circle") }
            .tag(Tab.inspect)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(text("设置", "Settings"), systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .environment(imports)
        .sheet(item: $conversion.report, onDismiss: conversion.reset) { report in
            BatchResultView(summary: report.summary)
        }
    }

    @Environment(BatchConversionCoordinator.self) private var conversion

    private func text(_ zh: String, _ en: String) -> String {
        preferences.language.text(zh: zh, en: en)
    }
}

#Preview {
    RootView()
        .environment(AppPreferences(defaults: UserDefaults(suiteName: "RootPreview")!))
        .environment(PhotoLibraryStore())
        .environment(BatchConversionCoordinator())
}
