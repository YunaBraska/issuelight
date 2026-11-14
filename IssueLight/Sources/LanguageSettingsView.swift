import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                Picker(
                    AppLocalization.string("App-Sprache", locale: locale),
                    selection: $languageSettings.selection
                ) {
                    Text(verbatim: AppLocalization.string("Systemstandard", locale: locale))
                        .tag(AppLanguage.system)
                    Divider()
                    ForEach(AppLanguage.supportedLanguages) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                }
                .accessibilityIdentifier("app-language-picker")

                Group {
                    if languageSettings.selection == .system {
                        Text(
                            verbatim: AppLocalization.string(
                                "IssueLight folgt der App-Sprache aus den macOS-Systemeinstellungen.",
                                locale: locale
                            )
                        )
                    } else {
                        Text(
                            verbatim: AppLocalization.string(
                                "IssueLight verwendet die gewählte Sprache unabhängig von macOS.",
                                locale: locale
                            )
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(verbatim: AppLocalization.string("Sprache", locale: locale))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 190)
    }

}

struct AppLanguageMenu: View {
    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.locale) private var locale

    var body: some View {
        Menu {
            Picker(
                AppLocalization.string("App-Sprache", locale: locale),
                selection: $languageSettings.selection
            ) {
                Text(verbatim: AppLocalization.string("Systemstandard", locale: locale))
                    .tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.supportedLanguages) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
            .labelsHidden()
        } label: {
            Label {
                HStack {
                    Text(verbatim: AppLocalization.string("Sprache", locale: locale))
                    Spacer()
                    if languageSettings.selection == .system {
                        Text(verbatim: AppLocalization.string("Systemstandard", locale: locale))
                    } else {
                        Text(verbatim: languageSettings.selection.nativeName)
                    }
                }
            } icon: {
                Image(systemName: "globe")
            }
        }
    }
}
