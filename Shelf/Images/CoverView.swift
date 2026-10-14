import SwiftUI

/// Square artwork tile. Non-square covers are fitted (never cropped) on a tone sampled from the art.
struct CoverView: View {
    let source: ImageSource?
    var title: String = ""
    var cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedKey: String?

    var body: some View {
        GeometryReader { proxy in
            let pixelWidth = Int((proxy.size.width * displayScale).rounded(.up))
            ZStack {
                if let image {
                    let ratio = image.size.width / max(image.size.height, 1)
                    if abs(ratio - 1) < 0.08 {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.15))
                    }
                } else {
                    Placeholder(title: title)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: source.map { "\($0.cacheKey)@\(pixelWidth)" }) {
                await load(pixelWidth: pixelWidth)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func load(pixelWidth: Int) async {
        guard let source, pixelWidth > 0 else { image = nil; loadedKey = nil; return }
        let key = "\(source.cacheKey)@\(pixelWidth)"
        guard loadedKey != key else { return }
        if let hit = ImagePipeline.shared.cachedImage(source, pixelWidth: pixelWidth) {
            image = hit
            loadedKey = key
            return
        }
        // A different cover is coming: don't keep showing the previous one if this one fails.
        if loadedKey?.hasPrefix(source.cacheKey + "@") != true { image = nil }
        if let loaded = await ImagePipeline.shared.image(source, pixelWidth: pixelWidth), !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            loadedKey = key
        }
    }

    private struct Placeholder: View {
        let title: String

        var body: some View {
            ZStack {
                // Opaque base so stacked placeholders don't show through each other.
                Color(.secondarySystemBackground)
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

extension LibraryItem {
    var coverSource: ImageSource { .cover(itemId: id, version: coverVersion) }
}

extension Author {
    var imageSource: ImageSource? {
        imagePath == nil ? nil : .author(authorId: id, version: imageVersion)
    }
}

/// Circular author portrait with initials fallback.
struct AuthorImage: View {
    let author: Author
    var size: CGFloat = 44

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Color.accentColor.opacity(0.18))
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: author.id) {
            image = nil
            guard let source = author.imageSource else { return }
            let width = Int(size * displayScale)
            if let hit = ImagePipeline.shared.cachedImage(source, pixelWidth: width) { image = hit; return }
            image = await ImagePipeline.shared.image(source, pixelWidth: width)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        author.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
