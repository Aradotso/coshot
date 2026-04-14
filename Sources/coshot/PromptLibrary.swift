import Foundation

struct Prompt: Identifiable, Codable, Hashable {
    var id: String { key + name }
    let key: String
    let name: String
    let template: String
    var model: String? = nil
}

struct PromptLibrary: Codable {
    var prompts: [Prompt]

    static var promptsFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("coshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("prompts.json")
    }

    static func load() -> PromptLibrary {
        let url = promptsFileURL
        if let data = try? Data(contentsOf: url),
           let lib = try? JSONDecoder().decode(PromptLibrary.self, from: data) {
            return lib
        }
        if let bundled = Bundle.module.url(forResource: "prompts.default", withExtension: "json"),
           let data = try? Data(contentsOf: bundled),
           let lib = try? JSONDecoder().decode(PromptLibrary.self, from: data) {
            try? data.write(to: url)
            return lib
        }
        return PromptLibrary(prompts: [])
    }
}
