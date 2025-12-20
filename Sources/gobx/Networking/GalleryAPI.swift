import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AppConfig: Codable {
    let baseUrl: String?
    let profile: Profile?

    struct Profile: Codable {
        let id: String
        let name: String
        let xProfile: String?

        static let defaultAuthor = Profile(
            id: "user_mj95qm9x_adu1a3a11",
            name: "DreamingDragon588",
            xProfile: "davelindon10"
        )
    }
}

func loadConfig() -> AppConfig? {
    guard let data = try? Data(contentsOf: GobxPaths.configURL) else { return nil }
    return try? JSONDecoder().decode(AppConfig.self, from: data)
}

private struct HTTPResponse {
    let statusCode: Int
    let body: Data
}

private func runHTTP(url: URL, method: String, jsonBody: Data?, timeoutSec: TimeInterval) async -> HTTPResponse? {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = max(1.0, timeoutSec)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let jsonBody {
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = min(10.0, max(1.0, timeoutSec))
    config.timeoutIntervalForResource = max(1.0, timeoutSec)

    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    } catch {
        return nil
    }
}

struct SubmissionResponse: Codable {
    let accepted: Bool
    let rank: Int?
    let message: String?
}

func submitScore(seed: UInt64, score: Double, config: AppConfig) async -> SubmissionResponse? {
    guard let profile = config.profile else { return nil }
    let urlStr = (config.baseUrl ?? "https://www.echohive.ai") + "/gallery-of-babel/api/submit"
    guard let url = URL(string: urlStr) else { return nil }

    var body: [String: Any] = [
        "seed": seed,
        "score": score,
        "generator_version": "2.0",
        "width": 128,
        "height": 128,
        "discoverer_id": profile.id,
        "discoverer_name": profile.name,
    ]
    if let x = profile.xProfile {
        body["discoverer_x_profile"] = x
    } else {
        body["discoverer_x_profile"] = NSNull()
    }

    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

    guard let res = await runHTTP(url: url, method: "POST", jsonBody: bodyData, timeoutSec: 15) else { return nil }

    if let decoded = try? JSONDecoder().decode(SubmissionResponse.self, from: res.body) {
        return decoded
    }
    let msg = String(data: res.body, encoding: .utf8) ?? ""
    if res.statusCode != 200 {
        return SubmissionResponse(accepted: false, rank: nil, message: "HTTP \(res.statusCode): \(msg)")
    }
    return SubmissionResponse(accepted: false, rank: nil, message: "Decode error: \(msg)")
}

struct TopResponse: Decodable {
    struct Image: Decodable {
        let seed: UInt64
        let score: Double
    }

    let images: [Image]
}

func fetchTop(limit: Int, config: AppConfig, uniqueUsers: Bool = false) async -> TopResponse? {
    let base = config.baseUrl ?? "https://www.echohive.ai"
    let unique = uniqueUsers ? "1" : "0"
    let urlStr = base + "/gallery-of-babel/api/top?limit=\(limit)&unique_users=\(unique)"
    guard let url = URL(string: urlStr) else { return nil }
    guard let res = await runHTTP(url: url, method: "GET", jsonBody: nil, timeoutSec: 15) else { return nil }
    guard res.statusCode == 200 else { return nil }
    return try? JSONDecoder().decode(TopResponse.self, from: res.body)
}
