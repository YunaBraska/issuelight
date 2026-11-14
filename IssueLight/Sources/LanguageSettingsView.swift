import AppKit
import SwiftUI

struct IssueLightSettingsView: View {
    enum Tab: Hashable {
        case sources
        case language
        case about
    }

    @ObservedObject var model: IssueLightModel
    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.locale) private var locale
    @State private var selection: Tab

    init(
        model: IssueLightModel,
        languageSettings: AppLanguageSettings,
        initialSelection: Tab = .sources
    ) {
        self.model = model
        self.languageSettings = languageSettings
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        TabView(selection: $selection) {
            SourceSetupView(model: model)
                .tabItem {
                    Label {
                        Text(verbatim: AppLocalization.string("Quellen", locale: locale))
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                }
                .tag(Tab.sources)

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
        .padding(16)
        .frame(width: 820, height: 600)
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
    private static let messages: [LocalizedStringResource] = [
        "Alerts multiply. Attention does not.\nIssueLight sorts the signal before it reaches you.\nA star helps. Coffee keeps the beacon lit.",
        "Green is a temporary agreement between distributed systems.\nIssueLight watches the fine print.\nStar it if it saved a minute. Fuel it if it saved the night.",
        "The quiet menu bar is not doing nothing.\nIt is waiting for evidence.\nStar the repository if that restraint feels useful.",
        "Monitoring should interrupt you only when it has something useful to say.\nIssueLight keeps the noise down and the problems visible.\nCoffee is optional. Reliable alerts are not.",
    ]

    @Environment(\.locale) private var locale
    let icon: NSImage
    let version: String
    let build: String
    let copyrightText: String
    @State private var messageIndex: Int

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
        copyrightText: String? = nil,
        messageIndex: Int? = nil
    ) {
        self.icon = icon
        let info = Bundle.main.infoDictionary
        self.version = version ?? (info?["CFBundleShortVersionString"] as? String ?? "Development")
        self.build = build ?? (info?["CFBundleVersion"] as? String ?? "Local")
        self.copyrightText = copyrightText
            ?? Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Yuna Morgenstern and IssueLight contributors."
        _messageIndex = State(
            initialValue: messageIndex.map { abs($0) % Self.messages.count }
                ?? Int.random(in: Self.messages.indices)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "IssueLight")
                            .font(.title2.bold())
                        Text(verbatim: "\(AppLocalization.string("Version", locale: locale)) \(version) (\(build))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Yuna Morgenstern · Apache License 2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(verbatim: AppLocalization.string(Self.messages[messageIndex], locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                links

                Text(verbatim: copyrightText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("about-settings")
    }

    private var links: some View {
        LazyVGrid(columns: linkColumns, alignment: .leading, spacing: 12) {
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
            .padding(.vertical, 3)
        }
        .buttonStyle(.link)
    }

    private var linkColumns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }
}
