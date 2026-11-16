import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LinkPresentation

// MARK: - Safe Activity Item Source for Custom Backup Archives
public final class BackupActivityItemSource: NSObject, UIActivityItemSource {
    public let fileURL: URL
    public let title: String

    public init(fileURL: URL, title: String? = nil) {
        self.fileURL = fileURL
        self.title = title ?? fileURL.lastPathComponent
        super.init()
    }

    public func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return fileURL
    }

    public func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return fileURL
    }

    public func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = fileURL
        metadata.url = fileURL
        return metadata
    }
}

// MARK: - Window & Topmost Controller Helper
@MainActor
public func topMostViewController() -> UIViewController? {
    let windowScene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    guard let window = windowScene?.windows.first(where: { $0.isKeyWindow })
            ?? windowScene?.windows.first else {
        return nil
    }

    var topVC = window.rootViewController
    while let presented = topVC?.presentedViewController, !presented.isBeingDismissed {
        topVC = presented
    }
    return topVC
}

// MARK: - Safe UIKit Share Sheet Presenter (Crash-Proof on iOS 16 & iPad)
@MainActor
public func presentShareSheet(url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    guard let topVC = topMostViewController() else { return }

    if topVC.isBeingDismissed || topVC.isBeingPresented {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentShareSheet(url: url)
        }
        return
    }

    let itemSource = BackupActivityItemSource(fileURL: url, title: url.lastPathComponent)
    let controller = UIActivityViewController(activityItems: [itemSource], applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
        popover.sourceView = topVC.view
        let bounds = topVC.view.bounds
        popover.sourceRect = CGRect(x: max(0, bounds.midX - 10), y: max(0, bounds.midY - 10), width: 20, height: 20)
        popover.permittedArrowDirections = .any
    }

    topVC.present(controller, animated: true)
}

// MARK: - Safe Native Document Export Picker (Save to Files / iCloud)
@MainActor
public func presentExportPicker(url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    guard let topVC = topMostViewController() else { return }

    if topVC.isBeingDismissed || topVC.isBeingPresented {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentExportPicker(url: url)
        }
        return
    }

    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    if let popover = picker.popoverPresentationController {
        popover.sourceView = topVC.view
        let bounds = topVC.view.bounds
        popover.sourceRect = CGRect(x: max(0, bounds.midX - 10), y: max(0, bounds.midY - 10), width: 20, height: 20)
        popover.permittedArrowDirections = .any
    }

    topVC.present(picker, animated: true)
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
