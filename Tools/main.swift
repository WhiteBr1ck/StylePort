import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: styleport-convert source.heic Styles3Template.bin output.heic\n", stderr)
    exit(2)
}

do {
    let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let templateData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let output = try Styles3Transplanter().convert(source: source, template: Styles3Template(data: templateData))
    try output.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    print("wrote \(output.count) bytes")
} catch {
    fputs("conversion failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
