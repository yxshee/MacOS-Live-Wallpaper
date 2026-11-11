import Foundation

/// One selectable scene: a built-in one drawn by the app's own code, or a
/// folder holding a shader and its licence.
struct SceneDescriptor: Equatable {
    enum Style: String, CaseIterable {
        case nature, stylised, abstract, cosy, scifi, other

        var title: String {
            switch self {
            case .nature: return "Nature"
            case .stylised: return "Stylised"
            case .abstract: return "Abstract"
            case .cosy: return "Cosy"
            case .scifi: return "Sci-Fi"
            case .other: return "Other"
            }
        }
    }

    enum Source: Equatable {
        case builtin(SceneKind)
        case shader(folder: URL)
    }

    var id: String
    var title: String
    var author: String
    var sourceURL: String
    var licence: String              // SPDX identifier
    var style: Style
    var source: Source
    var maxFPS: Float = 20
    var scale: Float = 0.5           // pixels drawn per point of screen, before the display's own scaling
    var channels: [String] = []      // up to two image files in the scene folder

    /// Free to use and adapt, but not for commercial purposes.
    var isNonCommercial: Bool { licence.uppercased().contains("-NC") }

    var credit: String { author.isEmpty ? title : "\(title) by \(author)" }
}

/// The scenes the app knows about: the two built in, those bundled in
/// `Resources/Scenes`, and any the user has put in Application Support.
final class SceneRegistry {
    static let shared = SceneRegistry(folders: SceneRegistry.standardFolders())

    static let builtins: [SceneDescriptor] = [
        SceneDescriptor(id: "horizon", title: "Horizon", author: "", sourceURL: "", licence: "MIT",
                        style: .nature, source: .builtin(.horizon)),
        SceneDescriptor(id: "nebula", title: "Nebula", author: "", sourceURL: "", licence: "MIT",
                        style: .nature, source: .builtin(.nebula)),
    ]

    /// Ids with a meaning of their own that no scene folder may take.
    static let reserved: Set<String> = ["horizon", "nebula", "video"]

    let scenes: [SceneDescriptor]
    private(set) var problems: [String] = []

    init(folders: [URL]) {
        var found = SceneRegistry.builtins
        var seen = SceneRegistry.reserved
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard FileManager.default.fileExists(atPath: entry.appendingPathComponent("scene.json").path) else { continue }
                switch SceneRegistry.load(entry) {
                case .success(let scene):
                    if seen.insert(scene.id).inserted { found.append(scene) }
                    else { problems.append("\(entry.lastPathComponent): the id is already taken") }
                case .failure(let problem):
                    problems.append("\(entry.lastPathComponent): \(problem.message)")
                }
            }
        }
        scenes = found
    }

    func scene(_ id: String) -> SceneDescriptor? { scenes.first { $0.id == id } }

    func scenes(in style: SceneDescriptor.Style) -> [SceneDescriptor] {
        scenes.filter { $0.style == style && !SceneRegistry.reserved.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func standardFolders() -> [URL] {
        var folders = [URL]()
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Scenes") { folders.append(bundled) }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            folders.append(support.appendingPathComponent("Live Wallpaper/Scenes"))
        }
        return folders
    }

    struct Problem: Error { var message: String }

    /// Reads one scene folder. The folder's name is the scene's id.
    static func load(_ folder: URL) -> Result<SceneDescriptor, Problem> {
        struct Manifest: Decodable {
            var title: String
            var author: String?
            var source: String?
            var licence: String
            var style: String?
            var maxFPS: Float?
            var scale: Float?
            var channels: [String]?
        }
        let id = folder.lastPathComponent
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .failure(Problem(message: "folder names may use only letters, digits, - and _"))
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("scene.json")) else {
            return .failure(Problem(message: "scene.json cannot be read"))
        }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch {
            return .failure(Problem(message: "scene.json is not valid: \(error.localizedDescription)"))
        }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.metal").path) else {
            return .failure(Problem(message: "main.metal is missing"))
        }
        guard !manifest.licence.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Problem(message: "scene.json must name a licence"))
        }
        let channels = manifest.channels ?? []
        guard channels.count <= 2, channels.allSatisfy({ !$0.contains("/") && !$0.hasPrefix(".") }) else {
            return .failure(Problem(message: "channels may list at most two files inside the scene folder"))
        }
        for name in channels {
            guard let size = ShaderScene.pixelSize(of: folder.appendingPathComponent(name)) else {
                return .failure(Problem(message: "\(name) is missing or is not an image"))
            }
            guard !ShaderScene.isGreyWithAlpha(folder.appendingPathComponent(name)) else {
                return .failure(Problem(message: "\(name) is grey with an alpha channel; save it as plain grey or as RGB"))
            }
            guard max(size.width, size.height) <= ShaderScene.maxChannelSide else {
                return .failure(Problem(message: "\(name) is \(size.width)×\(size.height); images may be at most \(ShaderScene.maxChannelSide) pixels a side"))
            }
        }
        return .success(SceneDescriptor(
            id: id, title: manifest.title, author: manifest.author ?? "", sourceURL: manifest.source ?? "",
            licence: manifest.licence, style: SceneDescriptor.Style(rawValue: manifest.style ?? "") ?? .other,
            source: .shader(folder: folder),
            maxFPS: min(max(manifest.maxFPS ?? 20, 1), 60), scale: min(max(manifest.scale ?? 0.5, 0.125), 2),
            channels: channels))
    }
}
