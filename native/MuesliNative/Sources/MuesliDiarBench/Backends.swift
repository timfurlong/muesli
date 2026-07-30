import ArgumentParser
import CoreML
import FluidAudio
import Foundation

enum Backend: String, CaseIterable, ExpressibleByArgument {
    case current
    case offlineVBx = "offline-vbx"
    case sortformer
    case lseend

    var displayName: String {
        switch self {
        case .current: return "current (streaming pyannote)"
        case .offlineVBx: return "offline VBx"
        case .sortformer: return "Sortformer"
        case .lseend: return "LS-EEND"
        }
    }
}

/// Flattens a `DiarizationResult` (current + offline VBx) into normalized segments.
private func normalize(_ result: DiarizationResult) -> [BenchSegment] {
    result.segments.map {
        BenchSegment(
            speaker: $0.speakerId,
            start: Double($0.startTimeSeconds),
            end: Double($0.endTimeSeconds)
        )
    }
}

/// Flattens a `DiarizerTimeline` (Sortformer + LS-EEND) into normalized segments.
///
/// Both finalized and tentative segments are considered: `processComplete` finalizes the
/// session, but a trailing tentative tail can survive and dropping it would understate coverage.
/// The two lists can overlap, so each speaker's intervals are unioned rather than concatenated —
/// otherwise the same speech is counted twice and coverage exceeds the recording length.
private func normalize(_ timeline: DiarizerTimeline) -> [BenchSegment] {
    timeline.speakers.values.flatMap { speaker -> [BenchSegment] in
        let label = speaker.name ?? "Speaker \(speaker.index)"
        let intervals = (speaker.finalizedSegments + speaker.tentativeSegments)
            .map { (start: Double($0.startTime), end: Double($0.endTime)) }
            .sorted { $0.start < $1.start }

        var merged: [(start: Double, end: Double)] = []
        for interval in intervals {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged.map { BenchSegment(speaker: label, start: $0.start, end: $0.end) }
    }
}

enum BackendRunner {
    static func run(
        _ backend: Backend,
        samples: [Float],
        audioSeconds: Double,
        expectedSpeakers: Int?
    ) async -> BackendReport {
        let start = Date()
        do {
            switch backend {
            case .current:
                let manager = DiarizerManager()
                let models = try await DiarizerModels.download()
                manager.initialize(models: models)
                let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
                return .make(
                    backend: backend.displayName,
                    segments: normalize(result),
                    wallSeconds: Date().timeIntervalSince(start),
                    audioSeconds: audioSeconds
                )

            case .offlineVBx:
                // The roster gives us a known speaker count, which is the whole point of the
                // offline backend: it can be constrained where the streaming one cannot.
                var config = OfflineDiarizerConfig.default
                if let expectedSpeakers {
                    config.clustering.numSpeakers = expectedSpeakers
                }
                let manager = OfflineDiarizerManager(config: config)
                try await manager.prepareModels()
                let result = try await manager.process(audio: samples)
                return .make(
                    backend: backend.displayName,
                    variant: expectedSpeakers.map { "numSpeakers=\($0)" } ?? "unconstrained",
                    segments: normalize(result),
                    wallSeconds: Date().timeIntervalSince(start),
                    audioSeconds: audioSeconds
                )

            case .sortformer:
                let config = SortformerConfig.default
                let diarizer = SortformerDiarizer(config: config)
                let models = try await SortformerModels.loadFromHuggingFace(config: config)
                diarizer.initialize(models: models)
                let timeline = try diarizer.processComplete(samples)
                return .make(
                    backend: backend.displayName,
                    variant: "slots=\(config.numSpeakers)",
                    segments: normalize(timeline),
                    wallSeconds: Date().timeIntervalSince(start),
                    audioSeconds: audioSeconds
                )

            case .lseend:
                let diarizer = LSEENDDiarizer()
                try await diarizer.initialize(variant: .dihard3)
                let timeline = try diarizer.processComplete(samples)
                return .make(
                    backend: backend.displayName,
                    variant: "dihard3",
                    segments: normalize(timeline),
                    wallSeconds: Date().timeIntervalSince(start),
                    audioSeconds: audioSeconds
                )
            }
        } catch {
            return .failure(
                backend: backend.displayName,
                error: error,
                wallSeconds: Date().timeIntervalSince(start)
            )
        }
    }
}
