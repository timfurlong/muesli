import AVFoundation
import Foundation

enum AudioLoaderError: Error, LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): return "Could not read audio: \(message)"
        }
    }
}

/// Loads an audio file as mono Float samples at the diarizer's 16 kHz working rate.
///
/// The banked meeting recordings are already 16 kHz mono Int16, so this is normally a
/// straight format conversion with no resampling, but the converter handles both cases.
enum AudioLoader {
    static let targetSampleRate: Double = 16000

    static func loadMono16k(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioLoaderError.unreadable("\(url.path): \(error.localizedDescription)")
        }

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioLoaderError.unreadable("could not build 16 kHz mono output format")
        }

        let inputFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioLoaderError.unreadable("no converter from \(inputFormat) to \(outputFormat)")
        }

        // Read in ~10s blocks so a 45-minute file does not need a single giant buffer.
        let inputBlockFrames = AVAudioFrameCount(inputFormat.sampleRate * 10)
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / inputFormat.sampleRate * targetSampleRate))

        var reachedEnd = false
        while !reachedEnd {
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(targetSampleRate * 10) + 1024
                )
            else {
                throw AudioLoaderError.unreadable("could not allocate output buffer")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard
                    let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: inputBlockFrames
                    )
                else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: inputBlockFrames)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw AudioLoaderError.unreadable(conversionError.localizedDescription)
            }

            if let channelData = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
                )
            }

            if status == .endOfStream || status == .error {
                reachedEnd = true
            }
            if status == .inputRanDry && outputBuffer.frameLength == 0 {
                reachedEnd = true
            }
        }

        guard !samples.isEmpty else {
            throw AudioLoaderError.unreadable("\(url.lastPathComponent) decoded to zero samples")
        }
        return samples
    }
}
