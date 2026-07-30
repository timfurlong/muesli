import ArgumentParser
import Foundation

/// Replays a banked meeting recording through candidate diarization backends.
///
/// This is the P1 benchmark harness from the Speaker ID roadmap. Without hand labels it does
/// not compute DER; it reports the structural signals (speaker count, turn count, talk-time
/// split, coverage) that tell us whether a backend is worth scoring properly, and writes RTTM
/// so the same run can be scored later once ground truth exists.
@main
struct DiarBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "muesli-diarbench",
        abstract: "Replay a recording through candidate diarizers and compare their output."
    )

    @Argument(help: "Path to a mono WAV recording (system-audio bank files are 16 kHz Int16).")
    var recording: String

    @Option(name: .long, help: "Backends to run. Repeat the flag to select several. Defaults to all.")
    var backend: [Backend] = []

    @Option(name: .long, help: "Known speaker count from the calendar roster; constrains backends that accept a hint.")
    var expectedSpeakers: Int?

    @Option(name: .long, help: "Directory for per-backend RTTM plus the combined JSON report.")
    var outputDir: String?

    mutating func run() async throws {
        let url = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath)
        let recordingId = url.deletingPathExtension().lastPathComponent

        FileHandle.standardError.write("Loading \(url.lastPathComponent)...\n".data(using: .utf8)!)
        let samples = try AudioLoader.loadMono16k(at: url)
        let audioSeconds = Double(samples.count) / AudioLoader.targetSampleRate
        FileHandle.standardError.write(
            String(format: "Loaded %.1fs (%d samples @ 16 kHz)\n", audioSeconds, samples.count).data(using: .utf8)!
        )

        let selected = backend.isEmpty ? Backend.allCases : backend
        var reports: [BackendReport] = []

        for candidate in selected {
            FileHandle.standardError.write("\n▶ \(candidate.displayName)\n".data(using: .utf8)!)
            let report = await BackendRunner.run(
                candidate,
                samples: samples,
                audioSeconds: audioSeconds,
                expectedSpeakers: expectedSpeakers
            )
            reports.append(report)
            FileHandle.standardError.write(summaryLine(report).data(using: .utf8)!)
        }

        let run = BenchRun(
            recording: url.path,
            recordingId: recordingId,
            audioSeconds: audioSeconds,
            expectedSpeakers: expectedSpeakers,
            reports: reports
        )

        if let outputDir {
            try write(run: run, recordingId: recordingId, to: outputDir)
        }

        print(renderTable(run: run))
    }

    private func summaryLine(_ report: BackendReport) -> String {
        guard report.ok else {
            return "  FAILED after \(String(format: "%.1f", report.wallSeconds))s: \(report.error ?? "unknown")\n"
        }
        return String(
            format: "  %d speakers, %d turns, %.1fs speech, %.1fx realtime\n",
            report.speakerCount,
            report.segmentCount,
            report.totalSpeechSeconds,
            report.realtimeFactor ?? 0
        )
    }

    private func write(run: BenchRun, recordingId: String, to directory: String) throws {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: dir.appendingPathComponent("\(recordingId).json"))

        for report in run.reports where report.ok {
            let slug = report.backend
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .lowercased()
            try report
                .rttm(recordingId: recordingId)
                .write(
                    to: dir.appendingPathComponent("\(recordingId).\(slug).rttm"),
                    atomically: true,
                    encoding: .utf8
                )
        }
    }

    /// `String(format:)` does not honour width specifiers for `%@`, so pad by hand.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func renderTable(run: BenchRun) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("Recording: \(run.recordingId)")
        lines.append(String(format: "Duration:  %.1fs (%.1f min)", run.audioSeconds, run.audioSeconds / 60))
        if let expected = run.expectedSpeakers {
            lines.append("Expected speakers: \(expected)")
        }
        lines.append("")
        lines.append(pad("Backend", 30) + " Spk  Turns   Speech  Cover  MedTurn   RTFx")
        lines.append(String(repeating: "-", count: 72))
        for report in run.reports {
            guard report.ok else {
                lines.append(pad(report.backend, 30) + "  FAILED")
                continue
            }
            lines.append(
                pad(report.backend, 30)
                    + String(
                        format: "%4d %6d %7.0fs %5.0f%% %7.1fs %6.1f",
                        report.speakerCount,
                        report.segmentCount,
                        report.totalSpeechSeconds,
                        report.speechCoverage * 100,
                        report.medianSegmentSeconds,
                        report.realtimeFactor ?? 0
                    )
                    + (report.isCoherent ? "" : "  ⚠︎ incoherent")
            )
        }
        lines.append("")
        for report in run.reports where report.ok {
            let split = report.speakers
                .prefix(6)
                .map { String(format: "%@ %.0fs (%.0f%%)", $0.speaker, $0.seconds, $0.shareOfSpeech * 100) }
                .joined(separator: ", ")
            lines.append("\(report.backend): \(split)")
        }
        return lines.joined(separator: "\n")
    }
}
