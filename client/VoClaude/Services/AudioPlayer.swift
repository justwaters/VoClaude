import AVFoundation
import Observation

/// Plays streamed 16-bit PCM chunks gaplessly by scheduling them back-to-back on one player node.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    /// Output level in 0...1 for the visualizer.
    private(set) var level: Float = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var queuedBuffers = 0
    /// Incremented by `stop()` so completion callbacks from flushed buffers are ignored.
    @ObservationIgnored private var generation = 0

    init() {
        engine.attach(node)
    }

    /// Queue little-endian Int16 mono samples for playback.
    func enqueue(pcm16 data: Data, sampleRate: Double) {
        guard let buffer = prepare(sampleRate: sampleRate).flatMap({ Self.makeBuffer(from: data, format: $0) }) else {
            return
        }
        do {
            try startEngineIfNeeded()
        } catch {
            print("AudioPlayer: failed to start engine: \(error)")
            return
        }

        queuedBuffers += 1
        let generation = generation
        let level = Self.rms(buffer)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.bufferFinished(generation: generation) }
        }
        if !node.isPlaying {
            node.play()
        }
        isPlaying = true
        self.level = level
    }

    /// Stop immediately and drop anything queued (barge-in).
    func stop() {
        generation += 1
        queuedBuffers = 0
        node.stop()
        isPlaying = false
        level = 0
    }

    private func bufferFinished(generation: Int) {
        guard generation == self.generation else { return }
        queuedBuffers = max(0, queuedBuffers - 1)
        if queuedBuffers == 0 {
            isPlaying = false
            level = 0
        }
    }

    private func prepare(sampleRate: Double) -> AVAudioFormat? {
        if let format, format.sampleRate == sampleRate {
            return format
        }
        guard let newFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { return nil }
        stop()
        engine.disconnectNodeOutput(node)
        // The main mixer resamples to the hardware rate.
        engine.connect(node, to: engine.mainMixerNode, format: newFormat)
        format = newFormat
        return newFormat
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        try AudioSessionConfigurator.activate()
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            for i in 0..<frameCount {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                channel[i] = Float(sample) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += channel[i] * channel[i]
        }
        // Speech RMS sits around 0.05–0.2; scale so the visualizer has range.
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 4)
    }
}

/// Shared AVAudioSession setup (iOS only; macOS has no audio session).
enum AudioSessionConfigurator {
    @MainActor
    static func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
        }
        try session.setActive(true)
        #endif
    }
}
