import Foundation
import SwiftUI
import UIKit

// MARK: - App Icon Cache & Extractor (Memory + Persistent Disk Cache for Apps & Cloud Backups)
public final class AppIconCache {
    public static let shared = AppIconCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskQueue = DispatchQueue(label: "dev.moe.appvault.iconcache", qos: .utility)
    private let lock = NSLock()
    private var bundleURLCache: [String: URL] = [:]

    private lazy var diskDirectory: URL? = {
        let fm = FileManager.default
        let primary = URL(fileURLWithPath: "/var/mobile/Documents/AppVaultBackups/.IconCache", isDirectory: true)
        if fm.isWritableFile(atPath: "/var/mobile/Documents") {
            try? fm.createDirectory(at: primary, withIntermediateDirectories: true)
            return primary
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("AppVaultIcons", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return nil
    }()

    private init() {
        memoryCache.countLimit = 400
    }

    /// Extracts bundle identifier from an archive filename such as:
    /// `WhatsApp_net.whatsapp.WhatsApp_v1_2026-11-22.adbk` or `App_com.example.app_1732250000.enc.adbk`
    public static func extractBundleIdentifier(fromArchiveName name: String) -> String? {
        var base = name
        for suffix in [".enc.adbk", ".adbk", ".zip"] {
            if base.lowercased().hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                break
            }
        }
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        // Standard pattern: <SanitizedName>_<bundleID>_<vN_date or timestamp>
        let candidate = parts[1]
        if candidate.contains(".") && !candidate.hasPrefix("v") {
            return candidate
        }
        // Fallback: find the first underscore-separated token containing '.'
        return parts.first(where: { $0.contains(".") && !$0.hasPrefix(".") })
    }

    public func cachedIcon(for bundleIdentifier: String) -> UIImage? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return memoryCache.object(forKey: bundleIdentifier as NSString)
    }

    public func loadIcon(for bundleIdentifier: String, bundleURL: URL? = nil) async -> UIImage? {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let mem = memoryCache.object(forKey: trimmed as NSString) {
            return mem
        }

        return await withCheckedContinuation { continuation in
            diskQueue.async {
                if let mem = self.memoryCache.object(forKey: trimmed as NSString) {
                    continuation.resume(returning: mem)
                    return
                }

                // 1. Check persistent PNG cache on disk (works even after app is uninstalled or on Google Drive / WebDAV tab)
                if let diskFile = self.diskFileURL(for: trimmed),
                   let data = try? Data(contentsOf: diskFile),
                   let diskImg = UIImage(data: data) {
                    self.memoryCache.setObject(diskImg, forKey: trimmed as NSString)
                    continuation.resume(returning: diskImg)
                    return
                }

                // 2. Try SpringBoard / MobileCoreServices runtime icon renderer (handles AssetCatalog .car & System apps)
                if let sbImg = self.fetchSpringBoardIcon(for: trimmed) {
                    self.memoryCache.setObject(sbImg, forKey: trimmed as NSString)
                    self.saveToDisk(image: sbImg, bundleIdentifier: trimmed)
                    continuation.resume(returning: sbImg)
                    return
                }

                // 3. Fallback to reading PNG files directly from the .app bundle
                let resolvedBundleURL = bundleURL ?? self.resolveBundleURL(for: trimmed)
                if let url = resolvedBundleURL, let bundleImg = self.fetchBundleIcon(from: url) {
                    self.memoryCache.setObject(bundleImg, forKey: trimmed as NSString)
                    self.saveToDisk(image: bundleImg, bundleIdentifier: trimmed)
                    continuation.resume(returning: bundleImg)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func diskFileURL(for bundleIdentifier: String) -> URL? {
        guard let dir = diskDirectory else { return nil }
        let safe = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).png")
    }

    private func saveToDisk(image: UIImage, bundleIdentifier: String) {
        guard let url = diskFileURL(for: bundleIdentifier),
              let pngData = image.pngData() else { return }
        try? pngData.write(to: url, options: .atomic)
    }

    private func fetchSpringBoardIcon(for bundleIdentifier: String) -> UIImage? {
        autoreleasepool {
            let sel = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
            guard UIImage.responds(to: sel),
                  let imp = UIImage.method(for: sel) else {
                return nil
            }
            typealias IconFn = @convention(c) (AnyObject, Selector, NSString, Int32, CGFloat) -> UIImage?
            let fn = unsafeBitCast(imp, to: IconFn.self)
            let scale: CGFloat = 2.0
            // format 2 = 60pt home-screen squircle icon; fallback format 0 if nil
            if let img = fn(UIImage.self, sel, bundleIdentifier as NSString, 2, scale) {
                return img
            }
            if let img = fn(UIImage.self, sel, bundleIdentifier as NSString, 0, scale) {
                return img
            }
            return nil
        }
    }

    private func resolveBundleURL(for bundleIdentifier: String) -> URL? {
        lock.lock()
        if let cached = bundleURLCache[bundleIdentifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let defaultSel = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultSel),
              let workspace = workspaceClass.perform(defaultSel)?.takeUnretainedValue() as? NSObject else {
            return nil
        }

        let proxySel = NSSelectorFromString("applicationProxyForIdentifier:")
        let allSel = NSSelectorFromString("allInstalledApplications")

        var foundURL: URL? = nil
        if workspace.responds(to: proxySel),
           let proxy = workspace.perform(proxySel, with: bundleIdentifier)?.takeUnretainedValue() as? NSObject {
            foundURL = extractURL(from: proxy, selectorName: "bundleURL")
        } else if workspace.responds(to: allSel),
                  let list = workspace.perform(allSel)?.takeUnretainedValue() as? [NSObject] {
            for proxy in list {
                let bidSel = NSSelectorFromString("applicationIdentifier")
                if proxy.responds(to: bidSel),
                   let bid = proxy.perform(bidSel)?.takeUnretainedValue() as? String,
                   bid == bundleIdentifier {
                    foundURL = extractURL(from: proxy, selectorName: "bundleURL")
                    break
                }
            }
        }

        if let url = foundURL {
            lock.lock()
            bundleURLCache[bundleIdentifier] = url
            lock.unlock()
        }
        return foundURL
    }

    private func extractURL(from object: NSObject, selectorName: String) -> URL? {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel),
              let raw = object.perform(sel)?.takeUnretainedValue() else {
            return nil
        }
        if let url = raw as? URL { return url }
        if let str = raw as? String, !str.isEmpty { return URL(fileURLWithPath: str) }
        return nil
    }

    private func fetchBundleIcon(from bundleURL: URL) -> UIImage? {
        let fm = FileManager.default
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        var candidates: [String] = []

        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if let icons = plist["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                candidates.append(contentsOf: files.reversed())
            }
            if let files = plist["CFBundleIconFiles"] as? [String] {
                candidates.append(contentsOf: files.reversed())
            }
            if let single = plist["CFBundleIconFile"] as? String {
                candidates.append(single)
            }
        }

        candidates.append(contentsOf: [
            "AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon76x76@2x~ipad",
            "AppIcon", "Icon-60@3x", "Icon-60@2x", "Icon@2x", "Icon"
        ])

        for base in candidates {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let variants = trimmed.lowercased().hasSuffix(".png")
                ? [trimmed]
                : ["\(trimmed)@3x.png", "\(trimmed)@2x.png", "\(trimmed).png", "\(trimmed)60x60@3x.png", "\(trimmed)60x60@2x.png"]
            for name in variants {
                let candidateURL = bundleURL.appendingPathComponent(name)
                if fm.fileExists(atPath: candidateURL.path),
                   let img = UIImage(contentsOfFile: candidateURL.path) {
                    return img
                }
            }
        }
        return nil
    }
}

// MARK: - Reusable SwiftUI App Icon View
public struct AppIconView: View {
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let isSystemApp: Bool
    public let fallbackSystemName: String
    public let fallbackColor: Color
    public let size: CGFloat

    @State private var loadedImage: UIImage? = nil

    public init(
        bundleIdentifier: String?,
        bundleURL: URL? = nil,
        isSystemApp: Bool = false,
        fallbackSystemName: String = "app.fill",
        fallbackColor: Color = .blue,
        size: CGFloat = 40
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.isSystemApp = isSystemApp
        self.fallbackSystemName = isSystemApp ? "gearshape.fill" : fallbackSystemName
        self.fallbackColor = isSystemApp ? .gray : fallbackColor
        self.size = size
        if let bid = bundleIdentifier, !bid.isEmpty {
            _loadedImage = State(initialValue: AppIconCache.shared.cachedIcon(for: bid))
        }
    }

    private var cornerRadius: CGFloat {
        max(6, size * 0.22)
    }

    public var body: some View {
        Group {
            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.54))
                    .foregroundColor(fallbackColor)
                    .frame(width: size, height: size)
                    .background(Color(UIColor.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .task(id: bundleIdentifier ?? "") {
            guard let bid = bundleIdentifier, !bid.isEmpty else { return }
            if loadedImage == nil {
                loadedImage = await AppIconCache.shared.loadIcon(for: bid, bundleURL: bundleURL)
            }
        }
    }
}
