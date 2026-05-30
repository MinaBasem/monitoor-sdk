import Foundation

enum HTTPResult {
    case success(IngestResponse)
    case rateLimited(retryAfter: TimeInterval)
    case serverError(attempt: Int)
    case clientError
}

enum CrashHTTPResult {
    case success(CrashResponse)
    case failure
}

final class HTTPClient {
    private let session: URLSession
    private let encoder = BatchEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Ingest

    func send(batch: OutboundBatch, apiKey: String, ingestURL: URL, attempt: Int) async -> HTTPResult {
        guard !batch.events.isEmpty else { return .success(IngestResponse(accepted: 0, rejected: 0, errors: [])) }

        let ingestBatch = IngestBatch(sdkVersion: MonitoorSDK.version, batch: batch.events)
        let (body, compressed): (Data, Bool)
        do {
            (body, compressed) = try encoder.encode(batch: ingestBatch)
        } catch {
            return .clientError
        }

        var request = URLRequest(url: ingestURL.appendingPathComponent("v1/ingest"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MonitoorSDK.version, forHTTPHeaderField: "X-Monitoor-SDK-Version")
        if compressed {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.httpBody = body
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .serverError(attempt: attempt) }

            switch http.statusCode {
            case 200...299:
                let parsed = (try? decoder.decode(IngestResponse.self, from: data))
                    ?? IngestResponse(accepted: batch.count, rejected: 0, errors: [])
                return .success(parsed)

            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? 60.0
                return .rateLimited(retryAfter: retryAfter)

            case 400...499:
                return .clientError

            default:
                return .serverError(attempt: attempt)
            }
        } catch {
            return .serverError(attempt: attempt)
        }
    }

    // MARK: - Crashes

    func sendCrash(report: CrashReport, apiKey: String, ingestURL: URL) async -> CrashHTTPResult {
        guard let body = try? JSONEncoder().encode(report) else { return .failure }

        var request = URLRequest(url: ingestURL.appendingPathComponent("v1/crashes"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(MonitoorSDK.version, forHTTPHeaderField: "X-Monitoor-SDK-Version")
        request.httpBody = body
        request.timeoutInterval = 30

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let parsed = try? decoder.decode(CrashResponse.self, from: data)
        else { return .failure }

        return .success(parsed)
    }
}
