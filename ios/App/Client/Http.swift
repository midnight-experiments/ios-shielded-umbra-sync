// The client's requests to the module's API (client/http.ts). Every exchange is kept (method, path, status, sizes,
// time, and the bodies up to a limit) for the app's request viewer. A request carries nothing that depends on the
// wallet beyond what PIR hides.

import Foundation

struct Exchange: Identifiable {
    let id: Int
    let method: String
    let path: String
    let status: Int
    let requestBytes: Int
    let responseBytes: Int
    let ms: Double
    let requestHead: Data    // the first bytes of the request body
    let responseHead: Data   // the first bytes of the response body
    let responseHeaders: [String: String]
}

final class PssHttp: @unchecked Sendable {
    let origin: URL
    private let session: URLSession
    private let lock = NSLock()
    private var log: [Exchange] = []
    private var nextId = 1
    /// Bytes of each body kept for the viewer.
    var keepBytes = 4096

    init(origin: URL) {
        self.origin = origin
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    var exchanges: [Exchange] { lock.withLock { log } }
    func takeExchanges(since id: Int) -> [Exchange] { lock.withLock { log.filter { $0.id > id } } }
    var lastId: Int { lock.withLock { nextId - 1 } }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let t = nowMs()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClientError.invalid("the server at \(origin.absoluteString) is unreachable (\(method) \(path)): \(error.localizedDescription)")
        }
        let ms = nowMs() - t
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalid("not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        lock.withLock {
            log.append(Exchange(id: nextId, method: method, path: path, status: http.statusCode, requestBytes: body?.count ?? 0,
                                responseBytes: data.count, ms: ms, requestHead: body?.prefix(keepBytes) ?? Data(),
                                responseHead: data.prefix(keepBytes), responseHeaders: headers))
            nextId += 1
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(decoding: data.prefix(400), as: UTF8.self)
            if http.statusCode == 409 && text.contains("snapshot-replaced") { throw ClientError.snapshotReplaced(text) }
            throw ClientError.http(http.statusCode, "\(method) \(path): \(text)")
        }
        return (data, http)
    }

    /// The manifest's bytes and the snapshot identifier the server names.
    func manifest() async throws -> (bytes: Data, servedId: String?) {
        let (d, r) = try await request("GET", Wire.Route.manifest)
        return (d, r.value(forHTTPHeaderField: "Pss-Snapshot-Id"))
    }

    /// An artifact by digest, checked against its size and SHA-256.
    func blob(_ ref: ArtifactRef) async throws -> Data {
        let (d, _) = try await request("GET", Wire.Route.blob + ref.digest)
        guard d.count == ref.size, d.sha256.hex == ref.digest else {
            throw ClientError.invalid("blob \(ref.digest.prefix(12))…: got \(d.count) bytes with SHA-256 \(d.sha256.hex.prefix(12))…")
        }
        return d
    }

    func tail() async throws -> Data { try await request("GET", Wire.Route.tail).0 }

    func query(_ table: PirTable, body: Data) async throws -> Data { try await request("POST", Wire.Route.query(table), body: body).0 }
}
