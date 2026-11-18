import AppKit
import SwiftUI
import IssueLightCore

struct StatusMenuLabel: View {
    let counts: MenuBarIssueCounts
    let accessibilityText: String

    var body: some View {
        if counts.compactText.isEmpty {
            Image("MenuBarLighthouse", bundle: IssueLightResources.bundle)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityLabel(accessibilityText)
        } else {
            Text(verbatim: counts.compactText)
                .monospacedDigit()
                .accessibilityLabel(accessibilityText)
        }
    }
}

struct MenuBarIssueCounts: Equatable {
    let critical: Int
    let warning: Int
    let unknown: Int
    let down: Int

    init(issues: [MonitoringIssue], unavailableSourceCount: Int = 0) {
        critical = issues.filter { $0.kind == .service && $0.severity == .critical }.count
        warning = issues.filter { $0.kind == .service && $0.severity == .warning }.count
        unknown = issues.filter { $0.kind == .service && $0.severity == .unknown }.count
            + max(0, unavailableSourceCount)
        down = issues.filter { $0.kind == .host }.count
    }

    var attentionCount: Int {
        critical + warning + unknown + down
    }

    var compactText: String {
        [
            critical > 0 ? "C:\(critical)" : nil,
            warning > 0 ? "W:\(warning)" : nil,
            unknown > 0 ? "U:\(unknown)" : nil,
            down > 0 ? "D:\(down)" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

struct StatusMenuView: View {
    @ObservedObject var model: IssueLightModel
    @ObservedObject var externalActions: ExternalActionCoordinator
    @ObservedObject var filters: PanelFilterSettings
    @Environment(\.openSettings) private var openSettings
    @State private var pendingAction: PendingIssueAction?

    var body: some View {
        StatusMenuContent(
            hasConfiguredSource: model.hasConfiguredSource,
            hasEnabledSource: model.hasEnabledSource,
            hasActiveSnapshot: model.hasActiveSnapshot,
            actionableIssues: model.actionableIssues,
            coveredIssues: model.coveredIssues,
            sourceNames: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.name) }),
            sourceFailures: model.failedSources,
            filters: filters,
            refreshState: model.refreshState,
            actionError: model.actionError?.message,
            supportedActions: model.supportedActions,
            activeActionIssueIDs: model.activeActionIssueIDs,
            openSettings: {
                NSApp.keyWindow?.orderOut(nil)
                openSettings()
                NSApp.activate()
            },
            quitApplication: {
                NSApp.terminate(nil)
            },
            openIssue: { issue in
                Task {
                    guard let target = model.webTarget(for: issue) else {
                        model.reportMissingWebConfiguration()
                        return
                    }
                    if case .failure(let error) = await externalActions.openWeb(target) {
                        model.reportExternalActionError(error)
                    }
                }
            },
            openSSH: { issue in
                guard let url = model.sshURL(for: issue) else { return }
                if case .failure(let error) = externalActions.openRemote(url) {
                    model.reportExternalActionError(error)
                }
            },
            openRDP: { issue in
                guard let url = model.rdpURL(for: issue) else { return }
                if case .failure(let error) = externalActions.openRemote(url) {
                    model.reportExternalActionError(error)
                }
            },
            hasSSH: { model.sshURL(for: $0) != nil },
            hasRDP: { model.rdpURL(for: $0) != nil },
            performRecheck: { issue in
                Task { await model.perform(.recheck, on: issue) }
            },
            requestAcknowledgement: { issue in
                pendingAction = PendingIssueAction(issue: issue, kind: .acknowledge)
            },
            requestDowntime: { issue in
                pendingAction = PendingIssueAction(issue: issue, kind: .scheduleDowntime)
            },
            dismissActionError: model.dismissActionError
        )
        .onChange(of: model.sources.map(\.id), initial: true) { _, sourceIDs in
            filters.reconcile(
                sourceIDs: Set(sourceIDs),
                isAuthoritative: model.hasLoadedSources
            )
        }
        .onChange(of: model.hasLoadedSources) { _, hasLoadedSources in
            filters.reconcile(
                sourceIDs: Set(model.sources.map(\.id)),
                isAuthoritative: hasLoadedSources
            )
        }
        .onDisappear {
            pendingAction = nil
        }
        .sheet(item: $pendingAction, onDismiss: { pendingAction = nil }) { pendingAction in
            IssueActionSheet(model: model, pendingAction: pendingAction)
        }
    }
}

private struct PendingIssueAction: Identifiable {
    let id = UUID()
    let issue: MonitoringIssue
    let kind: MonitoringActionKind
}

struct StatusMenuContent: View {
    let hasConfiguredSource: Bool
    let hasEnabledSource: Bool
    let hasActiveSnapshot: Bool
    let actionableIssues: [MonitoringIssue]
    let coveredIssues: [MonitoringIssue]
    let sourceNames: [UUID: String]
    let sourceFailures: [IssueLightModel.SourceFailure]
    @ObservedObject var filters: PanelFilterSettings
    let refreshState: IssueLightModel.RefreshState
    let actionError: String?
    let supportedActions: (MonitoringIssue) -> Set<MonitoringActionKind>
    let activeActionIssueIDs: Set<String>
    let openSettings: () -> Void
    let quitApplication: () -> Void
    let openIssue: (MonitoringIssue) -> Void
    let openSSH: (MonitoringIssue) -> Void
    let openRDP: (MonitoringIssue) -> Void
    let hasSSH: (MonitoringIssue) -> Bool
    let hasRDP: (MonitoringIssue) -> Bool
    let performRecheck: (MonitoringIssue) -> Void
    let requestAcknowledgement: (MonitoringIssue) -> Void
    let requestDowntime: (MonitoringIssue) -> Void
    let dismissActionError: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchText = ""
    @State private var isShowingFilters = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if hasPanelRows {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        AppLocalization.string("Probleme durchsuchen", locale: locale),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("issue-search")
                } else {
                    Spacer()
                }
                if refreshState == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                if hasPanelRows || filters.isActive {
                    filterButton
                }
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                        .pointerHoverFeedback()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(AppLocalization.string("Einstellungen …", locale: locale))
                .accessibilityLabel(AppLocalization.string("Einstellungen …", locale: locale))
                .accessibilityIdentifier("open-settings")
                Button(action: quitApplication) {
                    Image(systemName: "power")
                        .frame(width: 28, height: 28)
                        .pointerHoverFeedback()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .keyboardShortcut("q", modifiers: .command)
                .help(AppLocalization.string("IssueLight beenden", locale: locale))
                .accessibilityLabel(AppLocalization.string("IssueLight beenden", locale: locale))
                .accessibilityIdentifier("quit-application")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let actionError {
                StatusActionErrorBanner(message: actionError, dismiss: dismissActionError)
                Divider()
            }

            issuePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panelHeight: CGFloat {
        if !hasConfiguredSource || !hasEnabledSource {
            return 220
        }
        if !hasActiveSnapshot && sourceFailures.isEmpty {
            return 220
        }
        if !hasPanelRows {
            return 200
        }
        let visibleRowCount = filteredSourceFailures.count
            + filteredActionableIssues.count
            + filteredCoveredIssues.count
        if visibleRowCount == 0 {
            return 200
        }
        let actionErrorHeight: CGFloat = actionError == nil ? 0 : ceil(44 * panelTextScale)
        return min(
            520,
            ceil(49 * panelTextScale)
                + CGFloat(visibleRowCount) * issueRowHeight
                + actionErrorHeight
        )
    }

    private var hasPanelRows: Bool {
        !sourceFailures.isEmpty || !actionableIssues.isEmpty || !coveredIssues.isEmpty
    }

    private var issueRowHeight: CGFloat {
        ceil(39 * panelTextScale)
    }

    private var panelTextScale: CGFloat {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large:
            1
        case .xLarge:
            1.08
        case .xxLarge:
            1.18
        case .xxxLarge:
            1.28
        case .accessibility1:
            1.38
        case .accessibility2:
            1.49
        case .accessibility3:
            1.59
        case .accessibility4:
            1.74
        case .accessibility5:
            1.9
        @unknown default:
            1.38
        }
    }

    private var filteredActionableIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames)
            .filter(actionableIssues)
            .filter { filters.includes($0, isCovered: false) }
    }

    private var filteredCoveredIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames)
            .filter(coveredIssues)
            .filter { filters.includes($0, isCovered: true) }
    }

    private var filteredSourceFailures: [IssueLightModel.SourceFailure] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceFailures.filter { failure in
            if !filters.sourceID.isEmpty,
               failure.source.id.uuidString.lowercased() != filters.sourceID {
                return false
            }
            guard !query.isEmpty else { return true }
            return failure.source.name.localizedCaseInsensitiveContains(query)
                || failure.source.endpoint.absoluteString.localizedCaseInsensitiveContains(query)
                || failure.message.localizedCaseInsensitiveContains(query)
        }
    }

    private var filterButton: some View {
        Button {
            isShowingFilters.toggle()
        } label: {
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .frame(width: 28, height: 28)
                .pointerHoverFeedback()
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(AppLocalization.string("Filter", locale: locale))
        .accessibilityLabel(AppLocalization.string("Filter", locale: locale))
        .accessibilityIdentifier("issue-filter")
        .popover(isPresented: $isShowingFilters, arrowEdge: .top) {
            PanelFilterPopover(
                filters: filters,
                hostOptions: hostOptions,
                sourceNames: sourceNames
            )
            .environment(\.locale, locale)
            .opaqueInteractiveSurface()
        }
    }

    private var hostOptions: [PanelHostSelection] {
        let visibleHosts = Set(
            (actionableIssues + coveredIssues).map(PanelHostSelection.init(issue:))
        )
        return visibleHosts.union(filters.excludedHosts).sorted { lhs, rhs in
            let lhsSource = sourceNames[lhs.sourceID] ?? ""
            let rhsSource = sourceNames[rhs.sourceID] ?? ""
            let sourceOrder = lhsSource.localizedCaseInsensitiveCompare(rhsSource)
            if sourceOrder != .orderedSame {
                return sourceOrder == .orderedAscending
            }
            return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
        }
    }

    @ViewBuilder
    private var issuePanel: some View {
        if !hasConfiguredSource {
            ContentUnavailableView(
                AppLocalization.string("Keine Quelle konfiguriert", locale: locale),
                systemImage: "server.rack",
                description: Text(verbatim: AppLocalization.string("Füge zuerst eine Monitoring-Quelle hinzu.", locale: locale))
            )
        } else if !hasEnabledSource {
            ContentUnavailableView(
                AppLocalization.string("Keine Quelle aktiv", locale: locale),
                systemImage: "pause.circle",
                description: Text(verbatim: AppLocalization.string("Aktiviere mindestens eine Quelle, um den Status zu überwachen.", locale: locale))
            )
        } else if hasPanelRows {
            if filteredSourceFailures.isEmpty
                && filteredActionableIssues.isEmpty
                && filteredCoveredIssues.isEmpty {
                ContentUnavailableView(
                    AppLocalization.string("Keine Treffer", locale: locale),
                    systemImage: "magnifyingglass",
                    description: Text(
                        verbatim: AppLocalization.string(
                            searchText.isEmpty
                                ? "Keine Probleme entsprechen den aktiven Filtern."
                                : "Kein Problem passt zu „\(searchText)“.",
                            locale: locale
                        )
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSourceFailures) { failure in
                            StatusPanelSourceFailureRow(
                                failure: failure,
                                rowHeight: issueRowHeight
                            )
                        }
                        ForEach(filteredActionableIssues) { issue in
                            issueEntry(issue)
                        }
                        ForEach(filteredCoveredIssues) { issue in
                            issueEntry(issue)
                        }
                    }
                }
            }
        } else if hasActiveSnapshot {
            ContentUnavailableView(
                AppLocalization.string("Alles ruhig", locale: locale),
                systemImage: "checkmark.circle",
                description: Text(verbatim: AppLocalization.string("Keine Hosts oder Services benötigen Aufmerksamkeit.", locale: locale))
            )
        } else if case .failed(let message) = refreshState {
            ContentUnavailableView(
                AppLocalization.string("Status konnte nicht geladen werden", locale: locale),
                systemImage: "wifi.exclamationmark",
                description: Text(verbatim: message)
            )
        } else {
            ContentUnavailableView(
                AppLocalization.string("Status wird geladen", locale: locale),
                systemImage: "arrow.clockwise",
                description: Text(verbatim: AppLocalization.string("IssueLight fragt Hosts und Services bei der Quelle ab.", locale: locale))
            )
        }
    }

    private func issueEntry(_ issue: MonitoringIssue) -> some View {
        StatusPanelIssueEntry(
            issue: issue,
            sourceName: sourceNames[issue.sourceID] ?? AppLocalization.string("Unbekannte Quelle", locale: locale),
            isPerformingAction: activeActionIssueIDs.contains(issue.id),
            actions: supportedActions(issue),
            openIssue: { openIssue(issue) },
            openSSH: hasSSH(issue) ? { openSSH(issue) } : nil,
            openRDP: hasRDP(issue) ? { openRDP(issue) } : nil,
            performRecheck: { performRecheck(issue) },
            requestAcknowledgement: { requestAcknowledgement(issue) },
            requestDowntime: { requestDowntime(issue) },
            rowHeight: issueRowHeight
        )
    }

}

struct PanelFilterPopover: View {
    @ObservedObject var filters: PanelFilterSettings
    let hostOptions: [PanelHostSelection]
    let sourceNames: [UUID: String]
    @Environment(\.locale) private var locale
    @State private var hostSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: AppLocalization.string("Filter", locale: locale))
                    .font(.headline)
                Spacer()
                if filters.isActive {
                    Button(AppLocalization.string("Filter zurücksetzen", locale: locale)) {
                        filters.reset()
                    }
                    .buttonStyle(.link)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: AppLocalization.string("Instanz", locale: locale))
                        .foregroundStyle(.secondary)
                    sourcePicker
                }
                GridRow {
                    Text(verbatim: AppLocalization.string("Status", locale: locale))
                        .foregroundStyle(.secondary)
                    severityPicker
                }
                GridRow {
                    Text(verbatim: AppLocalization.string("Sichtbarkeit", locale: locale))
                        .foregroundStyle(.secondary)
                    coveragePicker
                }
            }

            Divider()

            HStack {
                Text(verbatim: AppLocalization.string("Hosts ausblenden", locale: locale))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !filters.excludedHosts.isEmpty {
                    Text(verbatim: "\(filters.excludedHosts.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            TextField(
                AppLocalization.string("Hosts durchsuchen", locale: locale),
                text: $hostSearch
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("host-filter-search")

            if filteredHostOptions.isEmpty {
                ContentUnavailableView(
                    AppLocalization.string("Keine Treffer", locale: locale),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredHostOptions) { selection in
                    Toggle(
                        isOn: Binding(
                            get: { filters.isHostExcluded(selection) },
                            set: { filters.setHost(selection, excluded: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: selection.hostName)
                                .lineLimit(1)
                            if let sourceName = sourceNames[selection.sourceID] {
                                Text(verbatim: sourceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .accessibilityIdentifier("host-filter-list")
            }

            if !filters.excludedHosts.isEmpty {
                Button(AppLocalization.string("Alle Hosts anzeigen", locale: locale)) {
                    filters.showAllHosts()
                }
                .buttonStyle(.bordered)
                .pointerHoverFeedback(cornerRadius: 7)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(width: 380, height: 480)
        .accessibilityIdentifier("filter-popover")
    }

    private var sourcePicker: some View {
        Picker("", selection: $filters.sourceID) {
            Text(verbatim: AppLocalization.string("Alle Instanzen", locale: locale)).tag("")
            ForEach(
                sourceNames.sorted(by: {
                    $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
                }),
                id: \.key
            ) { sourceID, name in
                Text(verbatim: name).tag(sourceID.uuidString.lowercased())
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var severityPicker: some View {
        Picker("", selection: $filters.severity) {
            Text(verbatim: AppLocalization.string("Alle Zustände", locale: locale)).tag(PanelSeverityFilter.all)
            Text(verbatim: AppLocalization.string("Kritisch", locale: locale)).tag(PanelSeverityFilter.critical)
            Text(verbatim: AppLocalization.string("Warnung", locale: locale)).tag(PanelSeverityFilter.warning)
            Text(verbatim: AppLocalization.string("Unbekannt", locale: locale)).tag(PanelSeverityFilter.unknown)
            Text(verbatim: "DOWN").tag(PanelSeverityFilter.down)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coveragePicker: some View {
        Picker("", selection: $filters.coverage) {
            Text(verbatim: AppLocalization.string("Alle Probleme", locale: locale)).tag(PanelCoverageFilter.all)
            Text(verbatim: AppLocalization.string("Benötigt Aufmerksamkeit", locale: locale)).tag(PanelCoverageFilter.attention)
            Text(verbatim: AppLocalization.string("Quittiert oder in Wartungszeit", locale: locale)).tag(PanelCoverageFilter.covered)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredHostOptions: [PanelHostSelection] {
        let query = hostSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hostOptions }
        return hostOptions.filter { selection in
            selection.hostName.localizedCaseInsensitiveContains(query)
                || (sourceNames[selection.sourceID] ?? "").localizedCaseInsensitiveContains(query)
        }
    }
}

private struct StatusPanelSourceFailureRow: View {
    let failure: IssueLightModel.SourceFailure
    let rowHeight: CGFloat
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: failure.source.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: AppLocalization.string("Status konnte nicht geladen werden", locale: locale))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 214, alignment: .leading)
            Text(verbatim: failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(Color.red.opacity(0.09))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) { Divider().padding(.leading, 10) }
        .help(hoverText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hoverText)
    }

    private var hoverText: String {
        [
            failure.source.name,
            failure.source.endpoint.absoluteString,
            AppLocalization.string("Status konnte nicht geladen werden", locale: locale),
            failure.message,
        ]
        .joined(separator: "\n")
    }
}

struct StatusActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            IssueLightSignalGlyph(state: .failed)
                .foregroundStyle(.red)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .pointerHoverFeedback()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Abbrechen", locale: locale))
            .accessibilityIdentifier("dismiss-action-error")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("action-error")
    }
}

struct MonitoringIssueSearch {
    let query: String
    let sourceNames: [UUID: String]

    init(query: String, sourceNames: [UUID: String]) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceNames = sourceNames
    }

    func filter(_ issues: [MonitoringIssue]) -> [MonitoringIssue] {
        guard !query.isEmpty else { return issues }
        return issues.filter { issue in
            issue.displayName.localizedCaseInsensitiveContains(query)
                || issue.hostName.localizedCaseInsensitiveContains(query)
                || issue.summary.localizedCaseInsensitiveContains(query)
                || (sourceNames[issue.sourceID] ?? "").localizedCaseInsensitiveContains(query)
        }
    }
}

private struct StatusPanelIssueEntry: View {
    let issue: MonitoringIssue
    let sourceName: String
    let isPerformingAction: Bool
    let actions: Set<MonitoringActionKind>
    let openIssue: () -> Void
    let openSSH: (() -> Void)?
    let openRDP: (() -> Void)?
    let performRecheck: () -> Void
    let requestAcknowledgement: () -> Void
    let requestDowntime: () -> Void
    let rowHeight: CGFloat
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 4) {
            Button(action: openIssue) {
                StatusPanelIssueRow(
                    issue: issue,
                    sourceName: sourceName
                )
                .pointerHoverFeedback(cornerRadius: 0)
            }
            .buttonStyle(.plain)

            if isPerformingAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 84)
            } else {
                quickAction(
                    AppLocalization.string("Erneut prüfen", locale: locale),
                    systemImage: "play.circle",
                    enabled: actions.contains(.recheck),
                    action: performRecheck
                )
                quickAction(
                    AppLocalization.string("Quittieren …", locale: locale),
                    systemImage: "checkmark.message",
                    enabled: actions.contains(.acknowledge) && !issue.isAcknowledged,
                    action: requestAcknowledgement
                )
                quickAction(
                    AppLocalization.string("Wartungszeit", locale: locale),
                    systemImage: "calendar.badge.clock",
                    enabled: actions.contains(.scheduleDowntime) && !issue.isInDowntime,
                    action: requestDowntime
                )
            }
        }
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .background(issue.presentationColor.opacity(issue.requiresAttention ? 0.09 : 0.045))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(issue.presentationColor)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) { Divider().padding(.leading, 34) }
        .contextMenu {
            if let openSSH {
                Button("SSH für überwachten Host", systemImage: "terminal", action: openSSH)
            }
            if let openRDP {
                Button("RDP für überwachten Host", systemImage: "rectangle.connected.to.line.below", action: openRDP)
            }
        }
    }

    private func quickAction(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 28)
                .pointerHoverFeedback()
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct IssueActionSheet: View {
    @ObservedObject var model: IssueLightModel
    let pendingAction: PendingIssueAction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var author = NSFullUserName()
    @State private var comment = ""
    @State private var duration: TimeInterval = 3_600

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: title)
                .font(.title2.bold())
            Text(verbatim: pendingAction.issue.summary)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            IssueActionInputFields(
                author: $author,
                comment: $comment,
                duration: $duration,
                includesDuration: pendingAction.kind == .scheduleDowntime
            )

            HStack {
                Spacer()
                Button(AppLocalization.string("Abbrechen", locale: locale)) { dismiss() }
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.string("Bestätigen", locale: locale)) {
                    let issue = pendingAction.issue
                    let action: MonitoringAction
                    if pendingAction.kind == .acknowledge {
                        action = .acknowledge(author: author, comment: comment)
                    } else {
                        let start = Date()
                        action = .scheduleDowntime(
                            author: author,
                            comment: comment,
                            start: start,
                            end: start.addingTimeInterval(duration)
                        )
                    }
                    dismiss()
                    Task { await model.perform(action, on: issue) }
                }
                .buttonStyle(.borderedProminent)
                .pointerHoverFeedback(cornerRadius: 7)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(22)
        .frame(width: 480)
        .opaqueInteractiveSurface()
    }

    private var title: String {
        pendingAction.kind == .acknowledge
            ? AppLocalization.string("Problem quittieren", locale: locale)
            : AppLocalization.string("Wartungszeit planen", locale: locale)
    }
}

struct IssueActionInputFields: View {
    @Binding var author: String
    @Binding var comment: String
    @Binding var duration: TimeInterval
    let includesDuration: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text(verbatim: AppLocalization.string("Autor", locale: locale))
                    .foregroundStyle(.secondary)
                TextField(AppLocalization.string("Autor", locale: locale), text: $author)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("action-author")
            }
            GridRow(alignment: .top) {
                Text(verbatim: AppLocalization.string("Kommentar", locale: locale))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                TextField(
                    AppLocalization.string("Kommentar", locale: locale),
                    text: $comment,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityIdentifier("action-comment")
            }
            if includesDuration {
                GridRow {
                    Text(verbatim: AppLocalization.string("Dauer", locale: locale))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $duration) {
                        Text(verbatim: AppLocalization.string("30 Minuten", locale: locale)).tag(TimeInterval(1_800))
                        Text(verbatim: AppLocalization.string("1 Stunde", locale: locale)).tag(TimeInterval(3_600))
                        Text(verbatim: AppLocalization.string("2 Stunden", locale: locale)).tag(TimeInterval(7_200))
                        Text(verbatim: AppLocalization.string("4 Stunden", locale: locale)).tag(TimeInterval(14_400))
                    }
                    .labelsHidden()
                    .accessibilityLabel(AppLocalization.string("Dauer", locale: locale))
                    .accessibilityIdentifier("action-duration")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusPanelIssueRow: View {
    let issue: MonitoringIssue
    let sourceName: String
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: sourceName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 214, alignment: .leading)
            Text(verbatim: summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let durationText {
                Text(verbatim: durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            if let attemptText {
                Text(verbatim: attemptText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            if issue.isAcknowledged || issue.isInDowntime {
                Image(systemName: issue.isInDowntime ? "calendar.badge.clock" : "checkmark.message")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
        }
        .padding(.leading, 10)
        .contentShape(Rectangle())
        .help(hoverText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var title: String {
        issue.kind == .host ? issue.displayName : "\(issue.hostName) · \(issue.displayName)"
    }

    private var severityText: String {
        if issue.kind == .host {
            return "DOWN"
        }
        switch issue.severity {
        case .critical: return AppLocalization.string("Kritisch", locale: locale)
        case .unknown: return AppLocalization.string("Unbekannt", locale: locale)
        case .warning: return AppLocalization.string("Warnung", locale: locale)
        }
    }

    private var summaryText: String {
        let summary = issue.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = summary.lowercased(with: locale)
        let knownPrefixes = ["CRITICAL", "WARNING", "UNKNOWN", "DOWN", severityText]
        let alreadyIncludesState = knownPrefixes.contains { prefix in
            let normalizedPrefix = prefix.lowercased(with: locale)
            return normalizedSummary == normalizedPrefix
                || normalizedSummary.hasPrefix("\(normalizedPrefix):")
                || normalizedSummary.hasPrefix("\(normalizedPrefix) ")
                || normalizedSummary.hasPrefix("\(normalizedPrefix) ·")
        }
        return alreadyIncludesState ? summary : "\(severityText) · \(summary)"
    }

    private var durationText: String? {
        guard let stateChangedAt = issue.stateChangedAt else { return nil }
        let interval = max(0, Date.now.timeIntervalSince(stateChangedAt))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: interval)
    }

    private var attemptText: String? {
        guard let checkAttempt = issue.checkAttempt,
              let maxCheckAttempts = issue.maxCheckAttempts else {
            return nil
        }
        return "\(checkAttempt)/\(maxCheckAttempts)"
    }

    private var coverageText: String {
        switch (issue.isAcknowledged, issue.isInDowntime) {
        case (true, true):
            return AppLocalization.string("Quittiert · Wartungszeit", locale: locale)
        case (true, false):
            return AppLocalization.string("Quittiert", locale: locale)
        case (false, true):
            return AppLocalization.string("Wartungszeit", locale: locale)
        case (false, false):
            return ""
        }
    }

    private var hoverText: String {
        [sourceName, severityText, title, issue.summary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var accessibilityText: String {
        [sourceName, severityText, title, issue.summary, durationText, attemptText, coverageText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }
}

private extension MonitoringIssue {
    var presentationColor: Color {
        switch severity {
        case .critical: return .red
        case .unknown: return .purple
        case .warning: return .orange
        }
    }
}
