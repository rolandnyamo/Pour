import Foundation

struct InstalledApplication {
    let url: URL
    let bundleIdentifier: String?
}

/// Legacy history recorded display names but not bundle identifiers. This local
/// index reconnects those names to installed app bundles for stable grouping and
/// native icons without using a deprecated Launch Services lookup.
enum InstalledApplicationResolver {
    private static let applicationsByName: [String: InstalledApplication] = {
        let fileManager = FileManager.default
        let roots = [
            fileManager.urls(for: .applicationDirectory, in: .userDomainMask),
            fileManager.urls(for: .applicationDirectory, in: .localDomainMask),
            fileManager.urls(for: .applicationDirectory, in: .systemDomainMask)
        ].flatMap { $0 }

        var result: [String: InstalledApplication] = [:]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let bundle = Bundle(url: url)
                let application = InstalledApplication(url: url, bundleIdentifier: bundle?.bundleIdentifier)
                let names = [
                    url.deletingPathExtension().lastPathComponent,
                    bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

                for name in names where !name.isEmpty {
                    result[name.lowercased()] = result[name.lowercased()] ?? application
                }
            }
        }
        return result
    }()

    static func application(named appName: String) -> InstalledApplication? {
        applicationsByName[appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
