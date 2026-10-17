import Foundation
import Network
import AppKit
import SafeSyncCore

@MainActor final class OAuthLogin {
    private var listener: NWListener?
    private var completion: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var expectedState = ""
    private var redirect = ""
    private var authorization: URL?
    func connect(_ account: CloudAccount, clientSecret: String) async throws {
        let pkce = try OAuthPKCE(); expectedState = pkce.state
        let params = NWParameters.tcp
        let port: NWEndpoint.Port = account.provider == .dropbox ? 53682 : .any
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: params)
        self.listener = listener
        let code: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { self.finish(.failure(BackupError.unsafe("인증 포트를 열 수 없습니다."))); return }
                        self.redirect = "http://127.0.0.1:\(port.rawValue)/"
                        let url = OAuthPKCE.authorizationURL(account: account, redirect: self.redirect, pkce: pkce)
                        if !NSWorkspace.shared.open(url) { self.finish(.failure(BackupError.unsafe("기본 브라우저를 열 수 없습니다."))) }
                    case .failed: self.finish(.failure(BackupError.unsafe("인증 수신 포트를 사용할 수 없습니다. 다른 연결 창을 닫고 재시도하세요.")))
                    default: break
                    }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    guard self.connections.count < 8 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.start(queue: .main); self.receive(connection, id: id, accumulated: Data())
                    }
                }
                listener.start(queue: .main)
                timeout = Task { try? await Task.sleep(for: .seconds(300)); if !Task.isCancelled { finish(.failure(BackupError.unsafe("로그인 시간이 초과되었습니다."))) } }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        let secret = try await OAuthPKCE.exchange(account: account, code: code, redirect: redirect, verifier: pkce.verifier, clientSecret: clientSecret)
        try CredentialVault.save(secret, account: account.id)
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            MainActor.assumeIsolated {
            guard let self else { return }
            var data = accumulated; if let bytes { data.append(bytes) }
            guard data.count < 16384, error == nil else { connection.cancel(); self.connections.removeValue(forKey: id); return }
            guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, accumulated: data) }; return
            }
            let first = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            var response = "400 Bad Request", result: Result<String, Error>?
            if first.count == 3, first[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + first[1]), components.path == "/" {
                let values = components.queryItems ?? []
                if values.filter({ $0.name == "state" }).count == 1, values.first(where: { $0.name == "state" })?.value == self.expectedState {
                    if let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty { response = "200 OK"; result = .success(code) }
                    else { result = .failure(BackupError.unsafe("로그인이 취소되었거나 접근 동의가 거부되었습니다.")) }
                }
            }
            let body = response == "200 OK" ? "SafeSync connected. You may close this window." : "SafeSync could not validate this login request."
            let message = "HTTP/1.1 \(response)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(message.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.connections.removeValue(forKey: id)
            if let result { self.finish(result) }
            }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }; self.completion = nil
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        completion.resume(with: result)
    }
    func cancel() { finish(.failure(CancellationError())) }
}
