import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Turns a `MediaRef` into a loadable URL. Signed URLs last 10 minutes; once one has expired
/// the resolver asks `GET /media/:id` for a fresh one.
struct GroupMediaURLResolver: Sendable {
    var resolve: @Sendable (MediaRef) async -> URL

    /// Uses the URL in the response as is.
    static let direct = GroupMediaURLResolver { $0.url }

    static func refreshing(
        with api: any GroupAPI, now: @escaping @Sendable () -> Date = { Date() }
    ) -> GroupMediaURLResolver {
        GroupMediaURLResolver { media in
            guard media.urlExpiresAt <= now() else { return media.url }
            return (try? await api.mediaURL(id: media.id).url) ?? media.url
        }
    }
}

private struct GroupMediaURLResolverKey: EnvironmentKey {
    static let defaultValue = GroupMediaURLResolver.direct
}

extension EnvironmentValues {
    var groupMediaURLResolver: GroupMediaURLResolver {
        get { self[GroupMediaURLResolverKey.self] }
        set { self[GroupMediaURLResolverKey.self] = newValue }
    }
}

/// One server photo, filling its frame.
struct GroupMediaImage: View {
    let media: MediaRef
    var contentMode: ContentMode = .fill
    @Environment(\.groupMediaURLResolver) private var resolver
    @State private var url: URL?

    var body: some View {
        ZStack {
            JournalTheme.surfaceMuted
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(JournalTheme.inkSecondary)
                    default:
                        ProgressView()
                    }
                }
            }
        }
        .task(id: media.id) { url = await resolver.resolve(media) }
        .accessibilityLabel(Text("사진"))
    }
}

/// Up to four post or comment photos: one large, or a two-column grid.
struct GroupPhotoGrid: View {
    let media: [MediaRef]
    var maxHeight: CGFloat = 220
    var onOpen: ((Int) -> Void)?

    var body: some View {
        if media.isEmpty {
            EmptyView()
        } else if media.count == 1 {
            tile(0).frame(height: maxHeight)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
                spacing: 4
            ) {
                ForEach(media.indices, id: \.self) { index in
                    tile(index).frame(height: media.count == 2 ? maxHeight : maxHeight / 2)
                }
            }
        }
    }

    private func tile(_ index: Int) -> some View {
        Button {
            onOpen?(index)
        } label: {
            GroupMediaImage(media: media[index])
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: JournalTheme.Radius.small))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityLabel(Text("사진 \(index + 1)/\(media.count)"))
    }
}

/// Full-screen photo viewer for a post's photos.
struct GroupPhotoViewer: View {
    let media: [MediaRef]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .background(Color.black)
                .navigationTitle(Text("\(index + 1)/\(media.count)"))
                #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        TabView(selection: $index) {
            ForEach(media.indices, id: \.self) { index in
                GroupMediaImage(media: media[index], contentMode: .fit)
                    .tag(index)
            }
        }
        .tabViewStyle(.page)
        #else
        VStack {
            if media.indices.contains(index) {
                GroupMediaImage(media: media[index], contentMode: .fit)
            }
            HStack {
                Button {
                    index = max(0, index - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                .accessibilityLabel(Text("이전 사진"))
                Spacer()
                Button {
                    index = min(media.count - 1, index + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index >= media.count - 1)
                .accessibilityLabel(Text("다음 사진"))
            }
            .padding()
        }
        #endif
    }
}

/// Photos picked on this device, before they are uploaded.
struct GroupLocalPhotoStrip: View {
    let photos: [GroupComposerPhoto]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JournalTheme.Spacing.small) {
                ForEach(photos) { photo in
                    ZStack(alignment: .topTrailing) {
                        GroupLocalImage(data: photo.data)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: JournalTheme.Radius.small))
                        Button {
                            onRemove(photo.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .accessibilityLabel(Text("사진 빼기"))
                    }
                }
            }
        }
    }
}

/// A local image from encoded data (JPEG, HEIC, PNG…).
struct GroupLocalImage: View {
    let data: Data

    var body: some View {
        ZStack {
            JournalTheme.surfaceMuted
            if let image = GroupImageMetrics.image(from: data) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(JournalTheme.inkSecondary)
            }
        }
        .clipped()
        .accessibilityLabel(Text("사진"))
    }
}
