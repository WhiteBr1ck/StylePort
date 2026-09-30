import Observation
import PhotosUI
import SwiftUI

struct InspectedPhoto: Identifiable {
  let id = UUID()
  let photo: SelectedPhoto
  let metadata: PhotoMetadata
}

@MainActor @Observable
final class PhotoInspectionSession {
  private(set) var pickerItems: [PHPickerResult] = []
  private(set) var photos: [InspectedPhoto] = []
  private(set) var isLoading = false
  private(set) var error: String?
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  init() {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--ui-test-inspection"),
        let data = Data(
          base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ),
        let image = UIImage(data: data),
        let metadata = try? PhotoMetadataReader.read(data: data, filename: "InspectionFixture.png")
      {
        let photo = SelectedPhoto(
          sourceURL: URL(fileURLWithPath: "/unused/InspectionFixture.png"),
          assetIdentifier: nil, preview: image, pixelSize: CGSize(width: 1, height: 1),
          fileName: metadata.filename)
        photos = [InspectedPhoto(photo: photo, metadata: metadata)]
      }
    #endif
  }

  func loadSelection(_ items: [PHPickerResult]) {
    loadTask?.cancel()
    pickerItems = items
    guard !pickerItems.isEmpty else {
      clear()
      return
    }
    isLoading = true
    error = nil
    loadTask = Task {
      do {
        var result: [InspectedPhoto] = []
        for item in items {
          let photo = try await PhotoImporter.loadNamedPhoto(item)
          let metadata = try await PhotoMetadataReader.read(
            url: photo.sourceURL, filename: photo.fileName)
          try Task.checkCancellation()
          result.append(InspectedPhoto(photo: photo, metadata: metadata))
        }
        photos = result
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      isLoading = false
      loadTask = nil
    }
  }

  func clear() {
    loadTask?.cancel()
    loadTask = nil
    pickerItems = []
    photos = []
    isLoading = false
    error = nil
  }
}

struct PhotoInfoView: View {
  @Environment(AppPreferences.self) private var preferences
  @Bindable var session: PhotoInspectionSession
  private struct PickerRequest: Identifiable { let id = UUID() }
  @State private var pickerRequest: PickerRequest?

  var body: some View {
    Group {
      if session.isLoading {
        ProgressView(text("读取照片信息…", "Reading photo information…"))
      } else if let error = session.error {
        ContentUnavailableView {
          Label(text("无法读取照片", "Unable to Read Photo"), systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          picker
        }
      } else if session.photos.isEmpty {
        ContentUnavailableView {
          Label(text("查看照片信息", "Photo Information"), systemImage: "info.circle")
        } description: {
          Text(
            text(
              "选择一张照片查看摄影风格、拍摄参数与图像元数据，可选两张照片进行对照。",
              "Select a photo to inspect its Photographic Styles, capture parameters and image metadata, or select two photos to compare."
            ))
        } actions: {
          picker
        }
      } else {
        List {
          if session.photos.count == 2 {
            comparison(session.photos[0].metadata, session.photos[1].metadata)
          }
          ForEach(session.photos) { item in
            PhotoMetadataSections(item: item, language: preferences.language)
          }
        }
      }
    }
    .navigationTitle(text("查看", "Inspect"))
    .sheet(item: $pickerRequest) { _ in
      NamedPhotoPicker { results in
        pickerRequest = nil
        if !results.isEmpty { session.loadSelection(results) }
      }
      .ignoresSafeArea()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { picker }
      if !session.photos.isEmpty || session.error != nil {
        ToolbarItem(placement: .topBarLeading) {
          Button(text("清空", "Clear"), action: session.clear)
        }
      }
    }
  }

  private var picker: some View {
    Button {
      pickerRequest = PickerRequest()
    } label: {
      Label(text("选择照片", "Choose Photos"), systemImage: "photo.badge.plus")
    }
    .accessibilityIdentifier("inspect.choosePhotos")
  }

  private func comparison(_ original: PhotoMetadata, _ copy: PhotoMetadata) -> some View {
    Section {
      LabeledContent(text("第一张", "First"), value: original.filename)
      LabeledContent(text("第二张", "Second"), value: copy.filename)
      if let first = original.style?.primaryImageDigest, let second = copy.style?.primaryImageDigest
      {
        LabeledContent(
          text("主图编码数据", "Primary Image Data"),
          value: first == second ? text("一致", "Identical") : text("不同", "Different"))
      } else {
        LabeledContent(text("主图编码数据", "Primary Image Data"), value: text("无法校验", "Unavailable"))
      }
      LabeledContent(
        text("文件大小", "File Size"), value: "\(size(original.byteCount)) → \(size(copy.byteCount))")
      DisclosureGroup(text("元数据差异", "Metadata Differences")) {
        let differences = copy.differences(from: original)
        if differences.isEmpty { Text(text("未发现元数据差异", "No metadata differences found")) }
        ForEach(differences) { field in MetadataRawRow(field: field) }
      }
    } header: {
      Text(text("两张照片对照", "Compare Two Photos"))
    }
  }

  private func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
  private func text(_ zh: String, _ en: String) -> String {
    preferences.language.text(zh: zh, en: en)
  }
}

private struct PhotoMetadataSections: View {
  let item: InspectedPhoto
  let language: AppPreferences.Language

  var body: some View {
    Section(item.metadata.filename) {
      Image(uiImage: item.photo.preview)
        .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240)
        .accessibilityLabel(text("照片预览", "Photo Preview"))
      LabeledContent(text("格式", "Format"), value: item.metadata.format)
      LabeledContent(
        text("文件大小", "File Size"),
        value: ByteCountFormatter.string(
          fromByteCount: Int64(item.metadata.byteCount), countStyle: .file))
    }
    Section {
      if let style = item.metadata.style {
        LabeledContent(
          text("摄影风格编辑数据", "Photographic Style Data"), value: presence(style.hasStyles))
        LabeledContent(text("质感风格数据", "Texture Style Data"), value: presence(style.hasTexture))
        LabeledContent(
          text("2026 辅助蒙版类型", "2026 Auxiliary Matte Types"), value: "\(style.newMatteCount)")
        ForEach(style.payloadSizes.keys.sorted(), id: \.self) { uri in
          LabeledContent(
            uri == PhotoStyleMetadata.stylesURI
              ? text("风格数据大小", "Style Payload Size") : text("质感数据大小", "Texture Payload Size"),
            value: "\(style.payloadSizes[uri] ?? 0) bytes")
        }
        DisclosureGroup(text("风格原始数据", "Raw Style Data")) {
          ForEach(style.rawFields) { field in MetadataRawRow(field: field) }
          ForEach(style.auxiliaryTypes, id: \.self) { uri in
            Text(uri).font(.caption).textSelection(.enabled)
          }
        }
      } else {
        Text(text("未读取到可识别的 HEIC 风格容器", "No readable HEIC style container"))
      }
    } header: {
      Text(text("摄影风格", "Photographic Styles"))
    }
    Section(text("拍摄与图像信息", "Capture and Image Information")) {
      ForEach(item.metadata.basics) { field in
        LabeledContent(
          fieldTitle(field.id),
          value: field.id == "gps"
            ? (field.value == "present" ? text("包含", "Present") : text("不包含", "Absent"))
            : field.value)
      }
    }
    Section {
      DisclosureGroup(text("全部元数据", "All Metadata")) {
        ForEach(item.metadata.rawFields) { field in MetadataRawRow(field: field) }
      }
      DisclosureGroup(text("过片的转换会修改什么？", "What Does Conversion Change?")) {
        Text(
          text(
            "转换保留原有主图编码、EXIF 和摄影风格数据，新增质感风格数据、12 组占位辅助蒙版及关联的 XMP，并重建容器引用与偏移。占位蒙版并非根据原图重新生成的真实分割结果。默认另存副本；此查看页面不做任何修改。",
            "Conversion preserves the original primary image encoding, EXIF and style data. It adds texture style data, 12 placeholder auxiliary mattes and associated XMP, and rebuilds container references and offsets. Placeholder mattes are not actual segmentations computed from the source photo. Copies are saved by default; this inspector changes nothing."
          ))
      }
    }
  }

  private func presence(_ exists: Bool) -> String {
    exists ? text("检测到", "Detected") : text("未检测到", "Not Detected")
  }
  private func text(_ zh: String, _ en: String) -> String { language.text(zh: zh, en: en) }
  private func fieldTitle(_ key: String) -> String {
    let titles: [String: (String, String)] = [
      "dimensions": ("像素尺寸", "Dimensions"), "camera": ("相机", "Camera"), "make": ("制造商", "Make"),
      "lens": ("镜头", "Lens"), "date": ("拍摄时间", "Captured"), "timeZone": ("时区", "Time Zone"),
      "aperture": ("光圈", "Aperture"), "exposure": ("快门", "Shutter"), "iso": ("ISO", "ISO"),
      "focalLength": ("焦距", "Focal Length"),
      "equivalentFocalLength": ("35 mm 等效焦距", "35 mm Equivalent"),
      "exposureBias": ("曝光补偿", "Exposure Bias"), "profile": ("色彩配置", "Color Profile"),
      "colorModel": ("色彩模型", "Color Model"), "depth": ("位深", "Bit Depth"),
      "orientation": ("方向标记", "Orientation"),
      "software": ("拍摄系统版本", "Capture Software"), "gps": ("位置元数据", "Location Metadata"),
    ]
    guard let title = titles[key] else { return key }
    return text(title.0, title.1)
  }
}

private struct MetadataRawRow: View {
  let field: PhotoMetadataField
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(field.id).font(.caption).foregroundStyle(.secondary)
      Text(field.value).font(.callout)
    }
    .textSelection(.enabled)
  }
}
