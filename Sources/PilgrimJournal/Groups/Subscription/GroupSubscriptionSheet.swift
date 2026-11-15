import StoreKit
import SwiftUI

/// The group subscription screen (`GroupsSheet.subscription`). Shown only while the server
/// requires a subscription and this user has none (`GroupSubscriptionController` skips it
/// otherwise): the monthly price, 구독하기, 구입 복원, 코드 사용, and the disclosures App Review
/// asks for next to them (guideline 3.1.2). The journal never needs it.
struct GroupSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscription: GroupSubscriptionController

    init(subscription: GroupSubscriptionController = .shared) {
        self.subscription = subscription
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: JournalTheme.Spacing.regular) {
                    content
                }
                .padding(JournalTheme.Spacing.large)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .background(JournalTheme.canvas)
            .navigationTitle("그룹 구독")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task { await subscription.loadScreen() }
        }
        .frame(minWidth: 380, minHeight: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch subscription.state {
        case .notRequired:
            header(
                systemImage: "checkmark.seal.fill", title: String(localized: "구독 없이 쓸 수 있어요"),
                detail: String(localized: "지금은 구독 없이 그룹을 만들고 참여할 수 있어요."))
            continueButton
        case .subscribed(let expiresAt, let inGracePeriod):
            header(
                systemImage: "checkmark.seal.fill", title: String(localized: "구독 중이에요"),
                detail: Self.subscribedDetail(expiresAt: expiresAt, inGracePeriod: inGracePeriod))
            continueButton
            GroupManageSubscriptionButton()
            messageRow
        case .required(let lapse):
            header(
                systemImage: "person.3.fill", title: String(localized: "그룹은 구독자 전용이에요"),
                detail: String(
                    localized: "그룹을 만들거나 참여하려면 월간 구독이 필요해요. 기록장은 구독 없이 그대로 쓸 수 있어요."))
            if let lapse {
                Label(GroupSubscriptionMessages.lapse(lapse), systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupSubscriptionPurchaseControls(subscription: subscription)
        }
    }

    private func header(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: JournalTheme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(JournalTheme.brandPrimary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(JournalTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var continueButton: some View {
        Button {
            subscription.continueAfterSubscription()
        } label: {
            Text(subscription.resumeSheet == nil ? "확인" : "계속")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(JournalTheme.brandPrimary)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var messageRow: some View {
        if let message = subscription.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func subscribedDetail(expiresAt: Date?, inGracePeriod: Bool) -> String {
        if inGracePeriod {
            return String(localized: "결제가 되지 않았어요. App Store에서 결제 정보를 확인해 주세요.")
        }
        guard let expiresAt else { return String(localized: "그룹을 만들고 참여할 수 있어요.") }
        let date = expiresAt.formatted(date: .long, time: .omitted)
        return String(localized: "그룹을 만들고 참여할 수 있어요. 다음 갱신일은 \(date)이에요.")
    }
}

/// Subscribe, restore and redeem-code buttons with the price and the auto-renewal
/// disclosure. Ported from PR #27's `PremiumPurchaseControls`.
private struct GroupSubscriptionPurchaseControls: View {
    @ObservedObject var subscription: GroupSubscriptionController
    @State private var isRedeemingCode = false

    var body: some View {
        VStack(spacing: JournalTheme.Spacing.medium) {
            priceRow
                .offerCodeRedemptionIfAvailable(isPresented: $isRedeemingCode) {
                    // The redeemed subscription also arrives through `Transaction.updates`.
                    Task { await subscription.verifyLatestTransaction() }
                }
            Button {
                Task { await subscription.purchase() }
            } label: {
                Label("구독하기", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(JournalTheme.brandPrimary)
            .disabled(
                subscription.isWorking || subscription.offer == nil || !subscription.canPurchase)
            if subscription.isAwaitingServer {
                Button("다시 확인") {
                    Task { await subscription.verifyLatestTransaction() }
                }
                .disabled(subscription.isWorking)
            }
            Button("구입 복원") {
                Task { await subscription.restore() }
            }
            .disabled(subscription.isWorking || !subscription.canPurchase)
            if GroupOfferCodeRedemption.isAvailable {
                Button("코드 사용") { isRedeemingCode = true }
                    .disabled(subscription.isWorking || !subscription.canPurchase)
            }
            if subscription.isWorking {
                ProgressView().controlSize(.small)
            }
            if let message = subscription.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "구독은 현재 기간이 끝나기 24시간 전까지 해지하지 않으면 자동으로 갱신돼요. 결제는 Apple 계정으로 청구되며, App Store 계정 설정에서 관리하거나 해지할 수 있어요. 구독은 지금 로그인한 그룹 계정에 연결돼요."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: JournalTheme.Spacing.regular) {
                Link("이용약관(EULA)", destination: GroupSubscriptionLinks.termsOfUse)
                Link("개인정보 처리방침", destination: GroupSubscriptionLinks.privacyPolicy)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var priceRow: some View {
        if let offer = subscription.offer {
            VStack(spacing: 2) {
                Text(offer.displayName)
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                Text(offer.priceWithPeriod)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(JournalTheme.ink)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else if subscription.hasLoadedOffer {
            Text("App Store에서 구독 정보를 불러오지 못했어요. 네트워크를 확인하고 다시 열어 주세요.")
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Opens Apple's subscription management, where the plan is changed or cancelled.
private struct GroupManageSubscriptionButton: View {
    #if os(iOS)
    @State private var isPresentingManagement = false
    #else
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        #if os(iOS)
        Button {
            isPresentingManagement = true
        } label: {
            Label("구독 관리", systemImage: "creditcard")
        }
        .manageSubscriptionsSheet(isPresented: $isPresentingManagement)
        #else
        Button {
            openURL(GroupSubscriptionLinks.manageSubscriptions)
        } label: {
            Label("구독 관리", systemImage: "creditcard")
        }
        #endif
    }
}

/// The links next to the purchase button (guideline 3.1.2).
enum GroupSubscriptionLinks {
    /// Apple's standard EULA. If App Store Connect is given a custom EULA, point this at it.
    static let termsOfUse = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Keep equal to the App Store Connect Privacy Policy URL.
    static let privacyPolicy = SupportLinks.supportPage

    /// Where macOS manages App Store subscriptions; iOS uses the system sheet.
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

/// App Store offer codes, redeemed in Apple's own sheet (guideline 3.1.1). macOS gained the
/// sheet in 15.
enum GroupOfferCodeRedemption {
    static var isAvailable: Bool {
        if #available(iOS 16.0, macOS 15.0, *) { true } else { false }
    }
}

extension View {
    @ViewBuilder
    fileprivate func offerCodeRedemptionIfAvailable(
        isPresented: Binding<Bool>, onCompletion: @escaping () -> Void
    ) -> some View {
        if #available(iOS 16.0, macOS 15.0, *) {
            offerCodeRedemption(isPresented: isPresented) { _ in onCompletion() }
        } else {
            self
        }
    }
}
