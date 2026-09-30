import PhotosUI
import SwiftUI

struct PhotosView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(BatchConversionCoordinator.self) private var conversion
    @Environment(PhotoImportSession.self) private var imports
    private var photos: [SelectedPhoto] { imports.photos }
    private var loadingProgress: (current: Int, total: Int)? { imports.loadingProgress }

    var body: some View {
        Group {
            if !imports.hasSelection {
                VStack(spacing: 20) {
                    importer {
                        Image(systemName: "plus")
                            .font(.system(size: 38, weight: .regular))
                            .frame(width: 92, height: 92)
                    }
                    .stylePortPrimaryButton()
                    if let loadingProgress {
                        ProgressView(importTitle(loadingProgress))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(photos) { photo in
                            GeometryReader { geometry in
                                Image(uiImage: photo.preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                                    .clipShape(.rect(cornerRadius: 12))
                                    .accessibilityLabel(photo.fileName)
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(text("转换", "Convert"))
        .toolbar {
            if imports.hasSelection {
                ToolbarItem(placement: .topBarLeading) {
                    Button(text("清空", "Clear")) { imports.clear() }
                        .disabled(conversion.isRunning || loadingProgress != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    importer { Image(systemName: "plus") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if imports.hasSelection { conversionBar }
        }
    }

    private func importer<Label: View>(@ViewBuilder label: @Sendable () -> Label) -> some View {
        @Bindable var imports = imports
        return PhotosPicker(
            selection: $imports.pickerItems,
            maxSelectionCount: 50,
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: .shared(),
            label: label
        )
        .accessibilityLabel(text("导入照片", "Import Photos"))
        .disabled(loadingProgress != nil || conversion.isRunning)
    }

    private var conversionBar: some View {
        VStack(spacing: 10) {
            if conversion.isRunning {
                ProgressView(progressTitle)
            } else if let loadingProgress {
                ProgressView(importTitle(loadingProgress))
            }
            Button {
                Task {
                    await conversion.convertImportedPhotos(
                        photos,
                        replacingOriginal: preferences.replaceOriginal,
                        skippedDuringImport: imports.skipped,
                        importFailures: imports.failures
                    )
                    imports.clear()
                }
            } label: {
                Text(text("转换", "Convert"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .stylePortPrimaryButton()
            .accessibilityIdentifier("conversion.convert")
            .disabled(conversion.isRunning || loadingProgress != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func importTitle(_ progress: (current: Int, total: Int)) -> String {
        text("正在导入 \(progress.current)/\(progress.total)", "Importing \(progress.current)/\(progress.total)")
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

struct BatchResultView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppPreferences.self) private var preferences
    let summary: BatchConversionSummary

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(text("总计", "Total"), value: "\(summary.total)")
                resultRow(text("成功", "Succeeded"), count: summary.succeeded, symbol: "checkmark.circle.fill", color: .green)
                resultRow(text("失败", "Failed"), count: summary.failed, symbol: "xmark.circle.fill", color: .red)
                resultRow(text("跳过", "Skipped"), count: summary.skipped, symbol: "arrow.forward.circle.fill", color: .orange)
                if !summary.failureMessages.isEmpty {
                    Section(text("错误详情", "Error Details")) {
                        ForEach(Array(summary.failureMessages.enumerated()), id: \.offset) { _, message in Text(message) }
                    }
                }
            }
            .navigationTitle(text("转换完成", "Conversion Complete"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("完成", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func resultRow(_ title: String, count: Int, symbol: String, color: Color) -> some View {
        LabeledContent {
            Text("\(count)").fontWeight(.semibold).foregroundStyle(color)
        } label: {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        preferences.language.text(zh: zh, en: en)
    }
}
