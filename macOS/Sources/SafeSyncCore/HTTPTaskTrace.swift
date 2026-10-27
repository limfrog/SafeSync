import Foundation

/// Per-task delegate: no swizzling and no URL/header/address payloads. The
/// captured run survives URLSession's delegate queue and parallel uploads.
final class HTTPTaskTrace: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let context = OperationLog.run
    private let operation: String
    private let id = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var lastProgress = ProcessInfo.processInfo.systemUptime, lastReport = 0.0
    private var sent: Int64 = 0, expected: Int64 = 0
    private var timer: DispatchSourceTimer?
    init(operation: String) {
        self.operation = operation; super.init()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.heartbeat() }; self.timer = timer; timer.resume()
    }
    private func emit(_ event: String, bytes: Int64? = nil, ms: Double? = nil, detail: String? = nil) {
        OperationLog.$run.withValue(context) {
            OperationLog.event(event, operation, bytes: bytes, ms: ms, detail: "request=\(id);\(detail ?? "")")
        }
    }
    func finish() { lock.lock(); let active = timer; timer = nil; lock.unlock(); active?.cancel() }
    deinit { finish() }
    private func heartbeat() {
        lock.lock(); let count = sent, expected = expected, idle = ProcessInfo.processInfo.systemUptime - lastProgress; lock.unlock()
        emit("transfer.wait", bytes: count, ms: idle * 1000, detail: "expectedBytes=\(expected);elapsedMs=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); sent = totalBytesSent; expected = totalBytesExpectedToSend; lastProgress = now
        let report = now - lastReport >= 1 || totalBytesSent == totalBytesExpectedToSend
        if report { lastReport = now }; lock.unlock()
        if report { emit("transfer.progress", bytes: totalBytesSent, ms: (now - started) * 1000, detail: "expectedBytes=\(totalBytesExpectedToSend)") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        func ms(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end, end >= start else { return "unavailable" }
            return String(format: "%.3f", end.timeIntervalSince(start) * 1000)
        }
        for (index, value) in metrics.transactionMetrics.enumerated() {
            let proto = ["h2", "h3", "http/1.1", "http/1.0"].contains(value.networkProtocolName ?? "") ? value.networkProtocolName! : "other"
            emit("http.metrics", bytes: value.countOfRequestBodyBytesSent,
                 ms: metrics.taskInterval.duration * 1000,
                 detail: "transaction=\(index);dnsMs=\(ms(value.domainLookupStartDate,value.domainLookupEndDate));connectMs=\(ms(value.connectStartDate,value.connectEndDate));tlsMs=\(ms(value.secureConnectionStartDate,value.secureConnectionEndDate));sendMs=\(ms(value.requestStartDate,value.requestEndDate));serverWaitMs=\(ms(value.requestEndDate,value.responseStartDate));receiveMs=\(ms(value.responseStartDate,value.responseEndDate));receivedBytes=\(value.countOfResponseBodyBytesReceived);reused=\(value.isReusedConnection);proxy=\(value.isProxyConnection);expensive=\(value.isExpensive);constrained=\(value.isConstrained);protocol=\(proto)")
        }
    }
}
