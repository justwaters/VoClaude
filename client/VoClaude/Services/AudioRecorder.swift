@preconcurrency import AVFoundation
import Observation
import Speech

/// Microphone capture for push-to-talk and hands-free calls.
///
/// Audio is converted to 16 kHz mono Int16 for upload to the daemon (faster-whisper).
/// Push-to-talk can instead feed Apple Speech (`onDeviceTranscription`) and send text.
/// Hands-free (`startContinuous`) keeps the mic open and uses voice-activity detection
/// to cut utterances, delivering each one while `isListening` is on.
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

    /// What a finished push-to-talk recording produced.
    enum Utterance {
        case audio(Data, sampleRate: Double)
        case text(String)
    }

    nonisolated static let uploadSampleRate: Double = 16_000

    /// Push-to-talk recording in progress.
    private(set) var isRecording = false
    /// Hands-free capture is running (the mic stays open for the whole call).
    private(set) var isContinuous = false
    /// Hands-free: someone is talking right now.
    private(set) var isHearingSpeech = false
    private(set) var level: Float = 0

    /// Hands-free gate. Utterances are only detected and delivered while this is on.
    var isListening = false {
        didSet {
            capture?.setListening(isListening)
            if !isListening { isHearingSpeech = false }
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var capture: CaptureSink?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var onUtterance: ((Data) -> Void)?
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Push-to-talk

    func start(onDeviceTranscription: Bool) async throws {
        guard !isRecording, !isContinuous else { return }
        guard await Self.requestPermission() else { throw RecorderError.microphoneDenied }

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
        try beginCapture(recognition: request, detectsUtterances: false)
        isRecording = true
    }

    /// Stop recording and return what was captured (nil if nothing usable).
    func stop() async -> Utterance? {
        guard isRecording, let sink = capture else { return nil }
        endCapture()
        isRecording = false

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
        endCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    // MARK: Hands-free

    /// Open the mic for a call. The caller configures the audio session (CallKit does on iPhone).
    func startContinuous(onUtterance: @escaping (Data) -> Void) throws {
        guard !isContinuous else { return }
        if isRecording { cancel() }
        self.onUtterance = onUtterance
        try beginCapture(recognition: nil, detectsUtterances: true)
        isContinuous = true

        // Route changes (AirPods, speaker toggle) stop the engine and can change the input format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartContinuous() }
        }
    }

    func stopContinuous() {
        guard isContinuous else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        endCapture()
        isContinuous = false
        isListening = false
        onUtterance = nil
    }

    private func restartContinuous() {
        guard isContinuous else { return }
        endCapture()
        do {
            try beginCapture(recognition: nil, detectsUtterances: true)
            capture?.setListening(isListening)
        } catch {
            print("AudioRecorder: couldn't restart after route change: \(error)")
        }
    }

    // MARK: Capture plumbing

    private func beginCapture(recognition: SFSpeechAudioBufferRecognitionRequest?, detectsUtterances: Bool) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw RecorderError.noInput }
        guard let sink = CaptureSink(
            inputFormat: inputFormat, recognition: recognition, detectsUtterances: detectsUtterances
        ) else {
            throw RecorderError.converterUnavailable
        }

        sink.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        sink.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
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
    }

    private func endCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        capture = nil
        level = 0
        isHearingSpeech = false
    }

    private func handle(_ event: UtteranceDetector.Event) {
        guard isContinuous, isListening else { return }
        switch event {
        case .started:
            isHearingSpeech = true
        case .discarded:
            isHearingSpeech = false
        case .ended(let pcm):
            isHearingSpeech = false
            isListening = false  // the caller turns it back on once Claude has replied
            onUtterance?(pcm)
        }
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

/// Splits a continuous stream into utterances using an adaptive energy threshold.
struct UtteranceDetector {
    enum Event: Sendable {
        case started
        case ended(Data)
        case discarded
    }

    /// Seconds of loud audio before we decide someone is talking.
    var startAfter = 0.15
    /// Seconds of quiet that end an utterance.
    var endAfter = 0.9
    /// Utterances with less speech than this are dropped (coughs, clicks).
    var minimumSpeech = 0.35
    var maximumLength = 60.0
    /// Audio kept from before speech started, so the first syllable isn't clipped.
    var preroll = 0.4
    /// The noise floor is the quietest level over this window. Steady noise (a fan) lifts it;
    /// the dips between words keep it low while someone talks.
    var floorWindow = 2.0

    private(set) var noiseFloor: Float = 0.02
    private var recentLevels: [(level: Float, duration: Double)] = []
    private var speaking = false
    private var loudRun = 0.0
    private var quietRun = 0.0
    private var length = 0.0
    private var buffered: [(Data, Double)] = []
    private var utterance = Data()

    mutating func reset() {
        speaking = false
        loudRun = 0
        quietRun = 0
        length = 0
        buffered = []
        utterance = Data()
    }

    /// Feed one chunk of 16 kHz PCM with its level (0…1) and duration in seconds.
    mutating func process(_ pcm: Data, level: Float, duration: Double) -> Event? {
        recentLevels.append((level, duration))
        while recentLevels.dropFirst().reduce(0, { $0 + $1.duration }) > floorWindow {
            recentLevels.removeFirst()
        }
        // Capped so long, steady speech can't be mistaken for background noise.
        noiseFloor = min(0.2, max(0.005, recentLevels.map(\.level).min() ?? level))

        if !speaking {
            buffered.append((pcm, duration))
            while buffered.dropFirst().reduce(0, { $0 + $1.1 }) > preroll { buffered.removeFirst() }

            if level > max(0.08, noiseFloor * 2.5) {
                loudRun += duration
                if loudRun >= startAfter {
                    speaking = true
                    utterance = buffered.reduce(into: Data()) { $0.append($1.0) }
                    buffered = []
                    length = loudRun
                    quietRun = 0
                    return .started
                }
            } else {
                loudRun = 0
            }
            return nil
        }

        utterance.append(pcm)
        length += duration
        quietRun = level < max(0.05, noiseFloor * 1.8) ? quietRun + duration : 0
        guard quietRun >= endAfter || length >= maximumLength else { return nil }

        let speech = length - quietRun
        let audio = utterance
        reset()
        return speech >= minimumSpeech ? .ended(audio) : .discarded
    }
}

/// Receives buffers on the audio thread; converts to 16 kHz Int16 and forwards to Speech or the detector.
private final class CaptureSink: @unchecked Sendable {
    let recognition: SFSpeechAudioBufferRecognitionRequest?
    var onLevel: (@Sendable (Float) -> Void)?
    var onEvent: (@Sendable (UtteranceDetector.Event) -> Void)?

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var pcm = Data()
    private let detectsUtterances: Bool
    private var detector: UtteranceDetector?  // guarded by lock
    private var listening = false             // guarded by lock

    init?(inputFormat: AVAudioFormat, recognition: SFSpeechAudioBufferRecognitionRequest?, detectsUtterances: Bool) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioRecorder.uploadSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.recognition = recognition
        self.detectsUtterances = detectsUtterances
        self.detector = detectsUtterances ? UtteranceDetector() : nil
    }

    func setListening(_ on: Bool) {
        lock.withLock {
            listening = on
            detector?.reset()
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let level = AudioPlayer.rms(buffer)
        onLevel?(level)

        if let recognition {
            recognition.append(buffer)
            return
        }
        guard let bytes = convert(buffer) else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        guard detectsUtterances else {
            lock.withLock { pcm.append(bytes) }
            return
        }
        let event: UtteranceDetector.Event? = lock.withLock {
            guard listening else { return nil }
            return detector?.process(bytes, level: level, duration: duration)
        }
        if let event { onEvent?(event) }
    }

    func takePCM() -> Data {
        lock.withLock {
            defer { pcm = Data() }
            return pcm
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

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
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
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
