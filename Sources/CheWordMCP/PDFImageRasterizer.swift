import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OOXMLSwift

/// #16 — `insert_image_from_path` PDF support (Stage 1: rasterize).
///
/// Renders one page of a PDF to a PNG file using native macOS `PDFKit` +
/// `CoreGraphics` (see `.claude/rules/native-macos-compat.md`: PDFKit is the
/// PDF base layer for this repo; no external CLI is shelled out to). The
/// design note on #16 ("rasterize path rejected, needs OLE embedding")
/// rejected *shelling out to `pdftoppm`* specifically — a native, in-process
/// rasterization is a materially different trade-off (no external process,
/// no PATH dependency, page selection stays a first-class parameter instead
/// of a caller-side pre-processing step) and is what this type does.
///
/// True vector embedding (OLE `<w:object>`, per the design note's Path B) is
/// a separate, much larger feature and is not attempted here — rasterizing
/// loses vector scaling fidelity, and the caller can tell it happened because
/// the tool description says so.
enum PDFImageRasterizer {

    /// Default render resolution. Fixed rather than caller-configurable per
    /// #16's scope ("可加 page 參數" — only `page` was asked for); 150 DPI is
    /// a reasonable screen/print middle ground for a watermark-free page
    /// image embedded in a Word document. Documented here so the trade-off
    /// this DPI represents is visible to a reader, not just to the caller.
    static let defaultDPI: Double = 150

    /// Render `page` (1-based) of the PDF at `pdfPath` to a freshly created
    /// temporary PNG file. Caller owns cleanup of the returned URL's parent
    /// directory (`FileManager.default.removeItem`).
    static func rasterize(pdfPath: String, page: Int, dpi: Double = defaultDPI) throws -> (url: URL, widthPx: Int, heightPx: Int) {
        guard FileManager.default.fileExists(atPath: pdfPath) else {
            throw WordError.fileNotFound(pdfPath)
        }
        guard let pdfDocument = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw WordError.invalidFormat("could not open '\(pdfPath)' as a PDF")
        }
        // #16 R2 F3: `PDFDocument(url:)` does NOT return nil for an
        // encrypted PDF — it hands back a locked, non-nil document.
        // `pdfPage.bounds(for: .mediaBox)` then reports a fixed US Letter
        // box (612x792pt) regardless of the PDF's real page size, and
        // `pdfPage.draw(with:to:)` draws nothing — the result was a
        // successful-looking, wrong-size, entirely blank PNG with no signal
        // to the caller that anything was wrong. Refuse before either call.
        guard !pdfDocument.isLocked else {
            throw WordError.invalidFormat(
                "PDF '\(pdfPath)' is password-protected and locked; cannot rasterize its content without the password. "
                + "Unlock it first (e.g. a general-purpose PDF tool that accepts the password) and retry.")
        }
        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            throw WordError.invalidFormat("PDF '\(pdfPath)' has no pages")
        }
        guard page >= 1, page <= pageCount else {
            throw WordError.invalidParameter(
                "page", "必須介於 1 到 \(pageCount)（該 PDF 的總頁數）之間，不接受 \(page)")
        }
        guard let pdfPage = pdfDocument.page(at: page - 1) else {
            throw WordError.invalidFormat("could not access page \(page) of '\(pdfPath)'")
        }

        let mediaBox = pdfPage.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else {
            throw WordError.invalidFormat("page \(page) of '\(pdfPath)' has an empty media box")
        }
        let scale = dpi / 72.0
        let widthPx = max(1, Int((mediaBox.width * scale).rounded()))
        let heightPx = max(1, Int((mediaBox.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: widthPx,
                height: heightPx,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw WordError.writeError("could not create a render context for '\(pdfPath)' page \(page)")
        }
        // White background — a PDF page with a transparent/empty background
        // would otherwise rasterize onto whatever CGContext defaults to
        // (black), which is never what a caller embedding a document page
        // as an image wants.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        context.scaleBy(x: scale, y: scale)
        pdfPage.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            throw WordError.writeError("could not rasterize '\(pdfPath)' page \(page)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("che-word-mcp", isDirectory: true)
            .appendingPathComponent("pdf-rasterize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let pngURL = tempDir.appendingPathComponent("page\(page).png")

        guard let destination = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw WordError.writeError("could not create a PNG writer for '\(pngURL.path)'")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempDir)
            throw WordError.writeError("could not finalize the rasterized PNG for '\(pdfPath)' page \(page)")
        }

        return (pngURL, widthPx, heightPx)
    }
}
