import Foundation

enum CerebrasError: LocalizedError {
    case missingKey
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Set your Cerebras API key from the menu bar"
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

struct CerebrasClient {
    let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!

    func stream(
        model: String,
        system: String,
        user: String,
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard let apiKey = resolveKey() else { throw CerebrasError.missingKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CerebrasError.http(0, "No response")
        }
        if http.statusCode != 200 {
            var buffer = ""
            for try await line in bytes.lines { buffer += line + "\n"; if buffer.count > 400 { break } }
            throw CerebrasError.http(http.statusCode, buffer)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty else { continue }
            onDelta(content)
        }
    }

    private func resolveKey() -> String? {
        if let k = Keychain.load(), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["COSHOT_CEREBRAS_KEY"], !k.isEmpty { return k }
        return nil
    }
}
