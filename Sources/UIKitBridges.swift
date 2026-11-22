import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Retained Export Coordinator (Prevents iOS 16.0 White-Screen / XPC Failures on TrollStore)
@MainActor
public final class ExportPresenterCoordinator: NSObject, UIDocumentPickerDelegate, UIDocumentInteractionControllerDelegate {
    public static let shared = ExportPresenterCoordinator()

    private var activeDocumentInteraction: UIDocumentInteractionController?
    private var activeStagedURL: URL?

    /// Creates a 0-byte APFS hardlink (or fallback copy) in a clean temporary export directory
    /// with 0644 permissions so iOS 16 DocumentManager / ShareSheet XPC can read files outside standard app sandboxes.
    private func stageExportURL(for originalURL: URL) -> URL {
        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory.appendingPathComponent("AppVaultExport", isDirectory: true)
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exportDir.path)

        let stagedURL = exportDir.appendingPathComponent(originalURL.lastPathComponent)
        if fm.fileExists(atPath: stagedURL.path) {
            try? fm.removeItem(at: stagedURL)
        }

        // Instant zero-space APFS hardlink first; fallback to copy if cross-volume
        if (try? fm.linkItem(at: originalURL, to: stagedURL)) != nil {
            PosixHelper.shared.fixPermissions(at: stagedURL.path)
            return stagedURL
        }
        if (try? fm.copyItem(at: originalURL, to: stagedURL)) != nil {
            PosixHelper.shared.fixPermissions(at: stagedURL.path)
            return stagedURL
        }
        return originalURL
    }

    private func cleanupStagedURL() {
        if let staged = activeStagedURL {
            try? FileManager.default.removeItem(at: staged)
            activeStagedURL = nil
        }
    }

    /// Waits until any dismissing ActionSheet / Alert / Sheet finishes animating out on iOS 16
    /// before presenting a new UIKit modal (prevents blank white remote view controllers).
    public func presentWhenReady(attempt: Int = 0, _ action: @escaping @MainActor (UIViewController) -> Void) {
        guard let root = rootKeyViewController() else { return }

        var presenter = root
        while let next = presenter.presentedViewController {
            if next.isBeingDismissed || next.isBeingPresented || next is UIAlertController {
                if attempt < 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.presentWhenReady(attempt: attempt + 1, action)
                    }
                }
                return
            }
            presenter = next
        }

        if presenter.isBeingDismissed || presenter.isBeingPresented || presenter.view.window == nil {
            if attempt < 15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.presentWhenReady(attempt: attempt + 1, action)
                }
            }
            return
        }

        action(presenter)
    }

    public func presentShareSheet(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLogger.shared.log("Export", "Export aborted: file missing at \(url.path)", level: .error)
            return
        }
        let staged = stageExportURL(for: url)
        DebugLogger.shared.log("Export", "Staged \(url.lastPathComponent) -> \(staged.path)")
        activeStagedURL = (staged.path != url.path) ? staged : nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.presentWhenReady { topVC in
            // Pass plain file URL directly (avoids LPLinkMetadata XPC hang on custom .adbk files on iOS 16.0)
            let controller = UIActivityViewController(activityItems: [staged], applicationActivities: nil)
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                Task { @MainActor in
                    self?.cleanupStagedURL()
                }
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = topVC.view
                let bounds = topVC.view.bounds
                popover.sourceRect = CGRect(x: max(0, bounds.midX - 10), y: max(0, bounds.midY - 10), width: 20, height: 20)
                popover.permittedArrowDirections = .any
            }
                topVC.present(controller, animated: true)
            }
        }
    }

    public func presentExportPicker(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLogger.shared.log("Export", "Export aborted: file missing at \(url.path)", level: .error)
            return
        }
        let staged = stageExportURL(for: url)
        DebugLogger.shared.log("Export", "Staged \(url.lastPathComponent) -> \(staged.path)")
        activeStagedURL = (staged.path != url.path) ? staged : nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.presentWhenReady { topVC in
            let picker = UIDocumentPickerViewController(forExporting: [staged], asCopy: true)
            picker.delegate = self
            picker.modalPresentationStyle = .formSheet
            if let popover = picker.popoverPresentationController {
                popover.sourceView = topVC.view
                let bounds = topVC.view.bounds
                popover.sourceRect = CGRect(x: max(0, bounds.midX - 10), y: max(0, bounds.midY - 10), width: 20, height: 20)
                popover.permittedArrowDirections = .any
            }
                topVC.present(picker, animated: true)
            }
        }
    }

    /// Fallback native iOS Open-In sheet (UIDocumentInteractionController) — works reliably on iOS 16.0 TrollStore
    /// even when DocumentManager's Files XPC extension refuses an unsandboxed app.
    public func presentOpenInMenu(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLogger.shared.log("Export", "Export aborted: file missing at \(url.path)", level: .error)
            return
        }
        let staged = stageExportURL(for: url)
        DebugLogger.shared.log("Export", "Staged \(url.lastPathComponent) -> \(staged.path)")
        activeStagedURL = (staged.path != url.path) ? staged : nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.presentWhenReady { topVC in
            let docController = UIDocumentInteractionController(url: staged)
            docController.delegate = self
            docController.name = url.lastPathComponent
            self.activeDocumentInteraction = docController
            let rect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 1, height: 1)
            if !docController.presentOptionsMenu(from: rect, in: topVC.view, animated: true) {
                    self.presentShareSheet(url: url)
                }
            }
        }
    }

    // MARK: - UIDocumentPickerDelegate
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupStagedURL()
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupStagedURL()
    }

    // MARK: - UIDocumentInteractionControllerDelegate
    public func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return rootKeyViewController() ?? UIViewController()
    }

    public func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
        activeDocumentInteraction = nil
        cleanupStagedURL()
    }
}

// MARK: - Window & Topmost Controller Helpers
@MainActor
public func rootKeyViewController() -> UIViewController? {
    let windowScene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    guard let window = windowScene?.windows.first(where: { $0.isKeyWindow })
            ?? windowScene?.windows.first else {
        return nil
    }
    return window.rootViewController
}

@MainActor
public func topMostViewController() -> UIViewController? {
    var topVC = rootKeyViewController()
    while let presented = topVC?.presentedViewController, !presented.isBeingDismissed {
        topVC = presented
    }
    return topVC
}

// MARK: - Public Export Entry Points
@MainActor
public func presentShareSheet(url: URL) {
    ExportPresenterCoordinator.shared.presentShareSheet(url: url)
}

@MainActor
public func presentExportPicker(url: URL) {
    ExportPresenterCoordinator.shared.presentExportPicker(url: url)
}

@MainActor
public func presentOpenInMenu(url: URL) {
    ExportPresenterCoordinator.shared.presentOpenInMenu(url: url)
}

@MainActor
public func openInFilza(url: URL) -> Bool {
    guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let filzaURL = URL(string: "filza://view\(encoded)") else {
        return false
    }
    if UIApplication.shared.canOpenURL(filzaURL) {
        UIApplication.shared.open(filzaURL)
        return true
    }
    return false
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
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
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
