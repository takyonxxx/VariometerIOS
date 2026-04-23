import SwiftUI
import UIKit

/// SwiftUI wrapper around UIActivityViewController for sharing files.
/// The system share sheet automatically includes WhatsApp, Messages, Mail,
/// AirDrop, Files app, etc. for the provided URLs.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
