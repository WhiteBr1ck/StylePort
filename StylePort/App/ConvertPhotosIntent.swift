import AppIntents
import Foundation

struct ConvertPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "用过片转换照片"
    static let description = IntentDescription("直接转换输入的照片，自动保存副本并返回成功、失败和跳过的数量。")
    static let openAppWhenRun = false

    @Parameter(title: "照片", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var photos: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        Summary("用过片转换 \(\.$photos)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let photos, !photos.isEmpty else {
            let message = "没有收到照片，未进行转换。"
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
        let summary = await Self.convertFiles(photos)
        let message = "处理 \(summary.total) 张：成功 \(summary.succeeded) 张，失败 \(summary.failed) 张，跳过 \(summary.skipped) 张。"
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }

    static func convertFiles(_ files: [IntentFile]) async -> BatchConversionSummary {
        var inputs: [ExternalPhotoInput] = []
        var failures: [String] = []
        for file in files {
            do {
                inputs.append(try copyToTemporaryFile(file))
            } catch {
                failures.append("\(file.filename): \(error.localizedDescription)")
            }
        }
        let converted = await ExternalPhotoConversion.convert(inputs)
        return BatchConversionSummary(total: files.count, succeeded: converted.succeeded, skipped: converted.skipped,
                                      failed: converted.failed + failures.count, failureMessages: converted.failureMessages + failures)
    }

    private static func copyToTemporaryFile(_ file: IntentFile) throws -> ExternalPhotoInput {
        let safeName = URL(fileURLWithPath: file.filename).lastPathComponent
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuoPian-Shortcuts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(safeName.isEmpty ? "Photo.HEIC" : safeName)
        if let source = file.fileURL {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try file.data.write(to: destination, options: .atomic)
        }
        return ExternalPhotoInput(url: destination, originalFilename: destination.lastPathComponent)
    }
}

struct GuoPianShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertPhotosIntent(),
                    phrases: ["用 \(.applicationName) 转换照片", "Convert photos with \(.applicationName)"],
                    shortTitle: "转换照片", systemImageName: "camera.filters")
    }
}
