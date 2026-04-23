import Foundation
import AVFoundation

/// Plays a short "tag the turnpoint" chime when the pilot enters a
/// cylinder. Deliberately independent of the main vario AudioEngine —
/// it has its own short-lived AVAudioPlayer, generated in-memory from
/// a small wavetable, so triggering a chime doesn't disturb the
/// continuous vario tone playing alongside it.
///
/// The chime is a three-note ascending major arpeggio (C5-E5-G5) with
/// a short decay on each note — pleasant, attention-grabbing, not
/// annoying. Pilots hear it as a "ding-ding-ding" acknowledgement.
final class ChimePlayer {
    static let shared = ChimePlayer()

    private var players: [AVAudioPlayer] = []
    private let sampleRate: Double = 44100
    private let queue = DispatchQueue(label: "chime.player")

    /// Generate + play the reach chime. Safe to call from any thread.
    /// Subsequent calls while one chime is still playing layer on top —
    /// pilots tagging back-to-back TPs get overlapping chimes, which
    /// sounds fine and confirms both reaches happened.
    func playReachChime() {
        queue.async { [weak self] in
            self?.playSequence(frequencies: [523.25, 659.25, 783.99],  // C5, E5, G5
                               noteDurationS: 0.12,
                               noteGapS: 0.03)
        }
    }

    /// Build a PCM buffer containing the requested note sequence and
    /// kick off an AVAudioPlayer on it. The player instance is held
    /// until playback finishes to keep ARC from freeing it mid-sound.
    private func playSequence(frequencies: [Double],
                              noteDurationS: Double,
                              noteGapS: Double) {
        let totalS = Double(frequencies.count) * (noteDurationS + noteGapS)
        let sampleCount = Int(totalS * sampleRate)
        var samples = [Int16](repeating: 0, count: sampleCount)

        let noteSamples = Int(noteDurationS * sampleRate)
        let gapSamples = Int(noteGapS * sampleRate)

        for (idx, freq) in frequencies.enumerated() {
            let start = idx * (noteSamples + gapSamples)
            for i in 0..<noteSamples {
                let t = Double(i) / sampleRate
                // Simple exponential decay envelope, ~5x shorter than
                // the note itself so each tick is distinct.
                let env = exp(-6.0 * t / noteDurationS)
                let sample = env * sin(2 * .pi * freq * t) * 0.35
                let s16 = Int16(sample * Double(Int16.max))
                samples[start + i] = s16
            }
        }

        // Wrap Int16 samples in a minimal WAV header so AVAudioPlayer
        // can parse them without any file I/O.
        let data = makeWAV(samples: samples, sampleRate: Int(sampleRate))
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.8
        player.prepareToPlay()
        player.play()
        // Keep the player alive for the duration. AVAudioPlayer stops
        // automatically when the buffer runs out; we remove it from the
        // retain list a bit after that.
        DispatchQueue.main.async { [weak self] in
            self?.players.append(player)
            DispatchQueue.main.asyncAfter(deadline: .now() + totalS + 0.5) {
                self?.players.removeAll { $0 === player }
            }
        }
    }

    /// Build a 16-bit mono PCM WAV file in memory. Minimal header,
    /// enough for AVAudioPlayer to decode.
    private func makeWAV(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        let fileSize = 36 + byteCount

        func append<T>(_ v: T) {
            var v = v
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(fileSize).littleEndian)
        data.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16).littleEndian)            // chunk size
        append(UInt16(1).littleEndian)             // PCM format
        append(UInt16(1).littleEndian)             // mono
        append(UInt32(sampleRate).littleEndian)
        append(UInt32(sampleRate * 2).littleEndian) // byte rate
        append(UInt16(2).littleEndian)             // block align
        append(UInt16(16).littleEndian)            // bits per sample
        // data chunk
        data.append("data".data(using: .ascii)!)
        append(UInt32(byteCount).littleEndian)
        samples.withUnsafeBufferPointer { buf in
            data.append(Data(buffer: buf))
        }
        return data
    }
}
