import AppKit
import ConstellationCore
import SwiftUI

/// An attachment as a square thumbnail: the image itself, or the file's icon and name. Clicking an
/// image zooms it; clicking a file opens it.
struct AttachmentThumbnail: View {
    @Environment(AppModel.self) private var model
    let attachment: Attachment
    var size: CGFloat = 56
    var onRemove: (() -> Void)?
    @State private var image: NSImage?

    var body: some View {
        Button(action: open) {
            content
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.14)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(attachment.name)
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.text)
                        .frame(width: 16, height: 16)
                        .background(Palette.surfaceRaised, in: .circle)
                        .overlay(Circle().strokeBorder(Palette.text.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove \(attachment.name)")
            }
        }
        .task(id: attachment.id) { image = await AttachmentImages.thumbnail(for: attachment) }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else {
            VStack(spacing: 2) {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : attachment.kind == .image ? "photo" : "doc")
                    .font(.system(size: size / 3.5))
                    .foregroundStyle(Palette.textSecondary)
                if size >= 48 {
                    Text(attachment.name)
                        .font(.ui(10))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                }
            }
            .frame(width: size, height: size)
            .background(Palette.surfaceSunken)
        }
    }

    private func open() {
        if attachment.kind == .image {
            model.zoomedAttachment = attachment
        } else {
            NSWorkspace.shared.open(attachment.storedURL)
        }
    }
}

/// A row of attachment thumbnails, e.g. under a message in the transcript.
struct AttachmentRow: View {
    let attachments: [Attachment]
    var size: CGFloat = 72
    var onRemove: ((Attachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, size: size, onRemove: onRemove.map { remove in { remove(attachment) } })
                }
            }
            .padding(.top, onRemove == nil ? 0 : 6)
            .padding(.trailing, onRemove == nil ? 0 : 6)
        }
        .scrollIndicators(.never)
    }
}

/// The zoomed image over the desktop. Click or esc closes it.
struct AttachmentZoom: View {
    @Environment(AppModel.self) private var model
    let attachment: Attachment
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 1400), maxHeight: min(image.size.height, 900))
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.5), radius: 32, y: 24)
            }
            Text(attachment.name).font(.ui(13)).foregroundStyle(Palette.textSecondary)
        }
        .padding(48)
        .contentShape(.rect)
        .onTapGesture { model.zoomedAttachment = nil }
        .task(id: attachment.id) {
            let url = attachment.storedURL
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

/// Thumbnails decoded off the main actor and kept for the life of the app.
enum AttachmentImages {
    @MainActor private static var cache: [UUID: NSImage] = [:]

    @MainActor
    static func thumbnail(for attachment: Attachment) async -> NSImage? {
        guard attachment.kind == .image else { return nil }
        if let cached = cache[attachment.id] { return cached }
        let url = attachment.storedURL
        let image = await Task.detached { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 256,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: thumbnail, size: .zero)
        }.value
        cache[attachment.id] = image
        return image
    }
}
