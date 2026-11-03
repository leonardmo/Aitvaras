import Foundation

/// Private connector traffic should not enter Foundation's shared cookie,
/// credential or response caches. Callers can still inject a custom session
/// for deterministic tests.
public enum ConnectorHTTPSession {
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

/// A response body that exceeded the connector's explicit memory budget.
/// Keep this error URL-free: connector URLs can contain private hostnames or
/// credentials, and the caller may surface the description in the UI.
struct HTTPResponseTooLargeError: Error, LocalizedError, Sendable {
    let maximumBytes: Int

    var errorDescription: String? {
        "The remote response exceeded the \(maximumBytes)-byte safety limit."
    }
}

/// Reads an HTTP response incrementally and cancels the underlying task as
/// soon as its body exceeds the caller's budget. `URLSession.data(for:)`
/// buffers the complete response before returning, so truncating afterwards
/// does not protect the app from an unexpectedly large or chunked response.
enum BoundedHTTP {
    static func data(
        for request: URLRequest,
        using session: URLSession,
        maximumBytes: Int,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        precondition(maximumBytes > 0)
        let (bytes, response) = try await session.bytes(
            for: request, delegate: delegate)

        do {
            try Task.checkCancellation()
            let expected = response.expectedContentLength
            guard expected <= 0 || expected <= Int64(maximumBytes) else {
                throw HTTPResponseTooLargeError(maximumBytes: maximumBytes)
            }

            var data = Data()
            if expected > 0 {
                data.reserveCapacity(Int(expected))
            }
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw HTTPResponseTooLargeError(maximumBytes: maximumBytes)
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            // AsyncBytes exposes its data task, letting us stop both declared
            // and chunked oversized transfers instead of merely discarding
            // bytes that Foundation continues to download.
            bytes.task.cancel()
            throw error
        }
    }

    static func data(
        from url: URL,
        using session: URLSession,
        maximumBytes: Int,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, URLResponse) {
        try await data(
            for: URLRequest(url: url),
            using: session,
            maximumBytes: maximumBytes,
            delegate: delegate)
    }
}
