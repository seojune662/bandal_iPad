import Foundation
import PDFKit

guard CommandLine.arguments.count == 2,
      let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    fputs("Cannot read PDF geometry\n", stderr); exit(1)
}
var result: [[String: Any]] = []
for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { exit(1) }
    let crop = page.bounds(for: .cropBox)
    result.append(["cropX": crop.minX, "cropY": crop.minY, "width": crop.width,
                   "height": crop.height, "rotation": ((page.rotation % 360) + 360) % 360])
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
