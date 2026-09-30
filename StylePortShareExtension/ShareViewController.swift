import Social
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIActivityIndicatorView(style: .large)
    private let doneButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    private let resultsStack = UIStackView()
    private var isConverting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground
        titleLabel.text = "过片"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        let count = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }.count
        detailLabel.text = "转换这 \(count) 张照片？\n转换后的照片将保存到照片库，保留原图。"
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        progressView.isHidden = true
        confirmButton.setTitle("确认转换", for: .normal)
        confirmButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        confirmButton.addTarget(self, action: #selector(confirmConversion), for: .touchUpInside)
        doneButton.setTitle("取消", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        resultsStack.axis = .vertical
        resultsStack.spacing = 12
        resultsStack.isHidden = true
        let stack = UIStackView(arrangedSubviews: [titleLabel, progressView, detailLabel, resultsStack, confirmButton, doneButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func confirmConversion() {
        guard !isConverting else { return }
        isConverting = true
        confirmButton.isHidden = true
        doneButton.isHidden = true
        progressView.isHidden = false
        progressView.startAnimating()
        Task { await startConversion() }
    }

    private func startConversion() async {
        let batch = await loadInputs()
        detailLabel.text = "正在转换 \(batch.total) 张照片…"
        let summary = await ExternalPhotoConversion.convert(batch.inputs)
        showCompletion(total: batch.total, succeeded: summary.succeeded,
                       failed: summary.failed + batch.failed, skipped: summary.skipped + batch.skipped)
    }

    private func loadInputs() async -> (inputs: [ExternalPhotoInput], total: Int, skipped: Int, failed: Int) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var results: [ExternalPhotoInput] = []
        var skipped = 0
        var failed = 0
        for provider in providers {
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
                skipped += 1
                continue
            }
            do {
                results.append(try await copyItem(from: provider, typeIdentifier: typeIdentifier))
            } catch {
                failed += 1
            }
        }
        return (results, providers.count, skipped, failed)
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [UTType.heic, UTType.heif, UTType.jpeg, UTType.image]
        return preferred.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })?.identifier
    }

    private func copyItem(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> ExternalPhotoInput {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    let suppliedName = suggestedName ?? url.lastPathComponent
                    let sourceExtension = url.pathExtension
                    let filename: String
                    if URL(fileURLWithPath: suppliedName).pathExtension.isEmpty, !sourceExtension.isEmpty {
                        filename = suppliedName + "." + sourceExtension
                    } else {
                        filename = suppliedName
                    }
                    let safeName = URL(fileURLWithPath: filename).lastPathComponent
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("GuoPian-Share", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(safeName.isEmpty ? "Photo.HEIC" : safeName)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: ExternalPhotoInput(
                        url: destination,
                        originalFilename: destination.lastPathComponent
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showCompletion(total: Int, succeeded: Int, failed: Int, skipped: Int) {
        progressView.stopAnimating()
        progressView.isHidden = true
        detailLabel.text = "转换完成 · 处理 \(total) 张"
        for (title, count, symbol, color) in [
            ("成功", succeeded, "checkmark.circle.fill", UIColor.systemGreen),
            ("失败", failed, "xmark.circle.fill", UIColor.systemRed),
            ("跳过", skipped, "arrow.forward.circle.fill", UIColor.systemOrange),
        ] {
            let icon = UIImageView(image: UIImage(systemName: symbol))
            icon.tintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UILabel()
            label.text = "\(title)  \(count) 张"
            label.font = .preferredFont(forTextStyle: .headline)
            label.adjustsFontForContentSizeCategory = true
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.spacing = 10
            resultsStack.addArrangedSubview(row)
        }
        resultsStack.isHidden = false
        doneButton.setTitle("完成", for: .normal)
        doneButton.isHidden = false
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
