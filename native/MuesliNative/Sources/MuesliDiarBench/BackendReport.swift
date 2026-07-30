import Foundation

/// One diarized turn, normalized across backends.
struct BenchSegment: Codable {
    let speaker: String
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

/// Per-speaker rollup used for the promise check: does the backend find the right
/// number of speakers, and does it split their talk time plausibly?
struct SpeakerRollup: Codable {
    let speaker: String
    let seconds: Double
    let segments: Int
    let shareOfSpeech: Double
}

struct BackendReport: Codable {
    let backend: String
    let variant: String?
    let ok: Bool
    let error: String?

    let wallSeconds: Double
    let realtimeFactor: Double?

    let speakerCount: Int
    let segmentCount: Int
    let totalSpeechSeconds: Double
    let speechCoverage: Double
    let medianSegmentSeconds: Double
    let speakers: [SpeakerRollup]
    let segments: [BenchSegment]

    /// Per-speaker intervals are unioned, so a single speaker can never exceed the recording
    /// length. Total coverage above 100% is only legitimate when speakers overlap; well above
    /// that, or any single speaker over 100%, means the backend emitted incoherent timings.
    var isCoherent: Bool {
        speakers.allSatisfy { $0.seconds <= totalSpeechSeconds } && speakers.allSatisfy { rollup in
            speechCoverage <= 1.05 || rollup.shareOfSpeech < 1.0
        }
    }

    static func failure(backend: String, variant: String? = nil, error: Error, wallSeconds: Double) -> BackendReport {
        BackendReport(
            backend: backend,
            variant: variant,
            ok: false,
            error: String(describing: error),
            wallSeconds: wallSeconds,
            realtimeFactor: nil,
            speakerCount: 0,
            segmentCount: 0,
            totalSpeechSeconds: 0,
            speechCoverage: 0,
            medianSegmentSeconds: 0,
            speakers: [],
            segments: []
        )
    }

    static func make(
        backend: String,
        variant: String? = nil,
        segments rawSegments: [BenchSegment],
        wallSeconds: Double,
        audioSeconds: Double
    ) -> BackendReport {
        let segments = rawSegments.sorted { $0.start < $1.start }
        let totalSpeech = segments.reduce(0) { $0 + $1.duration }

        var secondsBySpeaker: [String: Double] = [:]
        var countBySpeaker: [String: Int] = [:]
        for segment in segments {
            secondsBySpeaker[segment.speaker, default: 0] += segment.duration
            countBySpeaker[segment.speaker, default: 0] += 1
        }

        let rollups = secondsBySpeaker
            .map { speaker, seconds in
                SpeakerRollup(
                    speaker: speaker,
                    seconds: seconds,
                    segments: countBySpeaker[speaker] ?? 0,
                    shareOfSpeech: totalSpeech > 0 ? seconds / totalSpeech : 0
                )
            }
            .sorted { $0.seconds > $1.seconds }

        let durations = segments.map(\.duration).sorted()
        let median: Double
        if durations.isEmpty {
            median = 0
        } else if durations.count % 2 == 1 {
            median = durations[durations.count / 2]
        } else {
            median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
        }

        return BackendReport(
            backend: backend,
            variant: variant,
            ok: true,
            error: nil,
            wallSeconds: wallSeconds,
            realtimeFactor: wallSeconds > 0 ? audioSeconds / wallSeconds : nil,
            speakerCount: rollups.count,
            segmentCount: segments.count,
            totalSpeechSeconds: totalSpeech,
            speechCoverage: audioSeconds > 0 ? totalSpeech / audioSeconds : 0,
            medianSegmentSeconds: median,
            speakers: rollups,
            segments: segments
        )
    }

    /// NIST RTTM, so results can later be scored with dscore/pyannote once we have hand labels.
    func rttm(recordingId: String) -> String {
        segments
            .map { segment in
                let fields = [
                    "SPEAKER",
                    recordingId,
                    "1",
                    String(format: "%.3f", segment.start),
                    String(format: "%.3f", segment.duration),
                    "<NA>",
                    "<NA>",
                    segment.speaker,
                    "<NA>",
                    "<NA>",
                ]
                return fields.joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}

struct BenchRun: Codable {
    let recording: String
    let recordingId: String
    let audioSeconds: Double
    let expectedSpeakers: Int?
    let reports: [BackendReport]
}
