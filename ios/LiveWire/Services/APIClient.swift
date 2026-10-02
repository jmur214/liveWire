import Foundation

enum APIError: LocalizedError, Equatable {
    case badURL
    case unauthorized
    case server(Int, String)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The server URL is not valid."
        case .unauthorized: return "The API token was rejected (401)."
        case .server(let code, let msg): return "Server error \(code): \(msg)"
        case .decoding(let msg): return "Unexpected response: \(msg)"
        case .network(let msg): return msg
        }
    }
}

/// Thin async/await client for the B3 contracts. A value type: AppModel rebuilds it
/// whenever the server URL or token changes.
struct APIClient: Sendable {
    let baseURL: URL
    let token: String

    init?(serverURL: String, token: String) {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()), url.host != nil else {
            return nil
        }
        self.baseURL = url
        self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: Requests

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> URLRequest {
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var comps = URLComponents(url: baseURL.appending(path: rel), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func data(for req: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("No HTTP response") }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        default:
            let msg = (try? Self.decoder.decode(APIErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(http.statusCode, msg)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let d = try await data(for: request(path, query: query))
        do {
            return try Self.decoder.decode(T.self, from: d)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    private func post<B: Encodable, T: Decodable>(_ type: T.Type, _ path: String, body: B) async throws -> T {
        let payload = try Self.encoder.encode(body)
        let d = try await data(for: request(path, method: "POST", body: payload))
        do {
            return try Self.decoder.decode(T.self, from: d)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    // MARK: Endpoints (DESIGN.md B3)

    func health() async throws -> Health {
        try await get(Health.self, "/api/health")
    }

    func cities() async throws -> [City] {
        try await get(CitiesResponse.self, "/api/cities").cities
    }

    func incidents(hours: Double = 2, agencies: [Agency]? = nil) async throws -> [Incident] {
        var q = [URLQueryItem(name: "hours", value: String(format: "%.2f", hours))]
        if let agencies, !agencies.isEmpty {
            q.append(URLQueryItem(name: "agencies", value: agencies.map(\.rawValue).joined(separator: ",")))
        }
        return try await get(IncidentsResponse.self, "/api/incidents", query: q).incidents
    }

    func incident(_ id: Int) async throws -> Incident {
        try await get(Incident.self, "/api/incidents/\(id)")
    }

    func transmissions(sinceId: Int? = nil, limit: Int = 200) async throws -> TransmissionsResponse {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let sinceId { q.append(URLQueryItem(name: "since_id", value: String(sinceId))) }
        return try await get(TransmissionsResponse.self, "/api/transmissions", query: q)
    }

    func report(incidentId: Int, reason: String = "wrong_location") async throws {
        _ = try await post(OKResponse.self, "/api/report", body: ReportBody(incidentId: incidentId, reason: reason))
    }

    func registerDevice(_ reg: DeviceRegistration) async throws {
        _ = try await post(OKResponse.self, "/api/device", body: reg)
    }

    func streamRequest(sinceId: Int?) -> URLRequest {
        var q: [URLQueryItem] = []
        if let sinceId { q.append(URLQueryItem(name: "since_id", value: String(sinceId))) }
        var r = request("/api/stream", query: q)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 90   // pings arrive every 15 s; anything quieter is a dead connection
        return r
    }

    func audioURL(_ file: String) -> URL {
        baseURL.appending(path: "audio/\(file)")
    }

    func fetchAudio(_ file: String) async throws -> Data {
        var r = URLRequest(url: audioURL(file))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await data(for: r)
    }
}
