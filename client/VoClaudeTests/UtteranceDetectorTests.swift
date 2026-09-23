import Foundation
import Testing
@testable import VoClaude

/// Feeds the detector 85 ms chunks (a 4096-frame tap at 48 kHz) at fixed levels.
private struct Feed {
    var detector = UtteranceDetector()
    var events: [UtteranceDetector.Event] = []
    let chunk = 0.085

    mutating func play(level: Float, seconds: Double) {
        let bytes = Int(AudioRecorder.uploadSampleRate * chunk) * 2
        for _ in 0..<Int((seconds / chunk).rounded()) {
            if let event = detector.process(Data(count: bytes), level: level, duration: chunk) {
                events.append(event)
            }
        }
    }

    var endedAudio: Data? {
        for case .ended(let pcm) in events { return pcm }
        return nil
    }
}

struct UtteranceDetectorTests {
    @Test func sentenceThenPauseIsOneUtterance() throws {
        var feed = Feed()
        feed.play(level: 0.01, seconds: 1)    // room tone
        feed.play(level: 0.4, seconds: 1.5)   // speech
        feed.play(level: 0.01, seconds: 1.2)  // pause

        #expect(feed.events.count == 2)
        guard case .started = feed.events.first else { Issue.record("no start"); return }
        let seconds = Double(try #require(feed.endedAudio).count) / 2 / AudioRecorder.uploadSampleRate
        // speech + ~0.9 s trailing silence + up to ~0.5 s of pre-roll
        #expect(seconds > 2.2 && seconds < 3.1)
    }

    @Test func shortPausesDontCutTheSentence() {
        var feed = Feed()
        feed.play(level: 0.4, seconds: 1)
        feed.play(level: 0.01, seconds: 0.5)  // breath between phrases
        feed.play(level: 0.4, seconds: 1)
        #expect(feed.endedAudio == nil)
        feed.play(level: 0.01, seconds: 1)
        #expect(feed.endedAudio != nil)
    }

    @Test func longSteadySpeechIsNotCutOff() {
        var feed = Feed()
        feed.play(level: 0.01, seconds: 0.5)
        feed.play(level: 0.4, seconds: 5)  // no dips for longer than the floor window
        #expect(feed.endedAudio == nil)
        feed.play(level: 0.01, seconds: 1)
        #expect(feed.endedAudio != nil)
    }

    @Test func clicksAreIgnoredOrDiscarded() {
        var feed = Feed()
        feed.play(level: 0.9, seconds: 0.085)  // too short to start
        feed.play(level: 0.01, seconds: 1)
        #expect(feed.events.isEmpty)

        feed.play(level: 0.9, seconds: 0.25)   // starts, but too little speech to send
        feed.play(level: 0.01, seconds: 1)
        guard case .discarded = feed.events.last else {
            Issue.record("expected discarded, got \(feed.events)")
            return
        }
    }

    @Test func noisyRoomRaisesTheThreshold() {
        var feed = Feed()
        feed.play(level: 0.1, seconds: 5)  // steady fan noise just above the base threshold
        #expect(feed.events.isEmpty)
        feed.play(level: 0.6, seconds: 1)  // real speech still gets through…
        feed.play(level: 0.1, seconds: 1.2)  // …and ends when it drops back to the fan
        #expect(feed.events.count == 2)
        #expect(feed.endedAudio != nil)
    }
}

struct SessionTests {
    @Test(arguments: [
        ("192.168.1.5:8000", "ws://192.168.1.5:8000/ws/session/app"),
        ("ws://host.local:8000/", "ws://host.local:8000/ws/session/app"),
        ("wss://example.com/base", "wss://example.com/base/ws/session/app"),
    ])
    func webSocketURL(host: String, expected: String) {
        #expect(Session(name: "App", host: host, repoAlias: "app").webSocketURL?.absoluteString == expected)
    }

    @Test func decodesSessionsSavedBeforeVoices() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","host":"h:1","repoAlias":"a"}]"#
        let sessions = try JSONDecoder().decode([Session].self, from: Data(json.utf8))
        #expect(sessions.first?.voice == nil)
    }
}
