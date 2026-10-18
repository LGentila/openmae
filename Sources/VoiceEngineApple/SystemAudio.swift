@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import VoiceCore

/// The Mac's microphone and speakers, through ONE `AVAudioEngine`: Apple's voice processing (echo
/// cancellation) must know what the speakers play to remove it from what the microphone hears.
///
/// - Speakers mode: voice processing on (echo cancellation, noise reduction, automatic gain). Other apps keep their
///   level at rest; `setOtherApps` silences them while the user speaks and lowers them while Maé answers.
/// - Headphones mode: raw microphone, nothing to cancel, other apps are not turned down.
///
/// Microphone audio comes out of `microphone` in the engine's format (16 kHz mono); the assistant's
/// voice goes in through `AudioOutput`. Switching modes rebuilds the audio engine (Apple requires it).
public final class SystemAudio: AudioOutput, @unchecked Sendable {
    public struct Levels: Sendable {
        public var input: Float
        public var output: Float
    }

    /// What the system actually gave us, for the debug panel.
    public struct Route: Sendable {
        public var mode: AudioMode
        public var inputDevice: String?
        public var outputDevice: String?
        public var inputSampleRate: Double
        public var inputChannels: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case noMicrophone
        case unsupportedFormat(String)
        case cannotStart(String)
        public var description: String {
            switch self {
            case .noMicrophone: "no microphone available"
            case .unsupportedFormat(let f): "unsupported microphone format: \(f)"
            case .cannotStart(let detail): detail
            }
        }
    }

    /// Microphone audio, 16 kHz mono, in chunks of ~20 ms.
    public let microphone: AsyncStream<[Float]>
    /// Sound levels, about 20 times per second.
    public let levels: AsyncStream<Levels>
    /// Called (on an arbitrary thread) when the system reconfigured the audio — a device was plugged
    /// or unplugged. The engine has stopped: call `start` again.
    public var onConfigurationChange: (@Sendable () -> Void)?

    private let microphoneSink: AsyncStream<[Float]>.Continuation
    private let levelSink: AsyncStream<Levels>.Continuation

    // Everything below is guarded by `lock`: the audio threads, the pipeline and the host all use it.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    /// Buffers handed to the speakers and not yet heard.
    private var pendingBuffers = 0
    private var doneWaiters: [CheckedContinuation<Void, Never>] = []
    /// Between the first audio of an answer and its end: running out of audio then is a gap.
    private var answerPlaying = false
    /// Bumped on every stop, so callbacks of dropped buffers are ignored.
    private var generation = 0
    private var outputLevel: Float = 0
    /// When the speakers last ran out of audio in the middle of an answer.
    private var ranDryAt: ContinuousClock.Instant?
    private var lastLevelReport = ContinuousClock.now
    /// Times the speakers ran out of audio in the middle of an answer.
    public var underruns: Int { lock.withLock { _underruns } }
    private var _underruns = 0
    /// Speakers mode: the devices whose other apps `setOtherApps` turns down (the speakers, and voice processing's
    /// own device). Empty otherwise.
    private var duckedDevices: [AudioObjectID] = []
    private var otherAppsLevel = OtherAppsLevel.normal
    /// Microphone buffers that were not pure silence, since the engine started (see `waitForMicrophone`).
    private var heardBuffers = 0

    public init() {
        (microphone, microphoneSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
        (levels, levelSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Starting and stopping

    /// Microphone permission, asked once (the system remembers the answer).
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Opens the microphone and the speakers. `playbackSampleRate` is the voice's sample rate.
    @discardableResult
    public func start(mode: AudioMode, playbackSampleRate: Double) throws -> Route {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if mode == .speakers {
            // Must happen before anything is connected; it switches both microphone and speakers to
            // Apple's voice-processing unit.
            try input.setVoiceProcessingEnabled(true)
            input.isVoiceProcessingAGCEnabled = true
            // By default voice processing turns other apps down a lot (like a FaceTime call). Here: as little as it
            // can, and steadily (its advanced ducking would follow any voice the microphone hears: the singing in
            // the music, people in the room). `OtherAppsSound` then sets their level itself, at once.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
            if let speakers = Self.defaultDevice(input: false) {
                OtherAppsSound.set(lock.withLock { otherAppsLevel }, on: [speakers], ramp: 0.05)
            }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let playback = AVAudioFormat(standardFormatWithSampleRate: playbackSampleRate, channels: 1) else {
            throw Failure.unsupportedFormat("\(playbackSampleRate) Hz")
        }
        engine.connect(player, to: engine.mainMixerNode, format: playback)

        // With voice processing on, the microphone may report several channels (3 or 5 on some Macs)
        // and another sample rate: always read the format *after* enabling it, and let the engine mix
        // down to mono in the tap (converting the multi-channel buffer ourselves gives silence).
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noMicrophone }
        let speakers = engine.outputNode.outputFormat(forBus: 0)
        DebugLog.log("audio: mic \(Self.describe(hardware)) · speakers \(Self.describe(speakers))")
        if mode == .speakers {
            // Voice processing needs the microphone and the speakers at the same rate on the app's side;
            // by default the engine feeds the speakers at *their* rate, and when the two differ (on the
            // reference Mac the microphone switches to another rate once voice processing is on) the
            // start fails with error -10875. So the mixer is connected at the microphone's rate.
            guard let matched = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                              channels: max(1, speakers.channelCount))
            else { throw Failure.unsupportedFormat(Self.describe(hardware)) }
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: matched)
        }
        guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                                            channels: 1, interleaved: false),
              let resampler = MicrophoneResampler(from: tapFormat)
        else { throw Failure.unsupportedFormat("\(hardware)") }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate * 0.02),
                         format: tapFormat)
        { [weak self] buffer, _ in
            guard let self, let samples = resampler.convert(buffer) else { return }
            if samples.contains(where: { $0 != 0 }) { self.lock.withLock { self.heardBuffers += 1 } }
            self.microphoneSink.yield(samples)
            self.reportLevels(input: Self.level(of: samples))
        }
        player.installTap(onBus: 0, bufferSize: 1024, format: playback) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let level = Self.level(of: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            self.lock.withLock { self.outputLevel = level }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw Failure.cannotStart(
                "\(error) — micro \(Self.describe(hardware)), haut-parleurs \(Self.describe(speakers))")
        }
        player.play()

        // Voice processing turned the other apps down again as it started, through a device of its own that gathers
        // the speakers and the microphone: their level is set once more, after it, on both.
        var ducked: [AudioObjectID] = []
        if mode == .speakers, let speakers = Self.defaultDevice(input: false) {
            ducked = [speakers] + Self.aggregateDevices(containing: speakers)
            let level = lock.withLock { otherAppsLevel }
            OtherAppsSound.set(level, on: ducked, ramp: 0.05)
            DebugLog.log("audio: other apps \(level) on devices \(ducked)")
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil)
        { [weak self] _ in
            DebugLog.log("audio: configuration changed")
            self?.onConfigurationChange?()
        }
        lock.withLock {
            self.engine = engine
            self.player = player
            self.playbackFormat = playback
            self.observer = observer
            self.duckedDevices = ducked
            self.heardBuffers = 0
        }
        let route = Route(mode: mode, inputDevice: Self.defaultDeviceName(input: true),
                          outputDevice: Self.defaultDeviceName(input: false),
                          inputSampleRate: hardware.sampleRate, inputChannels: Int(hardware.channelCount))
        DebugLog.log("audio: started \(mode) — mic \(hardware.sampleRate) Hz × \(hardware.channelCount)")
        return route
    }

    /// Releases the microphone and the speakers.
    public func stop() {
        let (engine, observer, ducked) = lock.withLock {
            defer {
                self.engine = nil
                self.player = nil
                self.observer = nil
                self.duckedDevices = []
            }
            return (self.engine, self.observer, self.duckedDevices)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let engine else { return }
        OtherAppsSound.set(.normal, on: ducked)  // their sound comes back
        dropQueuedAudio()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Other apps and the microphone

    /// How loud the other apps are (speakers mode only). Kept across restarts of the engine.
    public func setOtherApps(_ level: OtherAppsLevel) {
        let devices: [AudioObjectID]? = lock.withLock {
            guard level != otherAppsLevel else { return nil }
            otherAppsLevel = level
            return duckedDevices
        }
        guard let devices, !devices.isEmpty else { return }
        OtherAppsSound.set(level, on: devices)
        DebugLog.log("audio: other apps \(level)")
    }

    /// True once the microphone delivers sound (anything but pure silence) after a start. A new voice-processing
    /// engine made right after the previous one was released sometimes stays deaf ("Error setting device on
    /// iounit" in the system log): nothing arrives until it is rebuilt.
    public func waitForMicrophone(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ heardBuffers > 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock { heardBuffers > 0 }
    }

    // MARK: - AudioOutput (the assistant's voice)

    public func play(_ samples: [Float], sampleRate: Double) async {
        guard !samples.isEmpty else { return }
        let state: (AVAudioPlayerNode, AVAudioFormat, Int)? = lock.withLock {
            guard let player, let playbackFormat else { return nil }
            if pendingBuffers == 0, answerPlaying {
                _underruns += 1
                if let ranDryAt { DebugLog.log("audio: gap of \(ContinuousClock.now - ranDryAt) in the voice") }
            }
            answerPlaying = true
            pendingBuffers += 1
            return (player, playbackFormat, generation)
        }
        guard let (player, format, generation) = state else { return }
        if format.sampleRate != sampleRate {
            DebugLog.log("audio: unexpected voice sample rate \(sampleRate) Hz")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferPlayed(generation: generation)
        }
        if !player.isPlaying { player.play() }
    }

    @discardableResult
    public func waitUntilDone() async -> PlaybackEnd {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = lock.withLock {
                if pendingBuffers == 0 {
                    answerPlaying = false
                    return true
                }
                doneWaiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
        return .confirmed  // played, or dropped by a stop: the speakers know
    }

    public func stopImmediately() async {
        dropQueuedAudio()
    }

    private func dropQueuedAudio() {
        let (player, waiters) = lock.withLock {
            generation += 1
            pendingBuffers = 0
            answerPlaying = false
            outputLevel = 0
            defer { doneWaiters = [] }
            return (self.player, doneWaiters)
        }
        player?.stop()  // drops everything scheduled, at once
        waiters.forEach { $0.resume() }
    }

    private func bufferPlayed(generation: Int) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard generation == self.generation else { return [] }
            pendingBuffers -= 1
            if pendingBuffers == 0 { ranDryAt = .now }
            guard pendingBuffers == 0, !doneWaiters.isEmpty else { return [] }
            answerPlaying = false
            outputLevel = 0
            defer { doneWaiters = [] }
            return doneWaiters
        }
        waiters.forEach { $0.resume() }
    }

    // MARK: - Levels

    private func reportLevels(input: Float) {
        let now = ContinuousClock.now
        let output: Float? = lock.withLock {
            guard now - lastLevelReport >= .milliseconds(50) else { return nil }
            lastLevelReport = now
            return pendingBuffers > 0 ? outputLevel : 0
        }
        if let output { levelSink.yield(Levels(input: input, output: output)) }
    }

    /// Loudness mapped to 0…1 (−50 dB → 0, 0 dB → 1).
    static func level<C: Collection>(of samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let db = 10 * log10(max(meanSquare, 1e-10))
        return min(max((db + 50) / 50, 0), 1)
    }

    // MARK: - Device names (debug panel)

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz × \(format.channelCount)"
    }

    static func defaultDeviceName(input: Bool) -> String? {
        guard let device = defaultDevice(input: input) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            == noErr, device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    /// The aggregate devices playing through `device`: voice processing makes one of its own.
    static func aggregateDevices(containing device: AudioDeviceID) -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).filter { candidate in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard candidate != device, AudioObjectHasProperty(candidate, &address),
                  AudioObjectGetPropertyDataSize(candidate, &address, 0, nil, &size) == noErr, size > 0
            else { return false }
            var parts = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(candidate, &address, 0, nil, &size, &parts) == noErr else { return false }
            return parts.contains(device)
        }
    }
}

/// Converts microphone buffers (any rate, mono) to the engine's 16 kHz. Used only on the tap's thread.
private final class MicrophoneResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: EngineAudio.inputSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        // "No data now" (rather than "end of stream") keeps the resampler's state between buffers.
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
