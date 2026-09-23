import AVFoundation
import Foundation
import Observation
// CallKit refuses calls in the Simulator, so there the call runs without it.
#if os(iOS) && !targetEnvironment(simulator)
import CallKit
#endif

/// Hands-free voice call with a session.
///
/// On iPhone the call goes through CallKit, so it behaves like a phone call: the system
/// call UI and Dynamic Island, lock-screen controls, earpiece/Bluetooth routing, Recents,
/// and it keeps running in the background. On macOS (and in the Simulator, where CallKit
/// refuses calls) it's the same loop without CallKit.
///
/// The conversation is half-duplex: listen until you stop talking, send, then wait while
/// Claude works and speaks, then listen again.
@MainActor
@Observable
final class CallController: NSObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case hearing
        case waiting
        case speaking
    }

    private(set) var phase: Phase = .idle
    private(set) var session: Session?
    private(set) var isMuted = false
    private(set) var isSpeakerOn = false
    private(set) var connectedAt: Date?
    private(set) var error: String?

    var isActive: Bool { phase != .idle }

    @ObservationIgnored private let connections: WebSocketManager
    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private var callID: UUID?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    #if os(iOS) && !targetEnvironment(simulator)
    @ObservationIgnored private let provider: CXProvider
    @ObservationIgnored private let callKit = CXCallController()
    #endif

    init(connections: WebSocketManager, recorder: AudioRecorder) {
        self.connections = connections
        self.recorder = recorder
        #if os(iOS) && !targetEnvironment(simulator)
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        #endif
        super.init()
        #if os(iOS) && !targetEnvironment(simulator)
        provider.setDelegate(self, queue: nil)  // main queue
        #endif
    }

    // MARK: Controls

    func start(_ session: Session) async {
        guard phase == .idle else { return }
        error = nil
        guard await AudioRecorder.requestPermission() else {
            error = AudioRecorder.RecorderError.microphoneDenied.localizedDescription
            return
        }
        let id = UUID()
        callID = id
        self.session = session
        phase = .connecting

        #if os(iOS) && !targetEnvironment(simulator)
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: session.name))
        action.isVideo = false
        do {
            try await callKit.request(CXTransaction(action: action))
        } catch {
            fail("Couldn't start the call (\((error as NSError).code)): \(error.localizedDescription)")
        }
        #else
        do {
            try AudioSessionConfigurator.configureForCall()
            try AudioSessionConfigurator.activateWithoutCallKit()
            try beginConversation()
        } catch {
            fail(error.localizedDescription)
        }
        #endif
    }

    func hangUp() {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let callID else { return teardown() }
        Task {
            do {
                try await callKit.request(CXTransaction(action: CXEndCallAction(call: callID)))
            } catch {
                teardown()
            }
        }
        #else
        teardown()
        #endif
    }

    func toggleMute() {
        #if os(iOS) && !targetEnvironment(simulator)
        if let callID {
            let action = CXSetMutedCallAction(call: callID, muted: !isMuted)
            Task { try? await callKit.request(CXTransaction(action: action)) }
            return
        }
        #endif
        setMuted(!isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        AudioSessionConfigurator.setSpeaker(isSpeakerOn)
    }

    // MARK: Conversation loop

    private func beginConversation() throws {
        try recorder.startContinuous { [weak self] pcm in
            self?.send(pcm)
        }
        connectedAt = .now
        #if os(iOS) && !targetEnvironment(simulator)
        if let callID { provider.reportOutgoingCall(with: callID, connectedAt: connectedAt) }
        #endif
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func send(_ pcm: Data) {
        guard let session, let connection = connections.connections[session.id] else { return }
        connection.sendAudio(pcm, sampleRate: AudioRecorder.uploadSampleRate)
        phase = .waiting
    }

    /// Keep the phase and the mic gate in step with the connection and playback.
    private func tick() {
        guard isActive, let session else { return }
        guard let connection = connections.connections[session.id] else { return fail("Session closed") }
        switch connection.state {
        case .failed(let reason):
            return fail(reason)
        case .disconnected:
            return fail("Disconnected")
        case .connecting:
            recorder.isListening = false
            phase = .connecting
            return
        case .connected:
            break
        }

        let playing = connections.player.isPlaying
        if connection.isBusy || playing {
            recorder.isListening = false
            phase = playing ? .speaking : .waiting
        } else {
            recorder.isListening = !isMuted
            phase = recorder.isHearingSpeech ? .hearing : .listening
        }
    }

    private func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted { recorder.isListening = false }
    }

    private func fail(_ message: String) {
        error = message
        #if os(iOS) && !targetEnvironment(simulator)
        if let callID {
            provider.reportCall(with: callID, endedAt: .now, reason: .failed)
        }
        #endif
        teardown()
    }

    private func teardown() {
        monitor?.cancel()
        monitor = nil
        recorder.stopContinuous()
        connections.player.stop()
        if isSpeakerOn { AudioSessionConfigurator.setSpeaker(false) }
        AudioSessionConfigurator.endCall()
        phase = .idle
        callID = nil
        session = nil
        isMuted = false
        isSpeakerOn = false
        connectedAt = nil
    }
}

#if os(iOS) && !targetEnvironment(simulator)
extension CallController: @preconcurrency CXProviderDelegate {
    // The provider calls back on the main queue (see `setDelegate(_:queue: nil)`), so these
    // run on the main actor; @preconcurrency checks that at runtime.

    func providerDidReset(_ provider: CXProvider) {
        teardown()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do {
            try AudioSessionConfigurator.configureForCall()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: .now)
            let update = CXCallUpdate()
            update.remoteHandle = action.handle
            update.localizedCallerName = session?.name
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: action.callUUID, updated: update)
            action.fulfill()
        } catch {
            action.fail()
            fail("Couldn't set up call audio: \(error.localizedDescription)")
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        teardown()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit has activated the voice-chat session; only now may audio start.
        do {
            try beginConversation()
        } catch {
            fail("Couldn't open the microphone: \(error.localizedDescription)")
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
#endif
