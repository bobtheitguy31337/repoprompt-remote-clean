import CoreTransferable
import ImageIO
import PhotosUI
import RepoPromptRemoteProtocol
import SwiftUI
import UniformTypeIdentifiers

struct RemoteDraftAttachment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let bytes: Data
    let thumbnail: Data?

    static func read(_ url: URL, name: String? = nil) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw RemoteAttachmentPickerError.notAFile
        }
        guard size <= RemoteAttachmentLimits.maxFileBytes else {
            throw RemoteAttachmentPickerError.tooLarge(url.lastPathComponent)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            guard bytes.count + chunk.count <= RemoteAttachmentLimits.maxFileBytes else {
                throw RemoteAttachmentPickerError.tooLarge(url.lastPathComponent)
            }
            bytes.append(chunk)
        }
        return Self(name: name ?? url.lastPathComponent, bytes: bytes, thumbnail: imageThumbnail(bytes))
    }

    private static func imageThumbnail(_ data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

private struct RemotePickedPhoto: Transferable {
    let attachment: RemoteDraftAttachment

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let ext = file.file.pathExtension
            let name = ext.isEmpty ? "Photo" : "Photo.\(ext)"
            return Self(attachment: try RemoteDraftAttachment.read(file.file, name: name))
        }
    }
}

private enum RemoteAttachmentPickerError: LocalizedError {
    case notAFile
    case tooLarge(String)
    case tooMany
    case totalLimit
    case unavailablePhoto

    var errorDescription: String? {
        switch self {
        case .notAFile: "Select a regular file."
        case let .tooLarge(name): "\(name) exceeds the 20 MB limit."
        case .tooMany: "Attach up to 10 files per message."
        case .totalLimit: "Attachments exceed the 50 MB limit for one message."
        case .unavailablePhoto: "Photos could not provide this image."
        }
    }
}

@MainActor
final class RemoteAttachmentDraft: ObservableObject {
    @Published private(set) var files: [RemoteDraftAttachment] = []
    @Published private(set) var isLoading = false

    func remove(_ id: UUID) { files.removeAll { $0.id == id } }
    func clear() { files.removeAll() }

    func load<Selection>(
        _ selections: [Selection],
        read: (Selection) async throws -> RemoteDraftAttachment,
        onError: (String) -> Void
    ) async {
        guard !isLoading, !selections.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var firstError: Error?
        for selection in selections {
            guard !Task.isCancelled else { return }
            guard files.count < RemoteAttachmentLimits.maxCount else {
                firstError = firstError ?? RemoteAttachmentPickerError.tooMany
                break
            }
            do {
                let attachment = try await read(selection)
                try Task.checkCancellation()
                guard files.reduce(attachment.bytes.count, { $0 + $1.bytes.count }) <= RemoteAttachmentLimits.maxTotalBytes else {
                    throw RemoteAttachmentPickerError.totalLimit
                }
                files.append(attachment)
            } catch is CancellationError {
                return
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { onError(firstError.localizedDescription) }
    }
}

struct RemoteAttachmentPicker: View {
    @ObservedObject var draft: RemoteAttachmentDraft
    let buttonHeight: CGFloat
    let isEnabled: Bool
    let onError: (String) -> Void

    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { showsPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { showsFiles = true } label: { Label("Browse Files", systemImage: "folder") }
        } label: {
            Group {
                if draft.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                }
            }
            .frame(width: buttonHeight, height: buttonHeight)
            .foregroundStyle(Color.remoteWarmOrange)
            .background(Color.remoteWarmOrange.opacity(0.12), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || draft.isLoading || draft.files.count >= RemoteAttachmentLimits.maxCount)
        .accessibilityLabel(draft.isLoading ? "Loading attachments" : "Attach files or photos")
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                Task {
                    await draft.load(urls, read: { url in
                        try await Task.detached(priority: .userInitiated) { try RemoteDraftAttachment.read(url) }.value
                    }, onError: onError)
                }
            case let .failure(error):
                onError(error.localizedDescription)
            }
        }
        .photosPicker(
            isPresented: $showsPhotos,
            selection: $photos,
            maxSelectionCount: max(1, RemoteAttachmentLimits.maxCount - draft.files.count),
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                await draft.load(items, read: { item in
                    guard let photo = try await item.loadTransferable(type: RemotePickedPhoto.self) else {
                        throw RemoteAttachmentPickerError.unavailablePhoto
                    }
                    return photo.attachment
                }, onError: onError)
            }
        }
    }
}

struct RemoteAttachmentDraftStrip: View {
    @ObservedObject var draft: RemoteAttachmentDraft
    let isSending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSending {
                ProgressView("Sending attachments…")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(draft.files) { file in
                        HStack(spacing: 7) {
                            if let data = file.thumbnail, let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 32, height: 32).clipped()
                                    .clipShape(.rect(cornerRadius: 5))
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "doc")
                            }
                            Text(file.name).lineLimit(1).frame(maxWidth: 125)
                            Button { draft.remove(file.id) } label: {
                                Image(systemName: "xmark.circle.fill").frame(width: 30, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(file.name)")
                        }
                        .font(.caption)
                        .padding(.leading, 8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(isSending)
        }
    }
}
