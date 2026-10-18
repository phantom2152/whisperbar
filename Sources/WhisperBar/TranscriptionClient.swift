import Foundation

enum TranscriptionError: LocalizedError {
    case noAudio
    case unreachable
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No audio was captured."
        case .unreachable: return "Can’t reach the server. Is it running?"
        case .http(let code): return "The server answered with HTTP \(code)."
        case .badResponse: return "The server’s reply couldn’t be read."
        }
    }
}

/// Sends a WAV file to whisper-server's /inference endpoint.
enum TranscriptionClient {
    static func transcribe(fileURL: URL, port: Int) async throws -> String {
        guard let audio = try? Data(contentsOf: fileURL), !audio.isEmpty else { throw TranscriptionError.noAudio }

        let boundary = UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"rec.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let error as URLError where error.code != .cancelled {
            throw TranscriptionError.unreachable
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranscriptionError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw TranscriptionError.badResponse }
        return text
    }
}
