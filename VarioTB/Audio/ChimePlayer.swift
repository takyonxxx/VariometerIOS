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
    ///
    /// Uses bundled `reach_chime.wav` (a short classic alarm chirp) —
    /// more urgent and recognisable than a synthesized arpeggio.
    /// Falls back to a C5-E5-G5 synth tone if the asset is missing.
    func playReachChime() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let url = Bundle.main.url(forResource: "reach_chime",
                                          withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.volume = 0.9
                player.prepareToPlay()
                player.play()
                DispatchQueue.main.async { [weak self] in
                    self?.players.append(player)
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + player.duration + 0.3) {
                        self?.players.removeAll { $0 === player }
                    }
                }
                return
            }
            // Fallback synth chime
            self.playSequence(frequencies: [523.25, 659.25, 783.99],
                              noteDurationS: 0.12,
                              noteGapS: 0.03,
                              volume: 0.8)
        }
    }

    /// Loud, attention-grabbing alarm for task start gate opening and
    /// task deadline. Plays a pre-recorded facility-alarm WAV file
    /// bundled with the app — much more urgent than a synthesized
    /// beep pattern. The pilot may be mid-flight with wind noise, so
    /// we want a siren-like sound that cuts through.
    ///
    /// Falls back to a synthesized pattern if the asset is missing
    /// (shouldn't happen in shipped builds, but makes the code robust
    /// during refactors that touch Copy Bundle Resources).
    func playTaskAlarm() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let url = Bundle.main.url(forResource: "task_alarm",
                                          withExtension: "wav"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.volume = 1.0
                player.prepareToPlay()
                player.play()
                DispatchQueue.main.async { [weak self] in
                    self?.players.append(player)
                    // Retain for the clip's full duration + tail.
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + player.duration + 0.5) {
                        self?.players.removeAll { $0 === player }
                    }
                }
                return
            }
            // Fallback synthesized alarm
            let pattern: [Double] = [
                880.0, 698.46,
                880.0, 698.46,
                880.0, 698.46,
                880.0, 698.46,
                880.0, 698.46,
                880.0, 698.46,
            ]
            self.playSequence(frequencies: pattern,
                              noteDurationS: 0.18,
                              noteGapS: 0.05,
                              volume: 1.0)
        }
    }

    /// Build a PCM buffer containing the requested note sequence and
    /// kick off an AVAudioPlayer on it. The player instance is held
    /// until playback finishes to keep ARC from freeing it mid-sound.
    private func playSequence(frequencies: [Double],
                              noteDurationS: Double,
                              noteGapS: Double,
                              volume: Float = 0.8) {
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
        player.volume = volume
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
