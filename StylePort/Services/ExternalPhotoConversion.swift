import Foundation

nonisolated enum ExternalPhotoConversion {
    static func convert(_ inputs: [ExternalPhotoInput]) async -> BatchConversionSummary {
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []

        for input in inputs {
            do {
                let eligibility = try await PhotoConversionService.eligibility(of: input.url)
                guard eligibility == .convertible else {
                    skipped += 1
                    continue
                }
                let output = try await PhotoConversionService().convert(
                    sourceURL: input.url,
                    originalFilename: input.originalFilename
                )
                _ = try await PhotoLibraryWriter.save(
                    outputURL: output,
                    outputFilename: output.lastPathComponent,
                    replacingOriginal: false,
                    assetIdentifier: nil
                )
                succeeded += 1
            } catch {
                failed += 1
                messages.append("\(input.originalFilename): \(error.localizedDescription)")
            }
        }

        return BatchConversionSummary(
            total: inputs.count,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed,
            failureMessages: messages
        )
    }
}
