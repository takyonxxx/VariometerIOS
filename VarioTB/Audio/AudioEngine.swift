import Foundation
import AVFoundation

/// Vario audio engine — tuned to match a real reference recording.
///
/// Analysis of the reference audio revealed these characteristics:
/// - Tone is NOT a pure sine. It's a harmonic-rich "piezo buzzer" timbre:
///   fundamental + strong 3rd harmonic (~60% amplitude) + 5th harmonic (~35%).
/// - Pitch is CONSTANT within each beep (no intra-beep sweep).
/// - Beep duration is FIXED at ~90 ms regardless of cadence or pitch.
/// - Pitch range: ~1100 Hz (low climb) → ~1340 Hz (strong climb). Narrow band.
/// - Cadence range: ~6 Hz (low climb) → ~8.5 Hz (strong climb).
/// - Sink alarm: continuous ~820 Hz tone with ~2 Hz FM vibrato depth ~40 Hz,
///   same harmonic-rich timbre as climb beeps.
/// - All parameter transitions are smoothed; no clicks between beeps.
final class AudioEngine: ObservableObject {
    // MARK: - Config

    // Pitch mapping — glides smoothly up with climb rate
    // (basePitch and maxPitch are now runtime-controllable via updateSettings)
    private let maxClimbRef: Double = 6.0

    // Cadence mapping (amplitude-modulation frequency, Hz)
    // Low climb: slow pulse; high climb: fast pulse. Tone never goes silent.
    private let minCadenceHz: Double = 2.5         // at threshold
    private let maxCadenceHz: Double = 8.0         // at max climb

    // Sink drone
    private let sinkPitchHz: Double = 200
    private let sinkVibratoHz: Double = 2.2
    private let sinkVibratoDepth: Double = 40      // Hz

    // (Unused in continuous mode but kept for future switchable beep mode)
    private let beepDurationSec: Double = 0.090
    private let envAttack: Double = 0.006
    private let envRelease: Double = 0.020

    // Harmonic amplitudes — buzzer-like rich timbre
    private let amp1: Double = 1.00
    private let amp3: Double = 0.55
    private let amp5: Double = 0.25
    private let amp2: Double = 0.05

    // Parameter smoothing (audio thread)
    private let smoothTau: Double = 0.10

    // MARK: - Audio graph

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let sampleRate: Double = 44100

    // MARK: - State (stateLock protects ALL below)

    private let stateLock = NSLock()
    private var _targetVario: Double = 0
    private var _enabled: Bool = true
    private var _volume: Double = 0.8
    private var _climbThreshold: Double = 0.1
    private var _sinkThreshold: Double = -2.0
    private var _soundMode: SoundMode = .procedural
    private var _basePitchHz: Double = 700
    private var _maxPitchHz:  Double = 1600

    // Smoothed values updated on audio thread
    private var smoothVario: Double = 0
    private var smoothPitch: Double = 1100
    private var smoothCadence: Double = 6.0
    private var smoothVolume: Double = 0.8

    // Per-beep state: pitch is latched at the START of each beep and held constant.
    private var currentBeepPitch: Double = 1100
    private var beepElapsed: Double = 0           // seconds since beep start
    private var beepActive: Bool = false          // is currently playing a beep
    private var silenceElapsed: Double = 0        // seconds since last beep ended

    // Phase accumulators
    private var phase: Double = 0
    private var vibratoPhase: Double = 0          // shared: sink FM + climb AM

    // MARK: - Public control

    /// When set, overrides the live vario reading for sound testing in Settings.
    /// Must be @Published so the SettingsView slider's "manual_test" label
    /// re-renders when the user drags the slider.
    @Published var testOverride: Double? = nil

    init() {
        setupAudio()
    }

    private func setupAudio() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buf = abl[0]
            let ptr = buf.mData!.assumingMemoryBound(to: Float.self)
            self.render(into: ptr, frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.9

        do {
            try engine.start()
        } catch {
            print("Audio engine start failed: \(error)")
        }
    }

    func updateSettings(enabled: Bool, volume: Double, mode: SoundMode,
                        climbThreshold: Double, sinkThreshold: Double,
                        basePitchHz: Double, maxPitchHz: Double) {
        stateLock.lock()
        _enabled = enabled
        _volume = volume
        _soundMode = mode
        _climbThreshold = climbThreshold
        _sinkThreshold = sinkThreshold
        _basePitchHz = basePitchHz
        _maxPitchHz = maxPitchHz
        stateLock.unlock()
    }

    func updateVario(_ v: Double) {
        stateLock.lock()
        _targetVario = testOverride ?? v
        stateLock.unlock()
    }

    // MARK: - DSP render

    private func render(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        stateLock.lock()
        let targetVario = _targetVario
        let enabled = _enabled
        let volume = _volume
        let climbThr = _climbThreshold
        let sinkThr = _sinkThreshold
        let mode = _soundMode
        let basePitch = _basePitchHz
        let maxPitch = _maxPitchHz
        stateLock.unlock()

        if !enabled {
            for i in 0..<frameCount { out[i] = 0 }
            return
        }

        let dt = 1.0 / sampleRate
        let alpha = 1.0 - exp(-dt / smoothTau)
        let twoPi = 2.0 * Double.pi

        for i in 0..<frameCount {
            smoothVario += (targetVario - smoothVario) * alpha
            smoothVolume += (volume - smoothVolume) * alpha

            var sample: Double = 0

            if smoothVario < sinkThr {
                // SINK DRONE — continuous tone with FM vibrato, same harmonic timbre
                vibratoPhase += dt * sinkVibratoHz * twoPi
                if vibratoPhase > twoPi { vibratoPhase -= twoPi }
                let instFreq = sinkPitchHz + sinkVibratoDepth * sin(vibratoPhase)
                phase += dt * instFreq * twoPi
                if phase > twoPi * 5 { phase -= twoPi * 5 }
                sample = harmonicWave(phase: phase, mode: mode) * 0.6

            } else if smoothVario > climbThr {
                // CLIMB TONE — pulsating: pitch glides smoothly, amplitude pulses
                // between 0 and 1 with SOFT edges (no sharp clicks).
                // Each cycle: smooth swell up, brief plateau near peak, smooth decay
                // to zero, brief rest at zero. Pitch keeps advancing continuously —
                // when amplitude comes back it picks up the pitch's new value.
                let norm = max(0, min(1, (smoothVario - climbThr) / maxClimbRef))

                let targetPitch = basePitch + norm * (maxPitch - basePitch)
                let targetCad   = minCadenceHz + norm * (maxCadenceHz - minCadenceHz)
                smoothPitch   += (targetPitch - smoothPitch) * alpha
                smoothCadence += (targetCad   - smoothCadence) * alpha

                // Cycle phase 0..1 over one beep cycle
                vibratoPhase += dt * smoothCadence * twoPi
                if vibratoPhase > twoPi { vibratoPhase -= twoPi }
                let cyc = vibratoPhase / twoPi    // 0..1

                // Amplitude shape: on for first 65%, off for last 35%.
                // Inside "on": smooth attack + plateau + smooth release (cosine ramps).
                // This gives perceived pulsation without clicks.
                let onFrac: Double = 0.65
                var amp: Double = 0
                if cyc < onFrac {
                    let t = cyc / onFrac      // 0..1 within on-segment
                    let attack = 0.20         // 20% of on-segment ramping up
                    let release = 0.35        // 35% of on-segment ramping down
                    if t < attack {
                        amp = 0.5 * (1 - cos(Double.pi * t / attack))
                    } else if t > 1 - release {
                        let r = (t - (1 - release)) / release
                        amp = 0.5 * (1 + cos(Double.pi * r))
                    } else {
                        amp = 1.0
                    }
                } else {
                    amp = 0
                }

                // Carrier pitch glides continuously — no latch
                phase += dt * smoothPitch * twoPi
                if phase > twoPi * 5 { phase -= twoPi * 5 }
                sample = harmonicWave(phase: phase, mode: mode) * amp

            } else {
                // Silence band (between thresholds) — completely quiet
                sample = 0
            }

            sample *= smoothVolume * 0.85
            if sample > 1.0 { sample = 1.0 }
            if sample < -1.0 { sample = -1.0 }
            out[i] = Float(sample)
        }
    }

    /// Harmonic-rich tone matching a real vario buzzer's timbre.
    /// Procedural mode = full buzzer character; Sample mode = slightly mellower.
    @inline(__always)
    private func harmonicWave(phase: Double, mode: SoundMode) -> Double {
        let s1 = sin(phase)
        let s2 = sin(2 * phase)
        let s3 = sin(3 * phase)
        let s5 = sin(5 * phase)
        switch mode {
        case .procedural:
            let s = amp1 * s1 + amp2 * s2 + amp3 * s3 + amp5 * s5
            return s / (amp1 + amp2 + amp3 + amp5)
        case .sample:
            let s = 1.0 * s1 + 0.35 * s3 + 0.08 * s5
            return s / 1.43
        }
    }
}
