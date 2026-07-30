import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("System audio retention")
struct SystemAudioRetentionTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-audio-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempRecording(in dir: URL, name: String = "capture.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return url
    }

    @Test func movesRecordingIntoSystemAudioDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tempRecording = try makeTempRecording(in: root)

        let output = try MuesliController.retainSystemAudioRecording(
            from: tempRecording,
            meetingTitle: "Weekly Standup",
            startedAt: Date(timeIntervalSince1970: 1_776_000_000),
            supportDirectory: root
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: tempRecording.path))
        #expect(output.pathExtension == "wav")
        #expect(output.lastPathComponent.hasSuffix("-system.wav"))
        #expect(output.lastPathComponent.contains("weekly-standup"))
        #expect(
            output.deletingLastPathComponent().path.hasSuffix("meeting-recordings/system-audio")
        )
    }

    @Test func avoidsOverwritingExistingRetainedRecording() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_776_000_000)

        let first = try MuesliController.retainSystemAudioRecording(
            from: makeTempRecording(in: root, name: "a.wav"),
            meetingTitle: "Sync",
            startedAt: startedAt,
            supportDirectory: root
        )
        let second = try MuesliController.retainSystemAudioRecording(
            from: makeTempRecording(in: root, name: "b.wav"),
            meetingTitle: "Sync",
            startedAt: startedAt,
            supportDirectory: root
        )

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(second.lastPathComponent.hasSuffix("-system-2.wav"))
    }

    @Test func defaultsToWavExtensionWhenTempFileHasNone() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try MuesliController.retainSystemAudioRecording(
            from: makeTempRecording(in: root, name: "capture"),
            meetingTitle: "Sync",
            startedAt: Date(timeIntervalSince1970: 1_776_000_000),
            supportDirectory: root
        )

        #expect(output.pathExtension == "wav")
    }

    @Test func recordsRetainedPathOnMeetingRow() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationStore(databaseURL: root.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        let startedAt = Date(timeIntervalSince1970: 1_776_000_000)
        let meetingID = try store.insertMeeting(
            title: "Weekly Standup",
            calendarEventID: nil,
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(60),
            rawTranscript: "Some words",
            formattedNotes: "## Notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let tempRecording = try makeTempRecording(in: root)

        let output = try MuesliController.retainSystemAudioRecording(
            from: tempRecording,
            meetingTitle: "Weekly Standup",
            startedAt: startedAt,
            supportDirectory: root,
            meetingID: meetingID,
            store: store
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try store.meeting(id: meetingID)?.systemAudioPath == output.path)
    }

    @Test func retainFlagDecodesFromSnakeCaseConfigKey() throws {
        let json = #"{"retain_system_audio_recordings": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.retainSystemAudioRecordings)

        let defaultConfig = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!defaultConfig.retainSystemAudioRecordings)
    }
}
