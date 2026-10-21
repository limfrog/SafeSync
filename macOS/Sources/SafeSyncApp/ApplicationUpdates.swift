import AppKit
import SwiftUI
import CryptoKit
import SafeSyncCore

private struct UpdateRelease: Codable, Sendable {
    let version: String
    let url: String
    let sha256: String
    let size: Int64
    let notes: String
}
private struct UpdateCatalog: Decodable { let schemaVersion: Int; let macOS: UpdateRelease? }
private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class ApplicationUpdates: ObservableObject {
    static let shared = ApplicationUpdates()
    @Published private(set) var availableVersion: String?
    @Published private(set) var status = "아직 업데이트를 확인하지 않았습니다."
    @Published private(set) var notes = ""
    @Published private(set) var busy = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var downloaded: URL?
    private var release: UpdateRelease?
    private var transfer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastNotice = ""
    private var automatic = false
    private var autoCheck: Bool { UserDefaults.standard.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true }
    private var autoDownload: Bool { UserDefaults.standard.object(forKey: "automaticallyDownloadUpdates") as? Bool ?? true }
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                if let self, self.autoCheck { self.check() }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }
    func check(manual: Bool = false) {
        if manual { show() }
        run(automatic: !manual) {
            self.status = "GitHub의 새 버전을 확인하고 있습니다…"
            let found = try await Self.latest(current: AppInformation.version)
            guard let found else {
                self.availableVersion = nil; self.release = nil; self.downloaded = nil
                self.status = "현재 버전이 최신입니다."; return
            }
            if self.release?.version != found.version { self.downloaded = nil }
            self.release = found; self.availableVersion = found.version; self.notes = found.notes
            self.status = "새 버전 \(found.version)을 사용할 수 있습니다."
            if self.lastNotice != found.version {
                self.lastNotice = found.version
                if NSApp.isActive { self.show() }
            }
            if self.autoDownload { try await self.downloadRelease(found) }
        }
    }
    func download() {
        guard let release else { return }
        run { try await self.downloadRelease(release) }
    }
    func cancel() { transfer?.cancel() }
    func preferencesChanged() { if automatic && (!autoCheck || !autoDownload) { cancel() } }
    func show() { Store.shared.openAppWindow?("updates") }
    func reveal() { if let downloaded { NSWorkspace.shared.activateFileViewerSelecting([downloaded]) } }
    private func run(automatic: Bool = false, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; fraction = 0; self.automatic = automatic
        transfer = Task {
            defer { busy = false; self.automatic = false; transfer = nil }
            do { try await action() }
            catch is CancellationError { status = "업데이트 작업을 취소했습니다." }
            catch { status = "업데이트 확인/다운로드 실패: \(error.localizedDescription)" }
        }
    }
    private func downloadRelease(_ release: UpdateRelease) async throws {
        downloaded = nil; status = "다운로드 및 무결성 검증 중…"
        let directory = Storage.applicationDirectory.appendingPathComponent("app-updates-v1", isDirectory: true)
        let file = try await Self.download(release, directory: directory) { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.busy, self.downloaded == nil else { return }
                self.fraction = Double(done) / Double(max(1, total))
            }
        }
        try Task.checkCancellation(); downloaded = file; fraction = 1
        status = "다운로드와 체크섬 검증이 완료됐습니다. ‘다운로드한 ZIP 열기’를 눌러 업데이트하세요."
    }
    nonisolated private static func error(_ text: String) -> NSError { NSError(domain: "SafeSync.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    nonisolated private static func parts(_ version: String) throws -> [Int] {
        guard version.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil,
              version.count <= 40 else { throw error("잘못된 업데이트 버전입니다.") }
        let values = version.split(separator: ".").compactMap { Int($0) }
        guard values.count == 3 else { throw error("잘못된 업데이트 버전입니다.") }; return values
    }
    nonisolated private static func validated(_ release: UpdateRelease) throws -> URL {
        _ = try parts(release.version)
        let expected = "https://raw.githubusercontent.com/limfrog/SafeSync/main/dist/SafeSync-macOS-\(release.version)-universal.zip"
        guard release.url == expected, let url = URL(string: expected), release.size > 0, release.size <= 1_073_741_824,
              release.sha256.range(of: #"\A[a-fA-F0-9]{64}\z"#, options: .regularExpression) != nil, release.notes.count <= 8000
        else { throw error("공식 저장소의 검증 가능한 업데이트가 아닙니다.") }; return url
    }
    nonisolated private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 1200
        return URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }
    nonisolated private static func latest(current: String) async throws -> UpdateRelease? {
        let session = session(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/limfrog/SafeSync/main/updates/latest.json")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 25
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 65536 else { throw error("업데이트 정보를 확인할 수 없습니다.") }
        var data = Data()
        for try await byte in bytes { if data.count >= 65536 { throw error("업데이트 정보가 너무 큽니다.") }; data.append(byte) }
        let catalog = try JSONDecoder().decode(UpdateCatalog.self, from: data)
        guard catalog.schemaVersion == 1 else { throw error("지원하지 않는 업데이트 정보입니다.") }
        guard let release = catalog.macOS else { return nil }; _ = try validated(release)
        return try parts(current).lexicographicallyPrecedes(parts(release.version)) ? release : nil
    }
    nonisolated private static func verify(_ file: URL, release: UpdateRelease) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == release.size else { return false }
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }; var hash = SHA256()
        while let data = try input.read(upToCount: 131072), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined().lowercased() == release.sha256.lowercased()
    }
    nonisolated private static func download(_ release: UpdateRelease, directory: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let url = try validated(release); let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw error("연결된 업데이트 폴더는 사용하지 않습니다.") }
        let final = directory.appendingPathComponent(url.lastPathComponent)
        if try verify(final, release: release) { return final }
        let partial = directory.appendingPathComponent(UUID().uuidString + ".part")
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw error("업데이트 임시 파일을 만들지 못했습니다.") }
        defer { try? fm.removeItem(at: partial) }
        let session = session(); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength < 0 || response.expectedContentLength == release.size else { throw error("업데이트 파일 크기가 게시 정보와 다릅니다.") }
        let output = try FileHandle(forWritingTo: partial); defer { try? output.close() }
        var buffer = Data(); buffer.reserveCapacity(131072); var total: Int64 = 0
        for try await byte in bytes {
            if total >= release.size { throw error("업데이트 파일이 게시된 크기를 초과했습니다.") }
            buffer.append(byte); total += 1
            if buffer.count >= 131072 { try Task.checkCancellation(); try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true); progress(total, release.size) }
        }
        if !buffer.isEmpty { try output.write(contentsOf: buffer) }; try output.synchronize(); try output.close()
        guard try verify(partial, release: release) else { throw error("업데이트 체크섬이 다릅니다. 설치하지 않았습니다.") }
        if fm.fileExists(atPath: final.path) { _ = try fm.replaceItemAt(final, withItemAt: partial) }
        else { try fm.moveItem(at: partial, to: final) }
        return final
    }
}

struct AppUpdateView: View {
    @ObservedObject private var updates = ApplicationUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SafeSync 업데이트").font(.title.bold())
            Text("현재 버전: \(AppInformation.version)").foregroundStyle(.secondary)
            if let version = updates.availableVersion { Text("새 버전: \(version)").font(.headline) }
            Text(updates.status).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: updates.fraction)
            ScrollView { Text(updates.notes).frame(maxWidth: .infinity, alignment: .leading) }
            Text("다운로드한 ZIP을 열고, 진행 중인 백업을 마친 뒤 기존 SafeSync를 종료하여 새 앱으로 교체하세요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("업데이트 확인") { updates.check(manual: true) }.disabled(updates.busy)
                Button("다운로드") { updates.download() }.disabled(updates.busy || updates.availableVersion == nil)
                Button("다운로드한 ZIP 열기") { updates.reveal() }.disabled(updates.downloaded == nil)
                Button("취소") { updates.cancel() }.disabled(!updates.busy)
            }
        }.padding(24).frame(width: 610, height: 380)
    }
}
