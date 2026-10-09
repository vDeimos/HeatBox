// SpeechListener.swift: the Mac's own speech recognition, for videos that
// have no captions. It is only ever used on the device: a Mac that could
// only recognise speech by sending sound away counts as unable.

import Engine
import Foundation
import Speech

struct MacSpeechRecognizer: SpeechRecognizer {
    /// macOS ends a program that asks for speech recognition without saying
    /// why in its Info.plist, and a bare program (`swift run`) has none.
    private static var canAsk: Bool {
        Launch.isBundled && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    private static func recognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func availability() -> SpeechAvailability {
        guard Self.canAsk else { return .unavailable }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            return .undecided
        case .denied, .restricted:
            return .notAllowed
        case .authorized:
            guard let recognizer = Self.recognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return .unavailable }
            return .ready
        @unknown default:
            return .unavailable
        }
    }

    func requestAccess() async {
        guard Self.canAsk, SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    /// The words and the one continuation waiting for them, reachable from the recogniser's queue.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var words: [TimedWord] = []
        private var continuation: CheckedContinuation<[TimedWord], Never>?
        var task: SFSpeechRecognitionTask?

        func wait(_ continuation: CheckedContinuation<[TimedWord], Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func set(_ found: [TimedWord]) {
            lock.lock()
            words = found
            lock.unlock()
        }

        /// Releases the waiting side, once.
        func finish() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            let found = words
            lock.unlock()
            waiting?.resume(returning: found)
        }
    }

    func words(in file: URL) async -> [TimedWord] {
        guard availability() == .ready, let recognizer = Self.recognizer() else { return [] }
        recognizer.queue = OperationQueue()
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let box = Box()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.wait(continuation)
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        box.set(result.bestTranscription.segments.map { TimedWord(start: $0.timestamp, text: $0.substring) })
                    }
                    if (result?.isFinal ?? false) || error != nil { box.finish() }
                }
                // A piece that never answers is given up after five minutes.
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                    box.task?.cancel()
                    box.finish()
                }
            }
        } onCancel: {
            box.task?.cancel()
            box.finish()
        }
    }
}
