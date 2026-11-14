import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import PilgrimAPI
import SwiftUI
import UniformTypeIdentifiers

/// Square crop for group stickers: a square of the shorter side, slid along the longer side by
/// `position` (0 = top/left, 0.5 = centre, 1 = bottom/right), scaled to 256 × 256 and encoded
/// as JPEG. The preparer (A1's `ImageCompressor`, sticker mode) then enforces the 100 KB cap.
enum GroupStickerCropper {
    static let side = PhotoLimits.stickerSide

    /// The crop rectangle in an upright image of `width` × `height`.
    static func cropRect(width: Int, height: Int, position: Double) -> CGRect {
        let edge = min(width, height)
        let clamped = min(max(position, 0), 1)
        let slack = Double(max(width, height) - edge)
        let offset = (slack * clamped).rounded()
        if width >= height {
            return CGRect(x: offset, y: 0, width: Double(edge), height: Double(edge))
        }
        return CGRect(x: 0, y: offset, width: Double(edge), height: Double(edge))
    }

    static func squareImage(from data: Data, position: Double = 0.5) -> CGImage? {
        guard let upright = GroupImageMetrics.cgImage(from: data, maxPixelSize: 1_024) else {
            return nil
        }
        let rect = cropRect(width: upright.width, height: upright.height, position: position)
        guard let cropped = upright.cropping(to: rect),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// 256 × 256 JPEG, no metadata.
    static func squareJPEG(from data: Data, position: Double = 0.5, quality: Double = 0.8)
        -> Data?
    {
        guard let image = squareImage(from: data, position: position) else { return nil }
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

/// Makes a group sticker from a photo: pick, slide the square crop, name it (optional), create.
struct GroupStickerCreateSheet: View {
    @ObservedObject var model: GroupPostDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var photo: Data?
    @State private var position = 0.5
    @State private var name = ""
    @State private var isLoadingPhoto = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let hasPhoto = photo != nil
                    PhotosPicker(selection: $selection, matching: .images) {
                        if !hasPhoto {
                            Label("사진 고르기", systemImage: "photo.on.rectangle")
                        } else {
                            Label("다른 사진 고르기", systemImage: "photo.on.rectangle")
                        }
                    }
                    if isLoadingPhoto {
                        ProgressView()
                    }
                    if let preview {
                        HStack {
                            Spacer()
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .frame(width: 160, height: 160)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: JournalTheme.Radius.medium))
                            Spacer()
                        }
                        if canSlide {
                            Slider(value: $position, in: 0...1) {
                                Text("자르는 위치")
                            }
                        }
                    }
                } footer: {
                    Text("정사각형으로 잘라 256×256 스티커로 만들어요. 이 그룹 안에서만 쓸 수 있어요.")
                }
                Section {
                    TextField("이름 (선택)", text: $name)
                } footer: {
                    Text("\(name.count)/\(APILimits.stickerNameMax)")
                        .foregroundStyle(
                            name.count > APILimits.stickerNameMax ? Color.red : .secondary)
                }
                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("스티커 만들기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") { Task { await create() } }
                        .disabled(!canCreate)
                }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    private var preview: CGImage? {
        photo.flatMap { GroupStickerCropper.squareImage(from: $0, position: position) }
    }

    private var canSlide: Bool {
        guard let photo, let size = GroupImageMetrics.pixelSize(of: photo) else { return false }
        return size.width != size.height
    }

    private var canCreate: Bool {
        photo != nil && !model.isWorking && name.count <= APILimits.stickerNameMax
            && model.canCreateSticker
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        photo = try? await item.loadTransferable(type: Data.self)
        position = 0.5
    }

    private func create() async {
        guard let photo,
            let jpeg = GroupStickerCropper.squareJPEG(from: photo, position: position)
        else {
            model.notice = String(localized: "이 사진은 올릴 수 없어요")
            return
        }
        if await model.createSticker(jpeg: jpeg, name: name) != nil {
            dismiss()
        }
    }
}
