import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Safe UIKit Share Sheet Presenter (Crash-Proof on iOS 16 & iPad)
@MainActor
public func presentShareSheet(url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene ??
                            UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ??
                       windowScene.windows.first?.rootViewController else {
        return
    }

    var topVC = rootVC
    while let presented = topVC.presentedViewController, !presented.isBeingDismissed {
        topVC = presented
    }

    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
        popover.sourceView = topVC.view
        popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }

    topVC.present(controller, animated: true)
}

// MARK: - Share Sheet Bridge (Backwards Compatibility)
public struct ShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]
    public let applicationActivities: [UIActivity]?

    public init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker Bridge
public struct DocumentPicker: UIViewControllerRepresentable {
    public let onDocumentPicked: (URL) -> Void

    public init(onDocumentPicked: @escaping (URL) -> Void) {
        self.onDocumentPicked = onDocumentPicked
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentPicked: onDocumentPicked)
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            UTType.archive,
            UTType.zip,
            UTType(filenameExtension: "adbk") ?? .data,
            UTType.data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onDocumentPicked: (URL) -> Void

        public init(onDocumentPicked: @escaping (URL) -> Void) {
            self.onDocumentPicked = onDocumentPicked
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onDocumentPicked(url)
        }
    }
}
