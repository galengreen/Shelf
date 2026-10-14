import SwiftUI

/// Bookmarks section on a book's page. Shows nothing if the book has none.
struct BookmarkList: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let bookmarks = model.bookmarks.bookmarks(for: item.id)
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: bookmarks.count == 1 ? "1 Bookmark" : "\(bookmarks.count) Bookmarks")
                VStack(spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, item: item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Bookmarks in the player's list panel, on the dark tinted background.
struct PlayerBookmarkList: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let bookmarks = model.bookmarks.bookmarks(for: item.id)
        if bookmarks.isEmpty {
            ContentUnavailableView {
                Label("No Bookmarks", systemImage: "bookmark")
            } description: {
                Text("Tap the bookmark button to mark a moment you want to come back to.")
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark, item: item, onDark: true)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark
    let item: LibraryItem
    var onDark = false

    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        Button {
            if model.player.item?.id == item.id && model.player.episode == nil {
                model.player.jump(to: bookmark.time)
            } else {
                model.player.open(item, at: bookmark.time)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(bookmark.title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.clock(bookmark.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(onDark ? .white.opacity(0.5) : .secondary)
            }
            .foregroundStyle(onDark ? .white : .primary)
            .padding(.vertical, 13)
            .contentShape(.rect)
            .overlay(alignment: .bottom) {
                Rectangle().fill(onDark ? .white.opacity(0.08) : Color.primary.opacity(0.07)).frame(height: 0.5)
                    .padding(.leading, 36)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newTitle = bookmark.title
                renaming = true
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.bookmarks.delete(bookmark, api: model.api) }
            }
        }
        .accessibilityLabel("\(bookmark.title), at \(Format.clock(bookmark.time))")
        .accessibilityHint("Plays from this bookmark")
        .accessibilityAction(named: "Rename") { newTitle = bookmark.title; renaming = true }
        .accessibilityAction(named: "Delete") { Task { await model.bookmarks.delete(bookmark, api: model.api) } }
        .alert("Rename Bookmark", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, title != bookmark.title else { return }
                Task { await model.bookmarks.rename(bookmark, to: title, api: model.api) }
            }
        }
    }
}
