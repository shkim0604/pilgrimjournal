import StoreKit
import SwiftUI

/// Shown instead of "유형 편집" when kind management is locked, and from
/// Settings › 프리미엄. Subscribing, restoring or redeeming an offer code
/// unlocks it on every device signed in to the same Apple ID.
struct PremiumFeatureNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: JournalTheme.Spacing.regular) {
                Image(
                    systemName: model.featureAccess.canManageKinds
                        ? "checkmark.seal.fill" : "lock.fill"
                )
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(JournalTheme.brandPrimary)
                .accessibilityHidden(true)
                if model.featureAccess.canManageKinds {
                    unlockedContent
                } else {
                    lockedContent
                }
            }
            .padding(JournalTheme.Spacing.large)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    @ViewBuilder
    private var lockedContent: some View {
        Text("유료 기능")
            .font(.title2.weight(.semibold))
            .foregroundStyle(JournalTheme.ink)
        Text("유형 추가·삭제·편집은 프리미엄 구독으로 쓸 수 있습니다. 지금 있는 유형으로 기록을 쓰고 옮기는 것은 계속 할 수 있습니다.")
            .multilineTextAlignment(.center)
            .foregroundStyle(JournalTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        PremiumPurchaseControls()
            .multilineTextAlignment(.center)
        Button("닫기") { dismiss() }
            .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var unlockedContent: some View {
        Text("프리미엄을 사용 중입니다")
            .font(.title2.weight(.semibold))
            .foregroundStyle(JournalTheme.ink)
        Text("이제 유형을 추가하고 이름·색·아이콘과 순서를 바꿀 수 있습니다.")
            .multilineTextAlignment(.center)
            .foregroundStyle(JournalTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("유형 편집 열기") { openKindManagement() }
            .buttonStyle(.borderedProminent)
            .tint(JournalTheme.brandPrimary)
            .keyboardShortcut(.defaultAction)
        Button("닫기") { dismiss() }
    }

    /// One sheet replaces another, so wait for this one to finish closing.
    private func openKindManagement() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.openKindManagement()
        }
    }
}

/// Subscribe, restore and redeem-code buttons with the price and the
/// disclosures App Review requires next to them (guideline 3.1.2). Each child
/// is its own view, so inside a `Form` section every one becomes a row.
struct PremiumPurchaseControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var isWorking = false
    @State private var hasRequestedOffer = false
    @State private var isRedeemingCode = false
    @State private var message: String?

    var body: some View {
        priceRow
            .task {
                if model.featureAccess.premiumOffer == nil {
                    await model.featureAccess.refresh()
                }
                hasRequestedOffer = true
            }
            .offerCodeRedemptionIfAvailable(isPresented: $isRedeemingCode) {
                Task { await refreshAfterOfferCode() }
            }
        Button(action: purchase) {
            Label("구독하기", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(JournalTheme.brandPrimary)
        .disabled(isWorking || model.featureAccess.premiumOffer == nil)
        Button("구입 복원", action: restore)
            .disabled(isWorking)
        if OfferCodeRedemption.isAvailable {
            Button("코드 사용") { isRedeemingCode = true }
                .disabled(isWorking)
        }
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(
            "구독은 현재 기간이 끝나기 24시간 전까지 해지하지 않으면 자동으로 갱신됩니다. 결제는 Apple 계정으로 청구되며, App Store 계정 설정에서 관리하거나 해지할 수 있습니다. 같은 Apple 계정을 쓰는 모든 기기에 적용됩니다."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: JournalTheme.Spacing.regular) {
            Link("이용약관(EULA)", destination: SupportLinks.termsOfUse)
            Link("개인정보 처리방침", destination: SupportLinks.privacyPolicy)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var priceRow: some View {
        if let offer = model.featureAccess.premiumOffer {
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
        } else if hasRequestedOffer {
            Text("App Store에서 구독 정보를 불러오지 못했습니다. 네트워크를 확인하고 다시 열어 주세요.")
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func purchase() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            let outcome = await model.featureAccess.purchasePremium()
            isWorking = false
            model.featureAccessDidChange()
            switch outcome {
            case .purchased, .cancelled:
                message = nil
            case .pending:
                message = String(localized: "구입 승인을 기다리고 있습니다. 승인되면 자동으로 열립니다.")
            case .unavailable:
                message = Self.storeUnavailableMessage
            case .failed(let reason):
                message = String(localized: "구입하지 못했습니다: \(reason)")
            }
        }
    }

    private func restore() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            let outcome = await model.featureAccess.restorePurchases()
            isWorking = false
            model.featureAccessDidChange()
            switch outcome {
            case .restored:
                message = String(localized: "구입을 복원했습니다.")
            case .nothingToRestore:
                message = String(localized: "이 Apple 계정에서 복원할 구독이 없습니다.")
            case .cancelled:
                message = nil
            case .unavailable:
                message = Self.storeUnavailableMessage
            case .failed(let reason):
                message = String(localized: "구입을 복원하지 못했습니다: \(reason)")
            }
        }
    }

    /// The redeemed subscription also arrives through `Transaction.updates`;
    /// this just makes the sheet react without waiting for it.
    private func refreshAfterOfferCode() async {
        await model.featureAccess.refresh()
        model.featureAccessDidChange()
    }

    private static var storeUnavailableMessage: String {
        String(localized: "지금은 App Store에 연결할 수 없습니다. 잠시 후 다시 시도하세요.")
    }
}

/// Settings › 프리미엄 while subscribed: opens Apple's subscription
/// management, where the user changes or cancels the plan.
struct ManageSubscriptionButton: View {
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
            openURL(SupportLinks.manageSubscriptions)
        } label: {
            Label("구독 관리", systemImage: "creditcard")
        }
        #endif
    }
}

/// App Store offer codes: Apple's own redemption sheet, so codes stay within
/// in-app purchase (guideline 3.1.1). macOS gained the sheet in 15.
enum OfferCodeRedemption {
    static var isAvailable: Bool {
        if #available(iOS 16.0, macOS 15.0, *) { true } else { false }
    }
}

extension View {
    @ViewBuilder
    fileprivate func offerCodeRedemptionIfAvailable(
        isPresented: Binding<Bool>,
        onCompletion: @escaping () -> Void
    ) -> some View {
        if #available(iOS 16.0, macOS 15.0, *) {
            offerCodeRedemption(isPresented: isPresented) { _ in onCompletion() }
        } else {
            self
        }
    }
}
