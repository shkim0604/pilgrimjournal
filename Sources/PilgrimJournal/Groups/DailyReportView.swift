import Combine
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

// The Daily Report screen (`GET /me/daily-report`, design.md 11절) and the 그룹 section of
// Settings: report on/off and time, the report itself, notification permission, and the
// blocked and hidden lists (task 2.7.3).

// MARK: - Presentation

/// The five parts of a group's report, in the order the screen shows them.
enum DailyReportSectionKind: String, CaseIterable, Sendable {
    case newPosts
    case commentsOnMyPosts
    case reactionsOnMyPosts
    case extendedPosts
    case expiringSoon

    var title: String {
        switch self {
        // Its own key: the bare "새 글" is the feed's "new post" button.
        case .newPosts:
            String(
                localized: "dailyReport.newPosts", defaultValue: "새 글",
                comment: "Daily Report section listing a group's new posts")
        case .commentsOnMyPosts: String(localized: "내 글에 달린 댓글")
        case .reactionsOnMyPosts: String(localized: "내 글에 남긴 반응")
        case .extendedPosts: String(localized: "토론이 연장된 글")
        case .expiringSoon: String(localized: "곧 사라지는 글")
        }
    }

    var systemImage: String {
        switch self {
        case .newPosts: "square.and.pencil"
        case .commentsOnMyPosts: "bubble.left"
        case .reactionsOnMyPosts: "heart"
        case .extendedPosts: "clock.arrow.circlepath"
        case .expiringSoon: "hourglass"
        }
    }

    func posts(in group: DailyReportGroup) -> [DailyReportPost] {
        switch self {
        case .newPosts: group.newPosts
        case .commentsOnMyPosts: group.commentsOnMyPosts
        case .reactionsOnMyPosts: group.reactionsOnMyPosts
        case .extendedPosts: group.extendedPosts
        case .expiringSoon: group.expiringSoon
        }
    }
}

struct DailyReportSection: Equatable, Identifiable, Sendable {
    let kind: DailyReportSectionKind
    let posts: [DailyReportPost]

    var id: DailyReportSectionKind { kind }
}

/// How a `DailyReportResponse` reads on screen. The server decides what is in the report; the
/// app only orders and words it.
enum DailyReportPresentation {
    /// Groups with something to show, in the server's order.
    static func groups(in report: DailyReportResponse) -> [DailyReportGroup] {
        report.groups.filter { $0.itemCount > 0 }
    }

    /// The non-empty parts of a group's report.
    static func sections(for group: DailyReportGroup) -> [DailyReportSection] {
        DailyReportSectionKind.allCases.compactMap { kind in
            let posts = kind.posts(in: group)
            return posts.isEmpty ? nil : DailyReportSection(kind: kind, posts: posts)
        }
    }

    static func title(for post: DailyReportPost) -> String {
        let title = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "제목 없음") : title
    }

    /// The line under a report row's title.
    static func detail(
        for post: DailyReportPost, in kind: DailyReportSectionKind, now: Date,
        calendar: Calendar = .current
    ) -> String {
        switch kind {
        case .newPosts:
            return "\(post.author.displayName) · \(post.kind.groupLabel)"
        case .commentsOnMyPosts:
            return String(localized: "댓글 \(post.count)개")
        case .reactionsOnMyPosts:
            return String(localized: "반응 \(post.count)개")
        case .extendedPosts:
            return
                "\(post.author.displayName) · \(GroupExpiryText.visibleUntil(post.expiresAt, calendar: calendar))"
        case .expiringSoon:
            return
                "\(post.author.displayName) · \(GroupExpiryText.disappearance(post.expiresAt, now: now, calendar: calendar))"
        }
    }

    /// "11월 14일" for the report's day.
    static func dayTitle(_ report: DailyReportResponse) -> String {
        GroupExpiryText.monthDay(report.date)
    }

    /// "11월 13일 오후 10:00 – 11월 14일 오후 10:00" in the device's time zone.
    static func windowText(_ report: DailyReportResponse, calendar: Calendar = .current)
        -> String
    {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "\(report.windowStart.formatted(style)) – \(report.windowEnd.formatted(style))"
    }
}

extension LocalTime {
    /// The wall-clock time of `date` in `calendar`'s time zone (a time picker's value).
    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self =
            LocalTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
            ?? .defaultDailyReport
    }

    /// This time on `day` in `calendar`'s time zone (to seed a time picker).
    func date(on day: Date = Date(), calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// Whether the report time zone on the server differs from this device's.
enum DailyReportTimeZone {
    static func differs(server: String?, device: TimeZone) -> Bool {
        guard let server, let serverZone = TimeZone(identifier: server) else { return false }
        return serverZone.identifier != device.identifier
    }
}

// MARK: - Daily Report screen

@MainActor
final class DailyReportModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(DailyReportResponse)
        case failed(String)
    }

    /// How many days before the latest report the screen can go back.
    static let maximumDaysBack = 6

    @Published private(set) var state: State = .loading
    /// The day on screen; nil until the first answer (the latest finished window).
    @Published private(set) var date: LocalDate?
    /// The day of the latest finished window.
    @Published private(set) var latestDate: LocalDate?

    private let fetch: (LocalDate?) async throws -> DailyReportResponse
    private let onError: (any Error) -> Void

    init(
        fetch: @escaping (LocalDate?) async throws -> DailyReportResponse,
        onError: @escaping (any Error) -> Void = { _ in }
    ) {
        self.fetch = fetch
        self.onError = onError
    }

    convenience init(groups: GroupsController) {
        let api = groups.api
        self.init(
            fetch: { try await api.dailyReport(date: $0) },
            onError: { [weak groups] in groups?.handle($0) })
    }

    var report: DailyReportResponse? {
        if case .loaded(let report) = state { return report }
        return nil
    }

    var canShowPreviousDay: Bool {
        guard let date, let latestDate else { return false }
        return date.days(until: latestDate) < Self.maximumDaysBack
    }

    var canShowNextDay: Bool {
        guard let date, let latestDate else { return false }
        return date < latestDate
    }

    func load() async {
        await load(date: date)
    }

    func showPreviousDay() async {
        guard canShowPreviousDay, let date else { return }
        await load(date: date.adding(days: -1))
    }

    func showNextDay() async {
        guard canShowNextDay, let date else { return }
        await load(date: date.adding(days: 1))
    }

    private func load(date requested: LocalDate?) async {
        // A refresh of the day on screen keeps it visible; another day shows the spinner.
        if report == nil || (requested != nil && report?.date != requested) { state = .loading }
        do {
            let report = try await fetch(requested)
            if requested == nil { latestDate = report.date }
            date = report.date
            state = .loaded(report)
        } catch {
            if GroupContentError.isCancellation(error) { return }
            onError(error)
            state = .failed(GroupContentError.message(for: error))
        }
    }
}

/// The report of one day: new posts in the user's groups, comments and reactions on their
/// posts, extended discussions and posts about to disappear. A row opens the post.
struct DailyReportView: View {
    @StateObject private var model: DailyReportModel
    private let onOpenPost: (UUID, UUID) -> Void

    /// `onOpenPost(groupID, postID)` opens a post the user tapped.
    init(groups: GroupsController, onOpenPost: @escaping (UUID, UUID) -> Void) {
        _model = StateObject(wrappedValue: DailyReportModel(groups: groups))
        self.onOpenPost = onOpenPost
    }

    var body: some View {
        List {
            if let report = model.report {
                content(report)
            }
        }
        .overlay { overlay }
        .navigationTitle("Daily Report")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.showPreviousDay() }
                } label: {
                    Label("이전 날", systemImage: "chevron.left")
                }
                .disabled(!model.canShowPreviousDay)
                Button {
                    Task { await model.showNextDay() }
                } label: {
                    Label("다음 날", systemImage: "chevron.right")
                }
                .disabled(!model.canShowNextDay)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func content(_ report: DailyReportResponse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
                Text(DailyReportPresentation.dayTitle(report))
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                Text(DailyReportPresentation.windowText(report))
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
                if report.totalCount > 0 {
                    Text("소식 \(report.totalCount)개")
                        .font(.subheadline)
                        .foregroundStyle(JournalTheme.brandPrimary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        let now = Date()
        ForEach(DailyReportPresentation.groups(in: report), id: \.groupId) { group in
            Section(group.groupName) {
                ForEach(DailyReportPresentation.sections(for: group)) { section in
                    Label(section.kind.title, systemImage: section.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.posts, id: \.postId) { post in
                        row(post, kind: section.kind, groupID: group.groupId, now: now)
                    }
                }
            }
        }
    }

    private func row(
        _ post: DailyReportPost, kind: DailyReportSectionKind, groupID: UUID, now: Date
    ) -> some View {
        Button {
            onOpenPost(groupID, post.postId)
        } label: {
            HStack(spacing: JournalTheme.Spacing.medium) {
                Image(systemName: post.kind.groupSymbol)
                    .foregroundStyle(post.kind.groupColor)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DailyReportPresentation.title(for: post))
                        .foregroundStyle(JournalTheme.ink)
                        .lineLimit(2)
                    Text(DailyReportPresentation.detail(for: post, in: kind, now: now))
                        .font(.caption)
                        .foregroundStyle(
                            kind == .expiringSoon ? Color.red : JournalTheme.inkSecondary
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("글을 엽니다.")
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            JournalEmptyState(
                title: String(localized: "Daily Report를 불러오지 못했어요"),
                description: message,
                systemImage: "exclamationmark.triangle"
            ) {
                Button("다시 시도") { Task { await model.load() } }
            }
        case .loaded(let report):
            if DailyReportPresentation.groups(in: report).isEmpty {
                JournalEmptyState(
                    title: String(localized: "새 소식이 없어요"),
                    description: String(
                        localized: "이 날은 그룹에 새 글이나 내 글에 달린 댓글·반응이 없었어요."),
                    systemImage: "newspaper"
                ) {}
                .padding(.top, 120)
            }
        }
    }
}

/// The Daily Report opened from a notification, as a sheet over the journal.
struct DailyReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: GroupsController
    let onOpenPost: (UUID, UUID) -> Void

    var body: some View {
        NavigationStack {
            DailyReportView(groups: groups) { groupID, postID in
                dismiss()
                onOpenPost(groupID, postID)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
    }
}

// MARK: - Settings

/// The report settings behind the 그룹 section: `PATCH /me` with `dailyReportEnabled`,
/// `dailyReportTime` and `timeZone`. A failed save puts the old value back and says so.
@MainActor
final class GroupReportSettingsModel: ObservableObject {
    @Published private(set) var hasProfile = false
    @Published private(set) var isEnabled = true
    @Published private(set) var time = LocalTime.defaultDailyReport
    /// The time zone the server sends the report in (`users.time_zone`).
    @Published private(set) var serverTimeZone: String?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var authorization: GroupNotificationAuthorization?

    private let update: (UpdateMeRequest) async throws -> MeResponse
    private let didUpdate: () async -> Void
    private let onError: (any Error) -> Void
    private let center: (any GroupNotificationCenter)?
    private let defaults: UserDefaults
    private let permissionDidChange: () -> Void
    private let debounce: Duration
    private var confirmedTime = LocalTime.defaultDailyReport
    private var pendingTime: Task<Void, Never>?
    private var savesInFlight = 0

    init(
        update: @escaping (UpdateMeRequest) async throws -> MeResponse,
        didUpdate: @escaping () async -> Void = {},
        onError: @escaping (any Error) -> Void = { _ in },
        center: (any GroupNotificationCenter)? = nil,
        defaults: UserDefaults = .standard,
        permissionDidChange: @escaping () -> Void = {},
        debounce: Duration = .milliseconds(800)
    ) {
        self.update = update
        self.didUpdate = didUpdate
        self.onError = onError
        self.center = center
        self.defaults = defaults
        self.permissionDidChange = permissionDidChange
        self.debounce = debounce
    }

    convenience init(groups: GroupsController) {
        let api = groups.api
        self.init(
            update: { try await api.updateMe($0) },
            // Keeps `GroupsController.me` (and with it every other screen) current.
            didUpdate: { [weak groups] in await groups?.loadAccount() },
            onError: { [weak groups] in groups?.handle($0) },
            center: SystemGroupNotificationCenter.shared,
            permissionDidChange: { GroupNotificationOpener.shared.registrar?.scheduleSync() })
    }

    /// Takes the server's values, unless the user is in the middle of changing them.
    func sync(from me: MeResponse?) {
        guard savesInFlight == 0, pendingTime == nil else { return }
        guard let me else {
            hasProfile = false
            return
        }
        apply(me)
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        let previous = isEnabled
        isEnabled = enabled
        await save(UpdateMeRequest(dailyReportEnabled: enabled)) { self.isEnabled = previous }
    }

    /// Saves a picked time after the picker settles, so scrolling sends one request.
    func setTime(_ newTime: LocalTime) {
        guard newTime != time else { return }
        time = newTime
        pendingTime?.cancel()
        pendingTime = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingTime = nil
            await self.save(UpdateMeRequest(dailyReportTime: newTime)) {
                self.time = self.confirmedTime
            }
        }
    }

    /// Waits for a picked time to be saved (tests).
    func waitForPendingTime() async {
        await pendingTime?.value
    }

    func useDeviceTimeZone(_ zone: TimeZone = .current) async {
        await save(UpdateMeRequest(timeZone: zone.identifier)) {}
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.authorizationStatus()
    }

    /// The "알림 켜기" button: the system prompt, then APNs through the registrar.
    func requestAuthorization() async {
        guard let center else { return }
        defaults.set(true, forKey: GroupNotificationRegistrar.askedDefaultsKey)
        _ = await center.requestAuthorization()
        await refreshAuthorization()
        permissionDidChange()
    }

    private func save(_ request: UpdateMeRequest, revert: () -> Void) async {
        savesInFlight += 1
        isSaving = true
        errorMessage = nil
        defer {
            savesInFlight -= 1
            isSaving = savesInFlight > 0
        }
        do {
            apply(try await update(request))
        } catch {
            onError(error)
            revert()
            errorMessage = GroupMessages.text(for: GroupsController.normalize(error))
            return
        }
        await didUpdate()
    }

    private func apply(_ me: MeResponse) {
        hasProfile = true
        isEnabled = me.dailyReportEnabled
        confirmedTime = me.dailyReportTime
        if pendingTime == nil { time = me.dailyReportTime }
        serverTimeZone = me.timeZone
    }
}

/// Settings → 그룹: Daily Report on/off and time, the report, notification permission, and the
/// blocked and hidden lists. SettingsView shows it only while `GroupsFeature` is on.
struct GroupsSettingsSection: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var groups: GroupsController
    @StateObject private var model: GroupReportSettingsModel
    @State private var deviceTimeZone = TimeZone.current

    init(groups: GroupsController) {
        _groups = ObservedObject(wrappedValue: groups)
        _model = StateObject(wrappedValue: GroupReportSettingsModel(groups: groups))
    }

    var body: some View {
        Section {
            if groups.accountState.hasGroupAccess, model.hasProfile {
                reportRows
                notificationRows
                NavigationLink {
                    BlockedUsersView(api: groups.api)
                } label: {
                    Label("차단한 사람", systemImage: "person.crop.circle.badge.xmark")
                }
                NavigationLink {
                    HiddenItemsView(api: groups.api)
                } label: {
                    Label("숨긴 항목", systemImage: "eye.slash")
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("그룹에 로그인하면 Daily Report와 차단·숨김 목록을 여기서 관리할 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("그룹")
        } footer: {
            Text("Daily Report는 하루 한 번, 정한 시각까지 24시간 동안의 그룹 소식을 알려 줘요. 그룹마다 빼려면 그룹 설정에서 바꿀 수 있어요.")
        }
        .task {
            model.sync(from: groups.me)
            if groups.me == nil { await groups.loadAccount() }
            await model.refreshAuthorization()
        }
        .onChange(of: groups.me) { _, me in model.sync(from: me) }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            deviceTimeZone = .current
        }
    }

    @ViewBuilder
    private var reportRows: some View {
        Toggle(
            "Daily Report",
            isOn: Binding(
                get: { model.isEnabled },
                set: { value in Task { await model.setEnabled(value) } }))
        DatePicker(
            "보내는 시각",
            selection: Binding(
                get: { model.time.date(calendar: .current) },
                set: { model.setTime(LocalTime(date: $0, calendar: .current)) }),
            displayedComponents: .hourAndMinute
        )
        .disabled(!model.isEnabled)
        if DailyReportTimeZone.differs(server: model.serverTimeZone, device: deviceTimeZone) {
            LabeledContent("리포트 시간대", value: model.serverTimeZone ?? "")
            Button("이 기기 시간대(\(deviceTimeZone.identifier))로 바꾸기") {
                Task { await model.useDeviceTimeZone(deviceTimeZone) }
            }
            .disabled(model.isSaving)
        }
        NavigationLink {
            DailyReportView(groups: groups, onOpenPost: openPost)
        } label: {
            Label("Daily Report 보기", systemImage: "newspaper")
        }
    }

    @ViewBuilder
    private var notificationRows: some View {
        switch model.authorization {
        case .denied:
            LabeledContent("알림", value: String(localized: "꺼짐"))
            if let url = SystemGroupNotificationCenter.settingsURL {
                Link(destination: url) {
                    Label("시스템 설정에서 알림 켜기", systemImage: "bell.badge")
                }
            }
        case .notDetermined:
            Button {
                Task { await model.requestAuthorization() }
            } label: {
                Label("그룹 알림 켜기", systemImage: "bell")
            }
        case .authorized, .provisional, nil:
            EmptyView()
        }
    }

    private func openPost(groupID: UUID, postID: UUID) {
        let route = GroupNotificationRoute.post(groupID: groupID, postID: postID)
        let opener = GroupNotificationOpener.shared
        if opener.isAttached {
            Task { await opener.open(route) }
        } else {
            appModel.openGroupNotificationRoute(route)
        }
    }
}
