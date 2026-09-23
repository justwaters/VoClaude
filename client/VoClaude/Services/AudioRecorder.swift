@preconcurrency import AVFoundation
import Observation
import Speech

/// Push-to-talk microphone capture.
///
/// Audio is converted to 16 kHz mono Int16 for upload to the daemon (faster-whisper).
/// When `onDeviceTranscription` is on, the same buffers also feed Apple Speech so the
/// client can send text instead of audio.
@MainActor
@Observable
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case noInput
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Enable it in Settings."
            case .speechDenied: "Speech recognition access is off. Enable it in Settings or turn off on-device transcription."
            case .noInput: "No microphone input is available."
            case .converterUnavailable: "Couldn't convert microphone audio."
            }
        }
    }

    /// What a finished recording produced.
    enum Utterance {
        case audio(Data, sampleRate: Double)
        case text(String)
    }

    nonisolated static let uploadSampleRate: Double = 16_000

    private(set) var isRecording = false
    private(set) var level: Float = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var capture: CaptureSink?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    func start(onDeviceTranscription: Bool) async throws {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }

        var request: SFSpeechAudioBufferRecognitionRequest?
        if onDeviceTranscription {
            guard await Self.requestSpeechAuthorization() else { throw RecorderError.speechDenied }
            let recognizer = SFSpeechRecognizer()
            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = false
            if recognizer?.supportsOnDeviceRecognition == true {
                newRequest.requiresOnDeviceRecognition = true
            }
            self.recognizer = recognizer
            request = newRequest
        }

        try AudioSessionConfigurator.activate()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw RecorderError.noInput }
        guard let sink = CaptureSink(inputFormat: inputFormat, recognition: request) else {
            throw RecorderError.converterUnavailable
        }

        sink.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        Self.installTap(on: input, format: inputFormat, sink: sink)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        capture = sink
        isRecording = true
    }

    /// Stop recording and return what was captured (nil if nothing usable).
    func stop() async -> Utterance? {
        guard isRecording, let sink = capture else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        capture = nil

        if let request = sink.recognition {
            request.endAudio()
            let text = await transcribe(request)
            recognizer = nil
            return text.isEmpty ? nil : .text(text)
        }

        let pcm = sink.takePCM()
        // Ignore taps shorter than ~0.3s; they're almost always accidental.
        guard pcm.count > Int(Self.uploadSampleRate * 0.3) * 2 else { return nil }
        return .audio(pcm, sampleRate: Self.uploadSampleRate)
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        capture = nil
        isRecording = false
        level = 0
    }

    private func transcribe(_ request: SFSpeechAudioBufferRecognitionRequest) async -> String {
        guard let recognizer, recognizer.isAvailable else { return "" }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            recognitionTask = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal {
                    once.resume(result.bestTranscription.formattedString)
                } else if error != nil {
                    once.resume(result?.bestTranscription.formattedString ?? "")
                }
            }
            // Don't hang the UI if the recognizer never produces a final result.
            Task {
                try? await Task.sleep(for: .seconds(10))
                once.resume("")
            }
        }
    }

    /// Built outside the main actor so the tap block isn't inferred as MainActor-isolated;
    /// AVAudioEngine calls it on a realtime audio thread.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, sink: CaptureSink) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.consume(buffer)
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// Receives buffers on the audio thread; converts to 16 kHz Int16 and forwards to Speech.
private final class CaptureSink: @unchecked Sendable {
    let recognition: SFSpeechAudioBufferRecognitionRequest?
    var onLevel: (@Sendable (Float) -> Void)?

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var pcm = Data()

    init?(inputFormat: AVAudioFormat, recognition: SFSpeechAudioBufferRecognitionRequest?) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioRecorder.uploadSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.recognition = recognition
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        onLevel?(AudioPlayer.rms(buffer))

        if let recognition {
            recognition.append(buffer)
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }

        let bytes = Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
        lock.withLock { pcm.append(bytes) }
    }

    func takePCM() -> Data {
        lock.withLock {
            defer { pcm = Data() }
            return pcm
        }
    }
}

/// Resumes a continuation at most once, from whichever path finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String) {
        let pending: CheckedContinuation<String, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
