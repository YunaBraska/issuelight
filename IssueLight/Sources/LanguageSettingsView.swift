import AppKit
import SwiftUI

struct IssueLightSettingsView: View {
    enum Tab: Hashable {
        case language
        case about
    }

    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.locale) private var locale
    @State private var selection: Tab

    init(languageSettings: AppLanguageSettings, initialSelection: Tab = .language) {
        self.languageSettings = languageSettings
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        TabView(selection: $selection) {
            LanguageSettingsView(languageSettings: languageSettings)
                .tabItem {
                    Label {
                        Text(verbatim: AppLocalization.string("Sprache", locale: locale))
                    } icon: {
                        Image(systemName: "globe")
                    }
                }
                .tag(Tab.language)

            AboutSettingsView()
                .tabItem {
                    Label {
                        Text(verbatim: AppLocalization.string("Über IssueLight", locale: locale))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                }
                .tag(Tab.about)
        }
        .padding(20)
        .frame(width: 620, height: 430)
    }
}

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
    }
}

struct AboutSettingsView: View {
    @Environment(\.locale) private var locale
    let icon: NSImage
    let version: String
    let build: String
    let copyrightText: String

    private let repositoryURL = URL(string: "https://github.com/YunaBraska/issuelight")!
    private let releasesURL = URL(string: "https://github.com/YunaBraska/issuelight/releases")!
    private let privacyURL = URL(string: "https://yunabraska.github.io/issuelight/privacy.html")!
    private let issuesURL = URL(string: "https://github.com/YunaBraska/issuelight/issues/new")!
    private let sponsorsURL = URL(string: "https://github.com/sponsors/YunaBraska")!
    private let coffeeURL = URL(string: "https://buymeacoffee.com/YunaBraska")!
    private let koFiURL = URL(string: "https://ko-fi.com/YunaBraska")!
    private let liberapayURL = URL(string: "https://liberapay.com/YunaBraska")!

    init(
        icon: NSImage = NSApp.applicationIconImage,
        version: String? = nil,
        build: String? = nil,
        copyrightText: String? = nil
    ) {
        self.icon = icon
        let info = Bundle.main.infoDictionary
        self.version = version ?? (info?["CFBundleShortVersionString"] as? String ?? "Development")
        self.build = build ?? (info?["CFBundleVersion"] as? String ?? "Local")
        self.copyrightText = copyrightText
            ?? Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Yuna Morgenstern and IssueLight contributors."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: "IssueLight")
                            .font(.title.bold())
                        Text(verbatim: "\(AppLocalization.string("Version", locale: locale)) \(version) (\(build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Yuna Morgenstern")
                            .font(.callout)
                        Text(verbatim: "Apache License 2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsLinks

                Divider()

                supportLinks

                Text(verbatim: copyrightText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .accessibilityIdentifier("about-settings")
    }

    private var settingsLinks: some View {
        LazyVGrid(columns: linkColumns, alignment: .leading, spacing: 10) {
            aboutLink("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", destination: repositoryURL)
            aboutLink(
                AppLocalization.string("Veröffentlichungen anzeigen …", locale: locale),
                systemImage: "shippingbox",
                destination: releasesURL
            )
            aboutLink(
                AppLocalization.string("Datenschutz", locale: locale),
                systemImage: "hand.raised",
                destination: privacyURL
            )
            aboutLink(
                AppLocalization.string("Problem melden …", locale: locale),
                systemImage: "exclamationmark.bubble",
                destination: issuesURL
            )
        }
    }

    private var supportLinks: some View {
        LazyVGrid(columns: linkColumns, alignment: .leading, spacing: 10) {
            aboutLink("GitHub Sponsors", systemImage: "heart", destination: sponsorsURL)
            aboutLink("Buy Me a Coffee", systemImage: "cup.and.saucer", destination: coffeeURL)
            aboutLink("Ko-fi", systemImage: "mug", destination: koFiURL)
            aboutLink("Liberapay", systemImage: "gift", destination: liberapayURL)
        }
    }

    private func aboutLink(_ title: String, systemImage: String, destination: URL) -> some View {
        Link(destination: destination) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private var linkColumns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
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
