import SwiftUI

struct SettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section(text("显示", "Display")) {
                Picker(text("语言", "Language"), selection: $preferences.language) {
                    Text(text("跟随系统", "System")).tag(AppPreferences.Language.system)
                    Text("简体中文").tag(AppPreferences.Language.simplifiedChinese)
                    Text("English").tag(AppPreferences.Language.english)
                }

                Picker(text("外观", "Appearance"), selection: $preferences.appearance) {
                    Text(text("跟随系统", "System")).tag(AppPreferences.Appearance.system)
                    Text(text("浅色", "Light")).tag(AppPreferences.Appearance.light)
                    Text(text("深色", "Dark")).tag(AppPreferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $preferences.replaceOriginal) {
                    Label(text("替换原照片", "Replace Original"), systemImage: "photo.badge.checkmark")
                }
            } footer: {
                Text(text(
                    "默认关闭。开启后，只有在新照片成功存入系统相册后才会删除原照片；“最近删除”中仍可恢复。",
                    "Off by default. When enabled, the original is deleted only after the converted photo is saved. It remains recoverable in Recently Deleted."
                ))
            }

            Section(text("关于", "About")) {
                LabeledContent(text("过片", "StylePort"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1")
            }
        }
        .navigationTitle(text("设置", "Settings"))
    }

    private func text(_ zh: String, _ en: String) -> String {
        preferences.language.text(zh: zh, en: en)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AppPreferences(defaults: UserDefaults(suiteName: "SettingsPreview")!))
}
