import AuthenticationServices
import Foundation
import ImageIO
import JournalGroups
import PhotosUI
import PilgrimAPI
import SwiftUI
import UniformTypeIdentifiers

/// "그룹 시작하기": Apple re-authentication for the group server, then the sign-up screen
/// (terms, display name, optional profile photo). Which step shows follows
/// `GroupsController.accountState`, so reopening the sheet after a half-finished sign-up lands
/// on the sign-up screen. Notification permission is asked later, on the first create or join
/// (A7).
struct GroupOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groups: GroupsController

    var body: some View {
        NavigationStack {
            Group {
                switch groups.accountState {
                case .needsProfile:
                    GroupSignUpForm(groups: groups)
                case .upgradeRequired:
                    GroupUpgradeNotice()
                default:
                    GroupSignInStep(groups: groups)
                }
            }
            .navigationTitle("그룹 시작하기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

/// Step 1: what groups are and the Apple re-authentication.
private struct GroupSignInStep: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var groups: GroupsController

    var body: some View {
        ScrollView {
            VStack(spacing: JournalTheme.Spacing.large) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(JournalTheme.brandPrimary)
                    .padding(.top, JournalTheme.Spacing.xLarge)
                    .accessibilityHidden(true)

                VStack(spacing: JournalTheme.Spacing.small) {
                    Text("함께 기도하는 작은 모임")
                        .font(.title2.bold())
                        .foregroundStyle(JournalTheme.ink)
                    Text("초대받은 사람끼리만 기도제목, 독후감, 간증을 나눠요. 올린 글은 정해진 기간이 지나면 사라져요.")
                        .font(.callout)
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 440)

                VStack(alignment: .leading, spacing: JournalTheme.Spacing.medium) {
                    Label("기록장은 그대로 내 기기와 iCloud에만 있어요.", systemImage: "lock.shield")
                    Label("직접 올린 글만 그룹 서버에 저장돼요.", systemImage: "paperplane")
                    Label("기록장에 로그인한 Apple 계정으로 한 번 더 인증해요.", systemImage: "person.badge.key")
                }
                .font(.callout)
                .foregroundStyle(JournalTheme.inkSecondary)
                .padding(JournalTheme.Spacing.regular)
                .frame(maxWidth: 440, alignment: .leading)
                .background(
                    JournalTheme.surfaceMuted,
                    in: RoundedRectangle(
                        cornerRadius: JournalTheme.Radius.medium, style: .continuous)
                )

                if groups.usesDevelopmentSignIn {
                    Button("개발용 계정으로 시작하기") {
                        Task { await groups.signInWithApple() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(groups.isSigningIn)
                } else {
                    SignInWithAppleButton(.continue) { request in
                        groups.prepareAppleButtonRequest(request)
                    } onCompletion: { result in
                        Task { await groups.finishAppleButtonSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 280, height: 48)
                    .disabled(groups.isSigningIn)
                    .accessibilityHint("그룹 서버에 로그인하기 위해 Apple 계정으로 다시 인증합니다.")
                }

                if groups.isSigningIn {
                    ProgressView()
                }

                if let message = groups.signInMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
            }
            .padding(JournalTheme.Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .background(JournalTheme.canvas)
    }
}

/// Step 2: the sign-up screen. Only a name and an optional photo are asked for.
private struct GroupSignUpForm: View {
    @ObservedObject var groups: GroupsController
    @State private var displayName = ""
    @State private var acceptsTerms = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: PreparedGroupPhoto?
    @State private var isPreparingPhoto = false
    @State private var isSaving = false
    @State private var message: String?

    private var canSave: Bool {
        acceptsTerms && GroupNameRules.isValidDisplayName(displayName) && !isSaving
            && !isPreparingPhoto
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: JournalTheme.Spacing.regular) {
                    GroupProfilePhotoPreview(photo: photo)
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(photo == nil ? "프로필 사진 고르기" : "다른 사진 고르기", systemImage: "photo")
                        }
                        if photo != nil {
                            Button("사진 빼기", role: .destructive) {
                                pickerItem = nil
                                photo = nil
                            }
                        }
                        if isPreparingPhoto {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("프로필 사진 (선택)")
            } footer: {
                Text("사진은 이 기기에서 줄이고 위치 같은 정보를 지운 뒤 올려요.")
            }

            Section {
                TextField("그룹에서 보일 이름", text: $displayName)
                    .onSubmit(save)
                Text(
                    "\(GroupNameRules.normalized(displayName).count)/\(APILimits.displayName.upperBound)"
                )
                .font(.caption)
                .foregroundStyle(
                    GroupNameRules.normalized(displayName).count > APILimits.displayName.upperBound
                        ? .red : JournalTheme.inkSecondary)
            } header: {
                Text("이름")
            } footer: {
                Text("그룹 멤버에게 보이는 이름이에요. 1~30자로 정해 주세요.")
            }

            Section {
                Toggle("이용 안내와 개인정보 처리 방침에 동의해요", isOn: $acceptsTerms)
                Link("이용 안내 보기", destination: SupportLinks.supportPage)
            } footer: {
                Text("그룹 서버에는 이 이름과 프로필 사진, 직접 올린 글만 저장돼요.")
            }

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("시작하기").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSave)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .onAppear {
            if displayName.isEmpty, let name = groups.me?.displayName { displayName = name }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw GroupProfilePhotoError.unreadable
            }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try GroupProfilePhotoPreparer.prepare(data)
            }.value
            photo = prepared
            message = nil
        } catch {
            message = String(localized: "이 사진은 쓸 수 없어요. 다른 사진을 골라 주세요.")
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await groups.completeProfile(displayName: displayName, photo: photo)
                message = nil
            } catch {
                // The name, photo and consent stay as typed for the retry.
                message = GroupMessages.text(for: GroupsController.normalize(error))
            }
        }
    }
}

private struct GroupProfilePhotoPreview: View {
    let photo: PreparedGroupPhoto?

    var body: some View {
        ZStack {
            Circle().fill(JournalTheme.surfaceMuted)
            if let image = photo?.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }
}

/// Shown instead of every group screen after a 426.
struct GroupUpgradeNotice: View {
    var body: some View {
        JournalEmptyState(
            title: String(localized: "앱 업데이트가 필요해요"),
            description: GroupMessages.upgradeRequired,
            systemImage: "arrow.down.app"
        ) {
            Link("App Store 열기", destination: GroupsAppStoreLink.url)
                .buttonStyle(.borderedProminent)
        }
        .background(JournalTheme.canvas)
    }
}

// MARK: - Profile photo

/// A profile photo ready to upload: a JPEG within `PhotoLimits` and its size. `clientID` stays
/// with the photo, so retrying a failed sign-up reuses the upload instead of making another.
struct PreparedGroupPhoto: Equatable, @unchecked Sendable {
    let clientID: UUID
    let jpegData: Data
    let width: Int
    let height: Int
    let previewImage: CGImage?

    static func == (lhs: PreparedGroupPhoto, rhs: PreparedGroupPhoto) -> Bool {
        lhs.clientID == rhs.clientID && lhs.jpegData == rhs.jpegData
    }
}

enum GroupProfilePhotoError: Error, Equatable {
    case unreadable
    case tooLarge
}

/// Shrinks a picked photo for the group server: long edge at most 1600 px with the
/// orientation applied, JPEG from quality 0.7 down to 0.3, then smaller, until it is at most
/// 500 KB. The JPEG is written from pixels only, so EXIF, GPS and other metadata are gone.
///
/// Phase 2 replaces this with A1's `ImageCompressor` (same `PhotoLimits` ladder) once it lands.
enum GroupProfilePhotoPreparer {
    static func prepare(_ data: Data, clientID: UUID = UUID()) throws -> PreparedGroupPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw GroupProfilePhotoError.unreadable
        }
        var longEdge = PhotoLimits.maxLongEdge
        for _ in 0..<8 {
            guard let image = thumbnail(source, maxPixelSize: longEdge) else {
                throw GroupProfilePhotoError.unreadable
            }
            var quality = PhotoLimits.Compression.initialQuality
            while quality >= PhotoLimits.Compression.minimumQuality - 0.001 {
                if let jpeg = encodeJPEG(image, quality: quality),
                    jpeg.count <= PhotoLimits.maxPhotoBytes
                {
                    return PreparedGroupPhoto(
                        clientID: clientID, jpegData: jpeg, width: image.width,
                        height: image.height, previewImage: image)
                }
                quality -= PhotoLimits.Compression.qualityStep
            }
            longEdge = Int(
                Double(max(image.width, image.height)) * PhotoLimits.Compression.downscaleFactor)
            guard longEdge >= 64 else { break }
        }
        throw GroupProfilePhotoError.tooLarge
    }

    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
