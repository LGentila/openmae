@preconcurrency import AVFoundation
import Foundation
import OpenMaeLink
import VoiceCore

/// The iPhone's microphone and speaker during a conversation.
///
/// - Microphone: Apple's voice processing (echo cancellation, automatic gain: the "voice chat" mode of the audio
///   session), down to 16 kHz mono, in Opus frames of 20 ms sent as they come. The Mac detects speech: the
///   microphone is sent all the time the conversation is open (silence when muted).
/// - Voice: Maé's frames go through the jitter buffer (OpenMaeLink.VoiceJitterBuffer) and are played at 24 kHz.
/// - Keeps running with the screen locked or in another app (background audio).
/// - A home station without the conversation plays the voice only (`startPlayback`): what Maé says on her own.
final class PhoneAudio: @unchecked Sendable {
    /// The Mac took the conversation back.
    var onReleased: (@Sendable () -> Void)?
    /// Sound levels (0…1) of the microphone and of the voice, about 20 times a second.
    var onLevels: (@Sendable (Float, Float) -> Void)?
    /// A voice stream starts playing here (true), or is over (false).
    var onPlaying: (@Sendable (Bool) -> Void)?

    private let link: PhoneLink
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: LinkAudio.voiceRate, channels: 1)!
    private var encoder: OpusEncoder?
    private var decoder: OpusDecoder?
    private var jitter = VoiceJitterBuffer()
    /// Buffers scheduled on the player and not yet played.
    private var scheduled = 0
    /// Bumped when the player is stopped: callbacks of dropped buffers are ignored.
    private var generation = 0
    private var reportedFinished: UInt32?
    private var playingStream: UInt32?
    private var microphoneStream: UInt32 = 0
    private var sequence: UInt32 = 0
    private var muted = false
    /// Between `start` and `stop`: the engine is started again after the system stopped it.
    private var running = false
    /// The speaker only, without the microphone (`startPlayback`).
    private var playbackOnly = false
    private var pendingResume: DispatchWorkItem?
    /// For the debug log (VOICE_DEBUG=1): what the microphone gave and what was sent.
    private var captured = (buffers: 0, packets: 0, peak: Float(0))
    private var inputLevel: Float = 0
    private var outputLevel: Float = 0
    private var lastLevels = ContinuousClock.now
    private var voiceTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let start0 = ContinuousClock.now

    init(link: PhoneLink) {
        self.link = link
        voiceTask = Task { [weak self] in
            for await input in link.voice { self?.received(input) }
        }
    }

    deinit {
        voiceTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Starting and stopping

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        lock.withLock { playbackOnly = false }
        try startEngine()
        lock.withLock { running = true }
        if observers.isEmpty { observe(session) }
    }

    /// A home station without the conversation: Maé's voice only, no microphone, mixed with the other apps' sound.
    func startPlayback() throws {
        guard !lock.withLock({ running && playbackOnly }) else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try session.setActive(true)
        lock.withLock { playbackOnly = true }
        try startPlayer()
        lock.withLock { running = true }
        if observers.isEmpty { observe(session) }
    }

    /// The station's speaker off (no longer a station): the audio session is let go, as after a conversation.
    func stopPlayback() {
        guard lock.withLock({ playbackOnly }) else { return }
        stop()
    }

    /// The engine with the player only.
    private func startPlayer() throws {
        stopEngine()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: voiceFormat)
        let decoder = try OpusDecoder(sampleRate: LinkAudio.voiceRate)
        engine.prepare()
        try engine.start()
        player.play()
        lock.withLock {
            self.engine = engine
            self.player = player
            self.encoder = nil
            self.decoder = decoder
        }
        DebugLog.log("audio: the station's speaker is ready")
    }

    private func startEngine() throws {
        stopEngine()
        let engine = AVAudioEngine()
        // Before anything is connected: both the microphone and the speaker go through Apple's voice processing.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: voiceFormat)
        let encoder = try OpusEncoder(sampleRate: LinkAudio.microphoneRate, bitRate: LinkAudio.microphoneBitRate)
        let decoder = try OpusDecoder(sampleRate: LinkAudio.voiceRate)
        try tapAndStart(engine, player: player)
        lock.withLock {
            self.engine = engine
            self.player = player
            self.encoder = encoder
            self.decoder = decoder
        }
        newMicrophoneStream()
    }

    /// The microphone's tap, at the input's format of the moment, then the engine and the player started.
    private func tapAndStart(_ engine: AVAudioEngine, player: AVAudioPlayerNode) throws {
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        DebugLog.log("audio: microphone \(hardware.sampleRate) Hz × \(hardware.channelCount), input "
                     + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))
        guard hardware.sampleRate > 0,
              let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                                            channels: 1, interleaved: false),
              let resampler = Resampler(from: tapFormat, to: LinkAudio.microphoneRate)
        else { throw OpusError.unavailable }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate * 0.02), format: tapFormat) {
            [weak self] buffer, _ in
            guard let self, let samples = resampler.convert(buffer) else { return }
            self.microphone(samples)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// A new microphone stream each time the microphone starts, numbered from the clock so that it is always above
    /// the previous one, even from another session: the Mac resets its decoder and takes it.
    private func newMicrophoneStream() {
        lock.withLock {
            encoder?.reset()
            microphoneStream = max(microphoneStream &+ 1, StreamNumber.now)
            sequence = 0
            scheduled = 0
            generation += 1
        }
    }

    func stop() {
        lock.withLock {
            running = false
            playbackOnly = false
            pendingResume?.cancel()
            pendingResume = nil
        }
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine() {
        let engine: AVAudioEngine? = lock.withLock {
            defer {
                self.engine = nil
                player = nil
                scheduled = 0
                generation += 1
            }
            return self.engine
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    func setMuted(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    /// A phone call, Siri, an alarm: the system stops the audio; it starts again once they are over. A headset
    /// plugged or unplugged, and once just after the start (voice processing reconfigures the iPhone's audio): the
    /// engine stops itself, and starts again at the new format.
    private func observe(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) {
                [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended
                else { return }
                self?.scheduleResume()
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
                [weak self] notification in
                // Only this engine's: one already dropped may still report its own.
                guard let self, let changed = notification.object as? AVAudioEngine,
                      changed === self.lock.withLock({ self.engine })
                else { return }
                self.scheduleResume()
            },
        ]
    }

    /// Starts the engine again shortly. Right after a change the microphone may have no format yet (0 Hz on an
    /// iPhone, just after voice processing came on): it is tried again, five seconds at most.
    private func scheduleResume(attempt: Int = 0) {
        let work = DispatchWorkItem { [weak self] in self?.resume(attempt: attempt) }
        lock.withLock {
            pendingResume?.cancel()
            pendingResume = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func resume(attempt: Int) {
        let (running, engine, player, playbackOnly) = lock.withLock {
            (self.running, self.engine, self.player, self.playbackOnly)
        }
        guard running else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            if playbackOnly {
                try startPlayer()
            } else if let engine, let player {
                player.stop()  // its buffers were dropped with the engine's stop
                try tapAndStart(engine, player: player)
                newMicrophoneStream()
            } else {
                try startEngine()
            }
            DebugLog.log("audio: started again\(attempt > 0 ? " after \(attempt + 1) tries" : "")")
        } catch {
            guard attempt < 25 else {
                DebugLog.log("audio: cannot start again (\(error))")
                return
            }
            scheduleResume(attempt: attempt + 1)
        }
    }

    // MARK: - Microphone

    private func microphone(_ samples: [Float]) {
        let (packets, stream, first): ([Data], UInt32, UInt32) = lock.withLock {
            let input = muted ? [Float](repeating: 0, count: samples.count) : samples
            inputLevel = muted ? 0 : Self.level(of: samples)
            let packets = encoder?.encode(input) ?? []
            defer { sequence &+= UInt32(packets.count) }
            if DebugLog.enabled {
                captured.buffers += 1
                captured.packets += packets.count
                captured.peak = max(captured.peak, samples.map(abs).max() ?? 0)
                if captured.buffers % 250 == 0 {
                    let peak = captured.peak > 0 ? 20 * log10(captured.peak) : -120
                    DebugLog.log("audio: microphone, \(captured.buffers) buffers, \(captured.packets) packets sent, "
                                 + "peak \(Int(peak)) dB\(muted ? ", muted" : "")")
                    captured.peak = 0
                }
            }
            return (packets, microphoneStream, sequence)
        }
        for (i, payload) in packets.enumerated() {
            link.sendMicrophone(AudioPacket(stream: stream, sequence: first &+ UInt32(i), payload: payload))
        }
        reportLevels()
    }

    // MARK: - Voice

    private var now: Double {
        let elapsed = ContinuousClock.now - start0
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Voice that comes while nothing plays it (no conversation, and not a station: the Mac has not heard yet that it
    /// stopped) is dropped: not said to be playing, nor counted as queued, which would wait forever.
    private func received(_ input: VoiceInput) {
        switch input {
        case .packet(let packet):
            let (outputs, starts): ([VoiceJitterBuffer.Output], Bool) = lock.withLock {
                guard running else { return ([], false) }
                var starts = false
                if packet.stream != playingStream, jitter.stream.map({ packet.stream > $0 }) ?? true {
                    playingStream = packet.stream
                    decoder?.reset()
                    starts = true
                }
                return (jitter.insert(packet, scheduled: scheduled, now: now), starts)
            }
            if starts { onPlaying?(true) }
            schedule(outputs)
        case .end(let stream, let frames):
            schedule(lock.withLock {
                running ? jitter.end(stream: stream, frames: frames, scheduled: scheduled, now: now) : []
            })
        case .stop(let stream):
            let player: AVAudioPlayerNode? = lock.withLock {
                jitter.stop(stream: stream)
                generation += 1
                scheduled = 0
                outputLevel = 0
                return self.player
            }
            player?.stop()  // what was scheduled is dropped at once
            player?.play()
            finishedIfDone()
        case .released:
            onReleased?()
        }
    }

    private func schedule(_ outputs: [VoiceJitterBuffer.Output]) {
        guard !outputs.isEmpty else {
            finishedIfDone()
            return
        }
        for output in outputs {
            let (samples, player, generation): ([Float], AVAudioPlayerNode?, Int) = lock.withLock {
                let samples: [Float]
                switch output {
                case .packet(let payload): samples = decoder?.decode(payload) ?? []
                case .conceal: samples = decoder?.decode(nil) ?? []
                }
                if !samples.isEmpty { scheduled += 1 }
                outputLevel = Self.level(of: samples)
                return (samples, self.player, self.generation)
            }
            guard !samples.isEmpty, let player,
                  let buffer = AVAudioPCMBuffer(pcmFormat: voiceFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.played(generation: generation)
            }
        }
    }

    private func played(generation: Int) {
        let outputs: [VoiceJitterBuffer.Output] = lock.withLock {
            guard generation == self.generation else { return [] }
            scheduled = max(0, scheduled - 1)
            if scheduled == 0 { outputLevel = 0 }
            return scheduled <= 1 ? jitter.playerNeedsMore(scheduled: scheduled, now: now) : []
        }
        schedule(outputs)
        reportLevels()
    }

    /// Tells the Mac once everything of the stream has been heard (or stopped): its turn can end.
    private func finishedIfDone() {
        let stream: UInt32? = lock.withLock {
            guard jitter.isComplete, scheduled == 0, let stream = jitter.stream, reportedFinished != stream else {
                return nil
            }
            reportedFinished = stream
            return stream
        }
        if let stream {
            link.finished(stream: stream)
            onPlaying?(false)
        }
    }

    // MARK: - Levels

    private func reportLevels() {
        let levels: (Float, Float)? = lock.withLock {
            guard ContinuousClock.now - lastLevels > .milliseconds(50) else { return nil }
            lastLevels = .now
            return (inputLevel, scheduled > 0 ? outputLevel : 0)
        }
        if let levels { onLevels?(levels.0, levels.1) }
    }

    /// Loudness mapped to 0…1 (−50 dB → 0, 0 dB → 1), as the Mac does.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let db = 10 * log10(max(meanSquare, 1e-10))
        return min(max((db + 50) / 50, 0), 1)
    }
}

/// Microphone buffers (any rate, mono) to the link's 16 kHz. Used only on the tap's thread.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to rate: Double) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        // "No data now" (rather than "end of stream") keeps the converter's state between buffers.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
