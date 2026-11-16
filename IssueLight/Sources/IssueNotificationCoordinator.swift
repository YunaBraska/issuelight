import Combine
import Foundation
import IssueLightCore
import UserNotifications

enum IssueNotificationPolicy: String, CaseIterable, Codable, Sendable {
    case disabled
    case criticalOnly
    case warningAndCritical
    case allAttentionStates

    func includes(_ severity: MonitoringSeverity) -> Bool {
        switch self {
        case .disabled:
            return false
        case .criticalOnly:
            return severity == .critical
        case .warningAndCritical:
            return severity == .warning || severity == .critical
        case .allAttentionStates:
            return true
        }
    }

    func displayName(locale: Locale) -> String {
        switch self {
        case .disabled:
            return AppLocalization.string("Aus", locale: locale)
        case .criticalOnly:
            return AppLocalization.string("Nur kritisch", locale: locale)
        case .warningAndCritical:
            return AppLocalization.string("Warnungen und kritisch", locale: locale)
        case .allAttentionStates:
            return AppLocalization.string("Alle Zustände", locale: locale)
        }
    }
}

@MainActor
final class IssueNotificationPolicyStore: ObservableObject {
    @Published private(set) var policies: [UUID: IssueNotificationPolicy]

    private let defaults: UserDefaults
    private let key = "issueNotificationPolicies"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        policies = Dictionary(
            uniqueKeysWithValues: stored.compactMap { identifier, rawValue in
                guard let sourceID = UUID(uuidString: identifier),
                      let policy = IssueNotificationPolicy(rawValue: rawValue),
                      policy != .disabled else {
                    return nil
                }
                return (sourceID, policy)
            }
        )
    }

    func policy(for sourceID: UUID) -> IssueNotificationPolicy {
        policies[sourceID] ?? .disabled
    }

    func set(_ policy: IssueNotificationPolicy, for sourceID: UUID) {
        if policy == .disabled {
            policies[sourceID] = nil
        } else {
            policies[sourceID] = policy
        }
        persist()
    }

    func reconcile(sourceIDs: Set<UUID>) {
        let retained = policies.filter { sourceIDs.contains($0.key) }
        guard retained != policies else { return }
        policies = retained
        persist()
    }

    private func persist() {
        defaults.set(
            Dictionary(
                uniqueKeysWithValues: policies.map {
                    ($0.key.uuidString.lowercased(), $0.value.rawValue)
                }
            ),
            forKey: key
        )
    }
}

struct IssueNotificationSummary: Equatable {
    let identifier: String
    let issueCount: Int
    let highestSeverity: MonitoringSeverity
    let issueForNavigation: MonitoringIssue
}

struct IssueNotificationPlan: Equatable {
    let summary: IssueNotificationSummary?
    let removesDeliveredSummary: Bool
}

struct IssueNotificationPlanner {
    private struct SourceState {
        var eligibleSeverities: [String: MonitoringSeverity]
        var hasDeliveredSummary: Bool
        var policy: IssueNotificationPolicy
    }

    private var states: [UUID: SourceState] = [:]

    mutating func update(
        sourceID: UUID,
        actionableIssues: [MonitoringIssue],
        policy: IssueNotificationPolicy
    ) -> IssueNotificationPlan {
        let identifier = Self.identifier(for: sourceID)
        if policy == .disabled {
            let removesSummary = states.removeValue(forKey: sourceID)?.hasDeliveredSummary == true
            return IssueNotificationPlan(summary: nil, removesDeliveredSummary: removesSummary)
        }

        let eligibleIssues = actionableIssues.filter { policy.includes($0.severity) }
        let eligibleSeverities = Dictionary(
            uniqueKeysWithValues: eligibleIssues.map { ($0.id, $0.severity) }
        )
        guard var state = states[sourceID] else {
            states[sourceID] = SourceState(
                eligibleSeverities: eligibleSeverities,
                hasDeliveredSummary: false,
                policy: policy
            )
            return IssueNotificationPlan(summary: nil, removesDeliveredSummary: false)
        }

        if state.policy != policy {
            let removesSummary = state.hasDeliveredSummary
            states[sourceID] = SourceState(
                eligibleSeverities: eligibleSeverities,
                hasDeliveredSummary: false,
                policy: policy
            )
            return IssueNotificationPlan(summary: nil, removesDeliveredSummary: removesSummary)
        }

        let hasNewOrEscalatedIssue = eligibleSeverities.contains { issueID, severity in
            guard let previousSeverity = state.eligibleSeverities[issueID] else { return true }
            return severity > previousSeverity
        }
        state.eligibleSeverities = eligibleSeverities
        if eligibleIssues.isEmpty {
            let removesSummary = state.hasDeliveredSummary
            state.hasDeliveredSummary = false
            states[sourceID] = state
            return IssueNotificationPlan(summary: nil, removesDeliveredSummary: removesSummary)
        }

        guard hasNewOrEscalatedIssue,
              let navigationIssue = eligibleIssues.sorted(by: Self.issueOrder).first,
              let highestSeverity = eligibleIssues.map(\.severity).max() else {
            states[sourceID] = state
            return IssueNotificationPlan(summary: nil, removesDeliveredSummary: false)
        }

        state.hasDeliveredSummary = true
        states[sourceID] = state
        return IssueNotificationPlan(
            summary: IssueNotificationSummary(
                identifier: identifier,
                issueCount: eligibleIssues.count,
                highestSeverity: highestSeverity,
                issueForNavigation: navigationIssue
            ),
            removesDeliveredSummary: false
        )
    }

    mutating func reset(sourceID: UUID) -> Bool {
        states.removeValue(forKey: sourceID)?.hasDeliveredSummary == true
    }

    mutating func reconcile(sourceIDs: Set<UUID>) -> [String] {
        let removedSourceIDs = states.keys.filter { !sourceIDs.contains($0) }
        return removedSourceIDs.compactMap { sourceID in
            let removesSummary = states.removeValue(forKey: sourceID)?.hasDeliveredSummary == true
            return removesSummary ? Self.identifier(for: sourceID) : nil
        }
    }

    static func identifier(for sourceID: UUID) -> String {
        "issuelight.source.\(sourceID.uuidString.lowercased())"
    }

    private static func issueOrder(_ lhs: MonitoringIssue, _ rhs: MonitoringIssue) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }
}

enum IssueNotificationAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
}

enum IssueNotificationInterruption: Equatable {
    case passive
    case active
}

struct IssueNotificationContent: Equatable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
    let interruption: IssueNotificationInterruption
}

@MainActor
protocol IssueNotificationCenterClient: AnyObject {
    func setResponseHandler(_ handler: @escaping @MainActor (String) -> Void)
    func currentAuthorization() async -> IssueNotificationAuthorization
    func requestAuthorization() async -> IssueNotificationAuthorization
    func deliver(_ content: IssueNotificationContent) async throws
    func remove(identifier: String)
    func removeAll()
}

@MainActor
final class SystemIssueNotificationCenter: NSObject, IssueNotificationCenterClient,
    UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var responseHandler: (@MainActor (String) -> Void)?

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func setResponseHandler(_ handler: @escaping @MainActor (String) -> Void) {
        responseHandler = handler
    }

    func currentAuthorization() async -> IssueNotificationAuthorization {
        let settings = await center.notificationSettings()
        return Self.authorization(from: settings.authorizationStatus)
    }

    func requestAuthorization() async -> IssueNotificationAuthorization {
        do {
            _ = try await center.requestAuthorization(options: [.alert])
            return await currentAuthorization()
        } catch {
            return .denied
        }
    }

    func deliver(_ content: IssueNotificationContent) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.threadIdentifier = content.threadIdentifier
        notification.interruptionLevel = content.interruption == .active ? .active : .passive
        try await center.add(
            UNNotificationRequest(
                identifier: content.identifier,
                content: notification,
                trigger: nil
            )
        )
    }

    func remove(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        defer { completionHandler() }
        let identifier = response.notification.request.identifier
        Task { @MainActor [weak self] in
            self?.responseHandler?(identifier)
        }
    }

    private static func authorization(
        from status: UNAuthorizationStatus
    ) -> IssueNotificationAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

@MainActor
final class IssueNotificationCoordinator: ObservableObject {
    @Published private(set) var authorization = IssueNotificationAuthorization.notDetermined
    let policyStore: IssueNotificationPolicyStore

    private let notificationCenter: IssueNotificationCenterClient
    private var planner = IssueNotificationPlanner()
    private var sourceObservation: AnyCancellable?
    private var snapshotObservation: AnyCancellable?
    private var sourceLoadObservation: AnyCancellable?
    private var sources: [MonitoringSource] = []
    private var snapshots: [UUID: MonitoringSnapshot] = [:]
    private var sourceListIsAuthoritative = false
    private var navigationURL: (MonitoringIssue) -> URL? = { _ in nil }
    private var locale: Locale
    private var pendingWork: Task<Void, Never>?
    private var pendingNavigationWork: Task<Void, Never>?
    private var notificationTargets: [String: (sourceID: UUID, url: URL)] = [:]
    private var navigationTarget: (UUID, URL) -> IssueWebTarget? = { _, _ in nil }
    private var openWeb: (IssueWebTarget) async -> Void = { _ in }

    init(
        policyStore: IssueNotificationPolicyStore? = nil,
        notificationCenter: IssueNotificationCenterClient? = nil,
        locale: Locale
    ) {
        self.policyStore = policyStore ?? IssueNotificationPolicyStore()
        self.notificationCenter = notificationCenter ?? SystemIssueNotificationCenter()
        self.locale = locale
        self.notificationCenter.setResponseHandler { [weak self] identifier in
            self?.openNotification(identifier: identifier)
        }
    }

    func configureNavigation(
        issueURL: @escaping (MonitoringIssue) -> URL?,
        target: @escaping (UUID, URL) -> IssueWebTarget?,
        open: @escaping (IssueWebTarget) async -> Void
    ) {
        navigationURL = issueURL
        navigationTarget = target
        openWeb = open
    }

    func observe(_ model: IssueLightModel) {
        sourceObservation = model.$sources.sink { [weak self] sources in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sources = sources
                self.update(
                    sources: sources,
                    snapshots: self.snapshots,
                    isAuthoritative: self.sourceListIsAuthoritative
                )
            }
        }
        snapshotObservation = model.$snapshots.sink { [weak self] snapshots in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshots = snapshots
                self.update(
                    sources: self.sources,
                    snapshots: snapshots,
                    isAuthoritative: self.sourceListIsAuthoritative
                )
            }
        }
        sourceLoadObservation = model.$hasLoadedSources.sink { [weak self] hasLoadedSources in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sourceListIsAuthoritative = hasLoadedSources
                self.update(
                    sources: self.sources,
                    snapshots: self.snapshots,
                    isAuthoritative: hasLoadedSources
                )
            }
        }
    }

    func setLocale(_ locale: Locale) {
        self.locale = locale
    }

    func refreshAuthorizationStatus() async {
        authorization = await notificationCenter.currentAuthorization()
    }

    func prepareForSession() async {
        notificationTargets.removeAll()
        notificationCenter.removeAll()
        await refreshAuthorizationStatus()
    }

    func requestAuthorization() async {
        authorization = await notificationCenter.requestAuthorization()
    }

    func setPolicy(_ policy: IssueNotificationPolicy, for sourceID: UUID) async {
        if planner.reset(sourceID: sourceID) {
            let identifier = IssueNotificationPlanner.identifier(for: sourceID)
            notificationTargets[identifier] = nil
            notificationCenter.remove(identifier: identifier)
        }
        policyStore.set(policy, for: sourceID)
        if policy != .disabled, authorization == .notDetermined {
            authorization = await notificationCenter.requestAuthorization()
        }
        update(
            sources: sources,
            snapshots: snapshots,
            isAuthoritative: sourceListIsAuthoritative
        )
    }

    func update(
        sources: [MonitoringSource],
        snapshots: [UUID: MonitoringSnapshot],
        isAuthoritative: Bool = true
    ) {
        self.sources = sources
        self.snapshots = snapshots
        let sourceIDs = Set(sources.map(\.id))
        if isAuthoritative {
            policyStore.reconcile(sourceIDs: sourceIDs)
        }
        let removedIdentifiers = isAuthoritative
            ? planner.reconcile(sourceIDs: sourceIDs)
            : []
        var contents: [IssueNotificationContent] = []
        var identifiersToRemove = removedIdentifiers

        for source in sources {
            let policy = source.isEnabled ? policyStore.policy(for: source.id) : .disabled
            guard let snapshot = snapshots[source.id] else {
                if policy == .disabled,
                   planner.reset(sourceID: source.id) {
                    identifiersToRemove.append(IssueNotificationPlanner.identifier(for: source.id))
                }
                continue
            }
            let plan = planner.update(
                sourceID: source.id,
                actionableIssues: snapshot.actionableIssues,
                policy: policy
            )
            if plan.removesDeliveredSummary {
                identifiersToRemove.append(IssueNotificationPlanner.identifier(for: source.id))
            }
            if let summary = plan.summary,
               authorization == .authorized {
                contents.append(content(for: summary, source: source))
            }
        }

        guard !identifiersToRemove.isEmpty || !contents.isEmpty else { return }
        for identifier in identifiersToRemove {
            notificationTargets[identifier] = nil
        }
        let previousWork = pendingWork
        pendingWork = Task { [notificationCenter] in
            await previousWork?.value
            guard !Task.isCancelled else { return }
            for identifier in Set(identifiersToRemove) {
                notificationCenter.remove(identifier: identifier)
            }
            for content in contents {
                try? await notificationCenter.deliver(content)
            }
        }
    }

    func waitForPendingWork() async {
        await pendingWork?.value
        await pendingNavigationWork?.value
    }

    private func content(
        for summary: IssueNotificationSummary,
        source: MonitoringSource
    ) -> IssueNotificationContent {
        let title: String
        if summary.issueCount == 1 {
            title = AppLocalization.string("Neues Monitoring-Problem", locale: locale)
        } else {
            title = AppLocalization.string(
                "\(summary.issueCount) neue Monitoring-Probleme",
                locale: locale
            )
        }
        if let url = navigationURL(summary.issueForNavigation) {
            notificationTargets[summary.identifier] = (source.id, url)
        } else {
            notificationTargets[summary.identifier] = nil
        }
        return IssueNotificationContent(
            identifier: summary.identifier,
            title: title,
            body: AppLocalization.string(
                "Öffne IssueLight, um den aktuellen Status zu prüfen.",
                locale: locale
            ),
            threadIdentifier: "issuelight.source.\(source.id.uuidString.lowercased())",
            interruption: summary.highestSeverity == .critical ? .active : .passive
        )
    }

    private func openNotification(identifier: String) {
        guard let storedTarget = notificationTargets[identifier] else { return }
        let sourceID = storedTarget.sourceID
        let url = storedTarget.url
        guard let target = navigationTarget(sourceID, url) else { return }
        let previousWork = pendingNavigationWork
        pendingNavigationWork = Task { [openWeb] in
            await previousWork?.value
            guard !Task.isCancelled else { return }
            await openWeb(target)
        }
    }
}
