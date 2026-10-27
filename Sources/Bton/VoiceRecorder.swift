@preconcurrency import AVFoundation
import BtonCore
import SwiftUI

/// Records the microphone to 16 kHz mono samples in memory: no audio file is ever written.
@MainActor @Observable final class VoiceRecorder {
    enum Phase: Equatable { case idle, recording, transcribing }

    static let barCount = 36

    private(set) var phase = Phase.idle
    /// The latest bar heights, 0 to 1, newest last.
    private(set) var bars = [Double](repeating: 0, count: barCount)
    private(set) var elapsed: TimeInterval = 0
    private(set) var problem: String?

    private let engine = AVAudioEngine()
    private let samples = SampleBox()
    private var silentFor: TimeInterval = 0
    private var onAutoStop: (() -> Void)?
    /// The microphone permission prompt is open: a second click must not start a second tap, and Esc must stop this one.
    private(set) var starting = false
    private var cancelledWhileStarting = false

    /// Starts the microphone. `onAutoStop` runs when the 5-minute cap or a long silence ends the recording.
    func start(onAutoStop: @escaping () -> Void) async {
        guard phase == .idle, !starting else { return }
        problem = nil
        starting = true
        cancelledWhileStarting = false
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        starting = false
        guard !cancelledWhileStarting else { return }
        guard allowed else {
            problem = VoiceError.microphoneDenied.localizedDescription
            return
        }
        samples.reset()
        bars = [Double](repeating: 0, count: Self.barCount)
        elapsed = 0
        silentFor = 0
        self.onAutoStop = onAutoStop
        do {
            try begin()
            phase = .recording
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            problem = error is VoiceError ? error.localizedDescription : "The microphone could not start: \(error.localizedDescription)"
        }
    }

    private func begin() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Voice.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw VoiceError.microphoneDenied }
        let tap = Self.tap(converter: converter, from: format, to: target, into: samples) { [weak self] level, seconds in
            Task { @MainActor in self?.heard(level: level, seconds: seconds) }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: tap)
        engine.prepare()
        try engine.start()
    }

    /// Built outside the main actor: the audio thread calls it, and a main-actor closure would trap there.
    private nonisolated static func tap(converter: AVAudioConverter, from format: AVAudioFormat, to target: AVAudioFormat,
                                        into box: SampleBox, heard: @escaping @Sendable (Float, TimeInterval) -> Void)
        -> AVAudioNodeTapBlock {
        { buffer, _ in
            let ratio = Voice.sampleRate / format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
            let supplied = Once()
            var failure: NSError?
            converter.convert(to: out, error: &failure) { _, status in
                if supplied.taken { status.pointee = .noDataNow; return nil }
                supplied.taken = true
                status.pointee = .haveData
                return buffer
            }
            guard failure == nil, let channel = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            box.append(chunk)
            heard(Voice.rms(chunk), Double(chunk.count) / Voice.sampleRate)
        }
    }

    private func heard(level: Float, seconds: TimeInterval) {
        guard phase == .recording else { return }
        elapsed += seconds
        bars.removeFirst()
        bars.append(Voice.barHeight(rms: level))
        silentFor = level >= Voice.silenceRMS ? 0 : silentFor + seconds
        if elapsed >= Voice.maxSeconds || silentFor >= Voice.silenceEndSeconds { onAutoStop?() }
    }

    /// What was said from sample `start` on, while the recording goes on.
    func samples(from start: Int) -> [Float] { samples.copy(from: start) }

    /// Stops the microphone and returns what was said.
    func stop() -> [Float] {
        guard phase == .recording else { return [] }
        halt()
        phase = .transcribing
        return samples.take()
    }

    /// Esc: stops and throws the recording away.
    func cancel() {
        if starting { cancelledWhileStarting = true }
        halt()
        _ = samples.take()
        phase = .idle
    }

    func finish() { phase = .idle }

    private func halt() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onAutoStop = nil
    }
}

private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []

    func append(_ chunk: [Float]) { lock.withLock { values += chunk } }
    func reset() { lock.withLock { values = [] } }
    func copy(from start: Int) -> [Float] { lock.withLock { start < values.count ? Array(values[start...]) : [] } }
    func take() -> [Float] { lock.withLock { defer { values = [] }; return values } }
}

/// Hands the converter its one buffer per call.
private final class Once: @unchecked Sendable { var taken = false }
