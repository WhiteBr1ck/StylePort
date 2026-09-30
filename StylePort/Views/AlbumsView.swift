import SwiftUI

struct AlbumsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(PhotoLibraryStore.self) private var library
    @Environment(BatchConversionCoordinator.self) private var conversion

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.albums) { album in
                    albumCard(album)
                        .contextMenu {
                            Button {
                                convert(album)
                            } label: {
                                Label(
                                    text("全部转换", "Convert All"),
                                    systemImage: "wand.and.sparkles"
                                )
                            }
                            .disabled(album.count == 0 || conversion.isRunning)
                        }
                }
            }
            .padding(16)
        }
        .overlay {
            if library.canReadLibrary, library.albums.isEmpty {
                ContentUnavailableView(
                    text("没有可写入的相册", "No Writable Albums"),
                    systemImage: "rectangle.stack",
                    description: Text(text(
                        "在系统“照片”中创建相册后，它会显示在这里。",
                        "Create an album in Apple Photos and it will appear here."
                    ))
                )
            }
        }
        .overlay(alignment: .bottom) {
            if conversion.isRunning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(progressTitle)
                        .font(.footnote.weight(.medium))
                    Spacer()
                }
                .padding(16)
                .background(.bar)
            }
        }
        .navigationTitle(text("相册", "Albums"))
        .task { await library.requestAccessAndLoad() }
        .refreshable { library.reload() }
    }

    private func albumCard(_ album: PhotoAlbum) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryThumbnailView(assetIdentifier: album.coverAssetIdentifier)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.headline)
                .lineLimit(1)
            Text(text("\(album.count) 张", "\(album.count) photos"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(text("长按可转换整个相册", "Touch and hold to convert the entire album"))
    }

    private func convert(_ album: PhotoAlbum) {
        let identifiers = library.photos(in: album.id).map(\.id)
        Task {
            await conversion.convertLibraryPhotos(
                identifiers: identifiers,
                albumIdentifier: album.id,
                replacingOriginal: preferences.replaceOriginal
            )
            library.reload()
        }
    }

    private var progressTitle: String {
        switch conversion.phase {
        case let .preparing(current, total): text("正在读取 \(current)/\(total)", "Loading \(current)/\(total)")
        case let .converting(current, total): text("正在转换 \(current)/\(total)", "Converting \(current)/\(total)")
        case let .saving(current, total): text("正在保存 \(current)/\(total)", "Saving \(current)/\(total)")
        case .idle, .completed: ""
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        preferences.language.text(zh: zh, en: en)
    }
}
