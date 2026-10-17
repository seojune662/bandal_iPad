import XCTest
@testable import Bandal

final class NativeLibraryIndexTests: XCTestCase {
    func testNotesFolderKeepsNonPDFAndNestedMaterialsReachable() {
        let note = NativeMaterial(relPath: "노트/텍스트.md", name: "텍스트.md", kind: "note")
        let image = NativeMaterial(relPath: "노트/사진.png", name: "사진.png", kind: "image")
        let pdf = NativeMaterial(relPath: "노트/하위/강의.pdf", name: "강의.pdf", kind: "pdf")
        let nested = NativeMaterial(relPath: "노트/하위", name: "하위", kind: "dir", children: [pdf])
        let root = NativeMaterial(relPath: "노트", name: "노트", kind: "dir", children: [note, image, nested])
        XCTAssertEqual(NativeLibraryIndex.contents(in: "", materials: [root]), [root])
        XCTAssertEqual(NativeLibraryIndex.contents(in: "노트", materials: [root]), [note, image, nested])
        XCTAssertEqual(NativeLibraryIndex.contents(in: "노트/하위", materials: [root]), [pdf])
        XCTAssertEqual(Set(NativeLibraryIndex.flatten([root]).map(\.relPath)), [root.relPath, note.relPath, image.relPath, nested.relPath, pdf.relPath])
    }
}
