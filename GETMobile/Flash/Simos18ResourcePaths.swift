import Foundation

/// iOS equivalent of Communication/Simos18/Simos18ResourcePaths.cs. Much
/// simpler than the Windows version's folder-next-to-exe searching, since
/// iOS just bundles everything under project.yml's `sources: path: GETMobile`
/// into the app bundle automatically (same mechanism that already bundles
/// Assets.xcassets) - Bundle.main resolves it directly, no fallback search needed.
enum Simos18ResourcePaths {
    enum ResourceError: Error, LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let name): return "Bundled resource \"\(name)\" not found in the app bundle."
            }
        }
    }

    static func boxCodesCsvPath() throws -> String {
        guard let url = Bundle.main.url(forResource: "box_codes", withExtension: "csv") else {
            throw ResourceError.notFound("box_codes.csv")
        }
        return url.path
    }

    /// For Phase 3: the unlock patch binaries (simos18_1_unlock_patch.bin,
    /// simos18_10_unlock_patch.bin) aren't bundled yet - only needed once the
    /// UDS unlock sequencing that actually consumes them is built.
    static func unlockPatchPath(_ fileName: String) throws -> String {
        let nameWithoutExt = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: nameWithoutExt, withExtension: ext) else {
            throw ResourceError.notFound(fileName)
        }
        return url.path
    }
}
