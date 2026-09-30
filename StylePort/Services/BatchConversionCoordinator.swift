import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class BatchConversionCoordinator {
    private(set) var phase: BatchConversionPhase = .idle
    var report: ConversionReport?

    var isRunning: Bool {
        switch phase {
        case .preparing, .converting, .saving: true
        case .idle, .completed: false
        }
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        report = nil
    }

    func convertImportedPhotos(
        _ photos: [SelectedPhoto],
        replacingOriginal: Bool,
        skippedDuringImport: Int = 0,
        importFailures: [String] = []
    ) async {
        guard !isRunning, !photos.isEmpty || skippedDuringImport > 0 || !importFailures.isEmpty else { return }
        var succeeded = 0
        var skipped = skippedDuringImport
        var messages = importFailures
        let total = photos.count + skippedDuringImport + importFailures.count

        for (offset, photo) in photos.enumerated() {
            do {
                phase = .preparing(current: offset + 1, total: total)
                let eligibility = try await PhotoConversionService.eligibility(of: photo.sourceURL)
                guard eligibility == .convertible else {
                    skipped += 1
                    continue
                }
                phase = .converting(current: offset + 1, total: total)
                let output = try await PhotoConversionService().convert(
                    sourceURL: photo.sourceURL,
                    originalFilename: photo.fileName
                )
                phase = .saving(current: offset + 1, total: total)
                _ = try await PhotoLibraryWriter.save(
                    outputURL: output,
                    replacingOriginal: replacingOriginal,
                    assetIdentifier: photo.assetIdentifier
                )
                succeeded += 1
            } catch {
                messages.append("\(photo.fileName): \(error.localizedDescription)")
            }
        }
        let summary = BatchConversionSummary(
            total: total,
            succeeded: succeeded,
            skipped: skipped,
            failed: messages.count,
            failureMessages: messages
        )
        phase = .completed(summary)
        report = ConversionReport(summary: summary)
        UINotificationFeedbackGenerator().notificationOccurred(messages.isEmpty ? .success : .warning)
    }

    func convertLibraryPhotos(
        identifiers: [String],
        albumIdentifier: String? = nil,
        replacingOriginal: Bool
    ) async {
        guard !isRunning, !identifiers.isEmpty else { return }
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        let total = identifiers.count

        for (offset, identifier) in identifiers.enumerated() {
            if Task.isCancelled { break }
            do {
                phase = .preparing(current: offset + 1, total: total)
                let source = try await PhotoAssetSource.load(identifier: identifier)
                let eligibility = try await PhotoConversionService.eligibility(of: source.url)
                guard eligibility == .convertible else {
                    skipped += 1
                    continue
                }

                phase = .converting(current: offset + 1, total: total)
                let output = try await PhotoConversionService().convert(
                    sourceURL: source.url,
                    originalFilename: source.originalFilename
                )
                phase = .saving(current: offset + 1, total: total)
                _ = try await PhotoLibraryWriter.save(
                    outputURL: output,
                    outputFilename: output.lastPathComponent,
                    replacingOriginal: replacingOriginal,
                    assetIdentifier: source.assetIdentifier,
                    albumIdentifier: albumIdentifier
                )
                succeeded += 1
            } catch {
                failed += 1
                messages.append(error.localizedDescription)
            }
        }

        let summary = BatchConversionSummary(
            total: total,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed,
            failureMessages: messages
        )
        phase = .completed(summary)
        report = ConversionReport(summary: summary)
        UINotificationFeedbackGenerator().notificationOccurred(failed == 0 ? .success : .warning)
    }
}
