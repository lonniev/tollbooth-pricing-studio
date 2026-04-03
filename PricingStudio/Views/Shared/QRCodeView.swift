import SwiftUI
import CoreImage.CIFilterBuiltins

/// Generate a QR code UIImage from a string. Returns nil on failure.
func generateQRCode(from string: String) -> UIImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaleX = 200.0 / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleX))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}

/// A SwiftUI view that renders a QR code or falls back to a link button.
struct QRCodeView: View {
    let string: String
    let size: CGFloat

    init(_ string: String, size: CGFloat = 200) {
        self.string = string
        self.size = size
    }

    var body: some View {
        if let image = generateQRCode(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let url = URL(string: string) {
            Link(destination: url) {
                Label("Open Payment Page", systemImage: "arrow.up.right.square")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
