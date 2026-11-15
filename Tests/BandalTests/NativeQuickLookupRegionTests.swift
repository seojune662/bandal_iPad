import XCTest
import PDFKit
import UIKit
@testable import Bandal

/// Whether a lassoed area can be told from its text or has to be seen, and what is read from it: whole lines, the
/// heading above, and the picture. The slides are like the three the lookup failed on: a formula whose text layer
/// is in pieces under two half-circled lines, a line drawing with its letters, two lines of integrals.
final class NativeQuickLookupRegionTests: XCTestCase {
    // MARK: the words

    func testFormulaPiecesAreToldFromWords() {
        for piece in ["q", "w", "~", "R", "=", "dS", "T", "α", "θ", "∫", "p_u", "x^2", "x2", "Tc/Th", "1/√R", "≥", "(τ", "θ)", "+", "−"] {
            XCTAssertTrue(NativeQuickLookupRegion.isFormulaPiece(piece), piece)
        }
        for word in ["a", "I", "of", "is", "concept", "blunt", "re-entry", "capsule:", "sin", "cos", "엔트로피는", "않는다.", "2주차", "-", "1", "12", "2024"] {
            XCTAssertFalse(NativeQuickLookupRegion.isFormulaPiece(word), word)
        }
        for number in ["1", "2.5", "10%", "(3)", "1,000"] { XCTAssertTrue(NativeQuickLookupRegion.isNumber(number), number) }
        for word in ["x2", "1/2", "3쪽", "a"] { XCTAssertFalse(NativeQuickLookupRegion.isNumber(word), word) }
    }

    func testALineOfSymbolsIsAFormulaAndProseIsNot() {
        XCTAssertTrue(NativeQuickLookupRegion.hasFormulaLine("A concept of a blunt re-entry capsule\nq w ~ 1 R"), "the formula's pieces under a sentence")
        XCTAssertTrue(NativeQuickLookupRegion.hasFormulaLine("L = N cos α − A sin α"))
        XCTAssertTrue(NativeQuickLookupRegion.hasFormulaLine("N ′ = − ∫ ( p u cos θ + τ u sin θ ) d s u"))
        XCTAssertTrue(NativeQuickLookupRegion.hasFormulaLine("2 x + 3 y = 7"), "coefficients are left out of the count")
        for prose in ["Entropy of an isolated system never decreases.", "고립계의 엔트로피는 감소하지 않는다.",
                      "효율은 1 - Tc/Th 이다.", "1 Introduction\n2 Methods\n3 Results", "12 30 45", "Figure 3"] {
            XCTAssertFalse(NativeQuickLookupRegion.hasFormulaLine(prose), prose)
            XCTAssertLessThan(NativeQuickLookupRegion.mathShare(of: prose), NativeQuickLookupRegion.mathThreshold, prose)
        }
        XCTAssertEqual(NativeQuickLookupRegion.mathShare(of: ""), 0)
        XCTAssertGreaterThanOrEqual(NativeQuickLookupRegion.mathShare(of: "S 0\nd Q T"), NativeQuickLookupRegion.mathThreshold)
    }

    // MARK: what is printed there besides text

    private func bitmap(width: Int = 200, height: Int = 100, paper: UInt8 = 255, _ draw: (inout [UInt8]) -> Void = { _ in }) -> NativeQuickLookupRegion.Bitmap {
        var pixels = [UInt8](repeating: paper, count: width * height)
        draw(&pixels)
        return .init(pixels: pixels, width: width, height: height)
    }

    func testAFigureIsWhatInkTouchesOutsideTheTextLines() {
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(bitmap(), text: []), 0, "blank")
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(bitmap(paper: 60), text: []), 0, "paper of any shade is paper")
        // Glyphs inside a text line's box are text.
        let glyphs = bitmap { pixels in for y in 20..<34 { for x in 10..<180 where x % 3 != 0 { pixels[y * 200 + x] = 0 } } }
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(glyphs, text: [CGRect(x: 0.04, y: 0.18, width: 0.88, height: 0.18)]), 0)
        XCTAssertGreaterThan(NativeQuickLookupRegion.figureShare(glyphs, text: []), NativeQuickLookupRegion.figureThreshold, "the same ink with no text layer under it")
        // One rule across the area crosses a twentieth of the grid: not a figure.
        let rule = bitmap { pixels in for x in 0..<200 { pixels[50 * 200 + x] = 0 } }
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(rule, text: []), 0.05, accuracy: 0.001)
        XCTAssertLessThan(NativeQuickLookupRegion.figureShare(rule, text: []), NativeQuickLookupRegion.figureThreshold)
        // A hairline outline covers little and crosses much.
        let outline = bitmap { pixels in
            for x in 20..<180 { pixels[20 * 200 + x] = 0; pixels[80 * 200 + x] = 0 }
            for y in 20..<81 { pixels[y * 200 + 20] = 0; pixels[y * 200 + 179] = 0 }
        }
        XCTAssertGreaterThan(NativeQuickLookupRegion.figureShare(outline, text: []), NativeQuickLookupRegion.figureThreshold)
        // A dark last row and column is how an area of a fractional size is drawn, not something printed.
        let edged = bitmap { pixels in
            for x in 0..<200 { pixels[99 * 200 + x] = 70 }
            for y in 0..<100 { pixels[y * 200 + 199] = 70 }
        }
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(edged, text: []), 0)
        // The app's paper ruling (about 0.11 from white) is not ink.
        let ruled = bitmap { pixels in for y in stride(from: 10, to: 100, by: 10) { for x in 0..<200 { pixels[y * 200 + x] = 227 } } }
        XCTAssertEqual(NativeQuickLookupRegion.figureShare(ruled, text: []), 0)
    }

    func testThePictureIsNeededForAFigureOrAFormulaAndNotForProse() {
        let prose = "A concept of a blunt re-entry capsule: the shock stands off the nose."
        XCTAssertFalse(NativeQuickLookupRegion.needsPicture(text: prose, figure: 0))
        XCTAssertFalse(NativeQuickLookupRegion.needsPicture(text: prose, figure: 0.05), "a rule under the line")
        XCTAssertTrue(NativeQuickLookupRegion.needsPicture(text: prose, figure: 0.2), "a figure beside the text")
        XCTAssertTrue(NativeQuickLookupRegion.needsPicture(text: prose + "\nq w ~ 1 R", figure: 0), "a formula line")
        XCTAssertTrue(NativeQuickLookupRegion.needsPicture(text: "", figure: 0.3), "a figure with no text at all")
        XCTAssertFalse(NativeQuickLookupRegion.needsPicture(text: "", figure: 0))
    }

    // MARK: three slides

    private static let slide = CGRect(x: 0, y: 0, width: 960, height: 540)
    private static let capsule = ["A concept of a blunt re-entry capsule: the bow shock stands off the nose", "and the stagnation point heating falls as the nose radius grows."]
    private static let forces = "The normal and axial forces per unit span follow from the pressure and the shear stress:"
    private static let integrals = ["N ′ = − ∫ ( p u cos θ + τ u sin θ ) d s u + ∫ ( p l cos θ − τ l sin θ ) d s l",
                                    "A ′ = ∫ ( − p u sin θ + τ u cos θ ) d s u + ∫ ( p l sin θ + τ l cos θ ) d s l"]
    private static let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20)]

    private func slides() throws -> URL {
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .semibold)]
        let label: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14)]
        let body = Self.body
        let data = UIGraphicsPDFRenderer(bounds: Self.slide).pdfData { renderer in
            // 1: a blunt capsule's heating. The formula (q̇_w ∼ 1/√R) is in the text layer as pieces.
            renderer.beginPage()
            ("Aerodynamic Heating" as NSString).draw(at: CGPoint(x: 60, y: 40), withAttributes: heading)
            (Self.capsule[0] as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: body)
            (Self.capsule[1] as NSString).draw(at: CGPoint(x: 60, y: 150), withAttributes: body)
            ("q w ~ 1 R" as NSString).draw(at: CGPoint(x: 60, y: 210), withAttributes: body)
            // 2: the angle of attack: hairlines, three letters, and the two formulas beside it.
            renderer.beginPage()
            ("Angle of Attack" as NSString).draw(at: CGPoint(x: 60, y: 40), withAttributes: heading)
            let context = renderer.cgContext
            context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: 120, y: 250, width: 300, height: 60))
            for (from, to) in [(CGPoint(x: 270, y: 280), CGPoint(x: 270, y: 150)), (CGPoint(x: 270, y: 280), CGPoint(x: 430, y: 240)),
                               (CGPoint(x: 60, y: 330), CGPoint(x: 480, y: 230)), (CGPoint(x: 270, y: 280), CGPoint(x: 330, y: 170)),
                               (CGPoint(x: 270, y: 280), CGPoint(x: 200, y: 160))] {
                context.move(to: from); context.addLine(to: to)
            }
            context.strokePath()
            ("N" as NSString).draw(at: CGPoint(x: 278, y: 148), withAttributes: label)
            ("A" as NSString).draw(at: CGPoint(x: 436, y: 222), withAttributes: label)
            ("α" as NSString).draw(at: CGPoint(x: 300, y: 262), withAttributes: label)
            ("L = N cos α − A sin α" as NSString).draw(at: CGPoint(x: 560, y: 190), withAttributes: body)
            ("D = N sin α + A cos α" as NSString).draw(at: CGPoint(x: 560, y: 300), withAttributes: body)
            // 3: the normal and the axial force, two lines of integrals.
            renderer.beginPage()
            ("Aerodynamic Forces" as NSString).draw(at: CGPoint(x: 60, y: 40), withAttributes: heading)
            (Self.forces as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: body)
            (Self.integrals[0] as NSString).draw(at: CGPoint(x: 60, y: 190), withAttributes: body)
            (Self.integrals[1] as NSString).draw(at: CGPoint(x: 60, y: 230), withAttributes: body)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookup-slides-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// A rectangle in slide points as the lasso reports it (fractions of the page).
    private func area(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x / Self.slide.width, y: y / Self.slide.height, width: width / Self.slide.width, height: height / Self.slide.height)
    }

    func testALassoAcrossTheMiddleOfItsLinesReadsThemWhole() async throws {
        let url = try slides()
        // Round the formula and the left third of the two lines above it, as a finger circles it.
        let reading = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 1, region: area(50, 112, 290, 135)))
        XCTAssertEqual(reading.text, (Self.capsule + ["q w ~ 1 R"]).joined(separator: "\n"), "\"blunt re-entry capsule\" and \"stagnation point\" are not cut off")
        XCTAssertEqual(reading.heading, "Aerodynamic Heating")
        XCTAssertTrue(reading.picture, "the formula's pieces say nothing: the area is looked at")
        // The two sentences alone are told from their text.
        let prose = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 1, region: area(50, 112, 800, 68)))
        XCTAssertEqual(prose.text, Self.capsule.joined(separator: "\n"))
        XCTAssertFalse(prose.picture)
        // One term circled inside a line is that term, as before.
        let before = ("and the " as NSString).size(withAttributes: Self.body).width, term = ("stagnation point" as NSString).size(withAttributes: Self.body).width
        let circled = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 1, region: area(60 + before + 1, 148, term - 2, 28)))
        XCTAssertEqual(circled.text, "stagnation point")
        XCTAssertFalse(circled.picture)
        let blank = await NativeQuickLookupPDFText.read(url: url, page: 1, region: area(100, 380, 500, 120))
        XCTAssertNil(blank, "nothing printed there")
        // An area whose size in pixels is not whole is drawn with a half-covered edge: still nothing.
        let uneven = await NativeQuickLookupPDFText.read(url: url, page: 1, region: area(100.3, 380.2, 297.64, 168.38))
        XCTAssertNil(uneven)
    }

    func testAFigureIsLookedAtWithOrWithoutLettersInIt() async throws {
        let url = try slides()
        let figure = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 2, region: area(50, 130, 450, 220)))
        XCTAssertTrue(figure.picture, "hairlines count")
        XCTAssertEqual(figure.heading, "Angle of Attack")
        XCTAssertFalse(figure.text.contains("cos"), "the formulas beside it were not circled: \(figure.text)")
        // A part of the drawing with no letter in it: there is no text, and it is still looked at.
        let bare = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 2, region: area(100, 236, 160, 90)))
        XCTAssertEqual(bare.text, "")
        XCTAssertTrue(bare.picture)
        // A formula beside the figure, circled by itself.
        let formula = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 2, region: area(550, 184, 300, 36)))
        XCTAssertEqual(formula.text, "L = N cos α − A sin α")
        XCTAssertTrue(formula.picture)
    }

    func testLinesOfIntegralsAreLookedAtAndTheSentenceAboveIsRead() async throws {
        let url = try slides()
        let integrals = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 3, region: area(50, 184, 880, 80)))
        XCTAssertEqual(integrals.text, Self.integrals.joined(separator: "\n"))
        XCTAssertEqual(integrals.heading, "Aerodynamic Forces")
        XCTAssertTrue(integrals.picture)
        let sentence = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 3, region: area(50, 114, 880, 36)))
        XCTAssertEqual(sentence.text, Self.forces)
        XCTAssertFalse(sentence.picture, "prose goes as text: no picture is paid for")
    }

    func testAFigureOnAScanWithoutATextLayerIsLookedAt() async throws {
        // A page that is one picture (a scan): a line drawing, no text layer.
        let drawing = UIGraphicsImageRenderer(size: Self.slide.size).image { context in
            UIColor.white.setFill(); context.fill(Self.slide)
            let lines = context.cgContext
            lines.setStrokeColor(UIColor.black.cgColor); lines.setLineWidth(2)
            lines.strokeEllipse(in: CGRect(x: 120, y: 200, width: 300, height: 120))
            lines.move(to: CGPoint(x: 80, y: 330)); lines.addLine(to: CGPoint(x: 480, y: 190)); lines.strokePath()
        }
        let data = UIGraphicsPDFRenderer(bounds: Self.slide).pdfData { renderer in
            renderer.beginPage()
            drawing.draw(in: Self.slide)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lookup-scan-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let figure = try await unwrap(NativeQuickLookupPDFText.read(url: url, page: 1, region: area(100, 180, 400, 170)))
        XCTAssertTrue(figure.picture, "nothing to read as text, something to look at")
        XCTAssertNil(figure.heading)
        let blank = await NativeQuickLookupPDFText.read(url: url, page: 1, region: area(560, 60, 300, 100))
        XCTAssertNil(blank, "an empty part of the scan")
    }

    func testThePictureIsTheAreaALittleWiderAsASmallJPEG() async throws {
        let url = try slides()
        let encoded = try await unwrap(NativeQuickLookupPDFText.picture(url: url, page: 2, region: area(50, 130, 450, 220)))
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let image = try XCTUnwrap(UIImage(data: data))
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        XCTAssertLessThanOrEqual(max(width, height), NativeQuickLookupPDFText.pictureSide)
        XCTAssertEqual(width / height, (450 + 2 * 0.012 * 960) / (220 + 2 * 0.012 * 540), accuracy: 0.05, "the lasso's area and a margin, not the page")
        XCTAssertLessThan(data.count, 120_000)
        let missing = await NativeQuickLookupPDFText.picture(url: url, page: 9, region: area(50, 130, 450, 220))
        XCTAssertNil(missing)
    }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
