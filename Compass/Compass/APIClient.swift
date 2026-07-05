//
//  APIClient.swift
//  Compass
//
//  Thin URLSession wrapper around the server API (CLAUDE.md §5).
//
//  NOTE: `baseURL` points at the local dev server. From the iOS Simulator,
//  http://localhost:4000 reaches the Node server running on your Mac. When you
//  deploy to your domain, change this to https://your-domain and the plain-HTTP
//  ATS exception in Info.plist is no longer needed.
//

import Foundation

struct APIErrorResponse: Decodable { let error: String }

enum APIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

final class APIClient {
    // Simulator talks to the Node server on your Mac over localhost. A real
    // device can't reach "localhost", so it uses your deployed server.
    //
    // 👉 TODO: replace YOUR-DOMAIN with your Contabo domain once it's live.
    //    It MUST be https:// — iOS App Transport Security blocks plain http on
    //    a public host (free TLS via Let's Encrypt / nginx; see server/DEPLOY.md).
    #if targetEnvironment(simulator)
    var baseURL = URL(string: "http://localhost:4000")!
    #else
    var baseURL = URL(string: "https://YOUR-DOMAIN.com")!
    #endif
    var token: String?

    /// Perform a request and return the raw response body. Throws APIError with
    /// a human-readable message on network failure or non-2xx status.
    func send(_ path: String,
              method: String = "GET",
              json: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.message("Bad URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.message("Can't reach the server. Is `node server.js` running? (\(error.localizedDescription))")
        }

        guard let http = resp as? HTTPURLResponse else {
            throw APIError.message("No response from server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let e = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.message(e.error)
            }
            throw APIError.message("Server error (\(http.statusCode)).")
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
