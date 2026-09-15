import CommonCrypto
import Foundation

/// Finds a V380 cloud relay server for a device, the same way the V380 app does when off-LAN.
/// Endpoint and signing scheme from github.com/PyanSofyan/V380Decoder DispatchRelayServer.
public enum CloudDispatch {
    private static let url = URL(string: "http://dispa1.av380.net:8001/api/v1/get_stream_server")!

    struct Request: Encodable { let dev_id: UInt32; let platform: Int; let timestamp: Int; let sign: String }
    struct Response: Decodable { let code: Int; let data: [Server]? }
    struct Server: Decodable { let ip: String }

    /// Returns candidate relay IPs (already sanity-checked for a reachable port 8800), best first.
    /// Blocks; call off the main thread. `platform` 10001 = normal device, 20001 = multi-lens/pano.
    public static func relayIPs(deviceId: UInt32, platform: Int = 10001, timeout: TimeInterval = 10) throws -> [String] {
        let ts = Int(Date().timeIntervalSince1970)
        let sign = sha1("dev_id=\(deviceId)&platform=\(platform)&timestamp=\(ts)hsdata2022")
        let body = try JSONEncoder().encode(Request(dev_id: deviceId, platform: platform, timestamp: ts, sign: sign))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = timeout

        let (data, response) = try syncData(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw V380Error.badResponse("dispatch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.code == 2000, let servers = decoded.data, !servers.isEmpty else {
            throw V380Error.badResponse("dispatch code \(decoded.code)")
        }
        return servers.map(\.ip)
    }

    private static func sha1(_ s: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        Array(s.utf8).withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(s.utf8.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// URLSession without async/await, to fit the session's blocking-thread model.
    private static func syncData(for req: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, let response { result = .success((data, response)) }
            else { result = .failure(V380Error.badResponse("empty dispatch response")) }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result!.get()
    }
}
