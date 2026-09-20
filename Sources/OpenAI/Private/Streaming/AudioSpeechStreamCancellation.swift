import Foundation

struct AudioSpeechCancellableRequest: CancellableRequest {
    let cancel: @Sendable () -> Void

    func cancelRequest() {
        cancel()
    }
}

/// Handles termination even when a custom transport completes before returning its request.
final class AudioSpeechStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: CancellableRequest?
    private var canceled = false

    func setRequest(_ request: CancellableRequest) {
        lock.lock()
        let shouldCancel = canceled
        if !shouldCancel { self.request = request }
        lock.unlock()
        if shouldCancel { request.cancelRequest() }
    }

    func cancel() {
        lock.lock()
        canceled = true
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.cancelRequest()
    }
}
