import Foundation
import Network

/// One browser callback on an ephemeral IPv4 loopback port. The provider
/// flow validates the returned URL, issuer and state before exchanging a code.
final class GatewayOAuthCallback: Sendable {
    private let listener: NWListener
    private let callbacks: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let timer: Task<Void, Never>
    let redirect: URL

    private init(listener: NWListener, port: NWEndpoint.Port, callbacks: AsyncThrowingStream<String, Error>,
                 continuation: AsyncThrowingStream<String, Error>.Continuation, timer: Task<Void, Never>) {
        self.listener = listener; self.callbacks = callbacks; self.continuation = continuation; self.timer = timer
        redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!
    }

    static func start(timeout: Duration = .seconds(300)) async throws -> GatewayOAuthCallback {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (ready, readiness) = AsyncThrowingStream<NWEndpoint.Port, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (callbacks, output) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let queue = DispatchQueue(label: "aitvaras.gateway.oauth.callback")
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { readiness.yield(port); readiness.finish() }
            case .failed, .cancelled:
                readiness.finish(throwing: GatewayOAuthError.invalidCallback)
                output.finish(throwing: GatewayOAuthError.invalidCallback)
            default: break
            }
        }
        listener.newConnectionLimit = 1
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { connection.cancel() }
            read(connection, data: Data(), output: output)
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            readiness.finish(throwing: GatewayOAuthError.timedOut)
            output.finish(throwing: GatewayOAuthError.timedOut)
            listener.cancel()
        }
        listener.start(queue: queue)
        do {
            var iterator = ready.makeAsyncIterator()
            guard let port = try await iterator.next() else { throw CancellationError() }
            return .init(listener: listener, port: port, callbacks: callbacks, continuation: output, timer: timer)
        } catch {
            listener.cancel(); timer.cancel()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        continuation.finish()
        listener.cancel()
        timer.cancel()
    }

    func receive() async throws -> URL {
        var iterator = callbacks.makeAsyncIterator()
        guard let target = try await iterator.next() else {
            try Task.checkCancellation()
            throw GatewayOAuthError.invalidCallback
        }
        guard let base = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              let url = URL(string: "http://127.0.0.1:\(base.port!)" + target) else {
            throw GatewayOAuthError.invalidCallback
        }
        return url
    }

    private static func read(_ connection: NWConnection, data: Data,
                             output: AsyncThrowingStream<String, Error>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, complete, error in
            let combined = data + (chunk ?? Data())
            if combined.count <= 8192,
               let end = combined.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: combined[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ") ?? []
                if parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
                   parts[2].hasPrefix("HTTP/1.") {
                    output.yield(String(parts[1]))
                    let body = "Return to Aitvaras to finish signing in."
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            } else if combined.count < 8192, !complete, error == nil {
                read(connection, data: combined, output: output)
                return
            }
            output.finish(throwing: GatewayOAuthError.invalidCallback)
            connection.cancel()
        }
    }
}
