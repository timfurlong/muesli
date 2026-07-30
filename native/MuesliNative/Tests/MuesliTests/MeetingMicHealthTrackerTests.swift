import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMicHealthTracker")
struct MeetingMicHealthTrackerTests {
    @Test("all-zero raw mic with active system audio raises degraded warning")
    func allZeroRawMicWithActiveSystemAudioRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        var snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("system audio without mic callbacks is distinguishable from all-zero mic")
    func systemAudioWithoutMicCallbacksIsMissingCallbacks() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss after healthy input raises warning")
    func midMeetingMicCallbackLossRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss still warns when system audio starts during grace window")
    func midMeetingMicCallbackLossWithGraceWindowRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 1_600), now: now.addingTimeInterval(0.5))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("silence without active system audio does not warn")
    func silenceWithoutActiveSystemAudioDoesNotWarn() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))

        #expect(snapshot.state == .waitingForAudio)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("non-zero raw mic clears degraded warning")
    func nonZeroRawMicClearsWarning() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        let recovered = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))

        #expect(recovered.state == .healthy)
        #expect(recovered.warningMessage == nil)
        #expect(recovered.firstNonZeroMicAt != nil)
    }

    @Test("no AEC status reported produces no AEC warning")
    func noAecStatusProducesNoWarning() {
        let tracker = MeetingMicHealthTracker()
        let snapshot = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))
        #expect(snapshot.aecStatus == nil)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("disengaged AEC raises warning even while mic is healthy")
    func disengagedAecRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))

        let snapshot = tracker.noteAecStatus(MeetingAecEngagementStatus(
            engaged: false, processorName: nil, passthroughSamples: 0, sampleRate: 16_000
        ))
        #expect(snapshot.state == .healthy)
        #expect(snapshot.warningMessage?.contains("Echo cancellation is not active") == true)
    }

    @Test("engaged AEC with sustained passthrough raises warning")
    func engagedAecWithPassthroughRaisesWarning() {
        let tracker = MeetingMicHealthTracker()

        var snapshot = tracker.noteAecStatus(MeetingAecEngagementStatus(
            engaged: true, processorName: "dtln", passthroughSamples: 16_000, sampleRate: 16_000
        ))
        #expect(snapshot.warningMessage == nil)

        snapshot = tracker.noteAecStatus(MeetingAecEngagementStatus(
            engaged: true, processorName: "dtln", passthroughSamples: 48_000, sampleRate: 16_000
        ))
        #expect(snapshot.warningMessage?.contains("skipping some microphone audio") == true)
    }

    @Test("mic-signal state warnings take precedence over AEC warnings")
    func micStateWarningsTakePrecedenceOverAec() {
        let tracker = MeetingMicHealthTracker()
        _ = tracker.noteAecStatus(MeetingAecEngagementStatus(
            engaged: false, processorName: nil, passthroughSamples: 0, sampleRate: 16_000
        ))

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))

        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.warningMessage == snapshot.state.userMessage)
    }
}
