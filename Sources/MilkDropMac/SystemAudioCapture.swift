import Foundation
import CoreAudio
import AudioToolbox
import MilkDropCore

/// Captures the global output mix with Core Audio's process-tap API (macOS 14.2+).
/// Unlike ScreenCaptureKit this is audio-only and does not request Screen Recording access.
final class SystemAudioCapture {
    let analyzer = AudioAnalyzer(sampleRate: 48_000)
    private let ioQueue = DispatchQueue(label: "MilkDropMac.CoreAudioTap.IO", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "MilkDropMac.CoreAudioTap.Analysis", qos: .userInitiated)
    private let ring = AudioRing(capacity: 65_536)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var drainTimer: DispatchSourceTimer?
    private var loggedSignal = false
    private var lastDiagnostic = Date.distantPast
    private(set) var status = "Starting Core Audio system tap…"
    var onStatus: ((String) -> Void)?

    func start() async {
        do {
            try startCoreAudioTap()
        } catch {
            updateStatus("System audio tap failed: \(error.localizedDescription)")
            RuntimeLog.write("AUDIO ERROR \(error)")
        }
    }

    func stop() {
        drainTimer?.cancel(); drainTimer = nil
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = kAudioObjectUnknown; tapID = kAudioObjectUnknown
    }

    private func startCoreAudioTap() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }
        stop()

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "MilkDrop System Output"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create process tap")
        let format: AudioStreamBasicDescription = try property(tapID, selector: kAudioTapPropertyFormat)
        analyzer.configure(sampleRate: format.mSampleRate)

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey as String: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey as String: true
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MilkDrop Audio Tap",
            kAudioAggregateDeviceUIDKey as String: "com.lukeschneider.milkdropmac.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [tapEntry]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID), "create private aggregate device")
        try waitUntilAggregateIsReady()

        let ring = self.ring
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, _, _ in
            ring.write(input)
        }, "create tap IOProc")
        guard let ioProcID else { throw TapError.missingIOProc }
        try check(AudioDeviceStart(aggregateID, ioProcID), "start tap IO")

        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainAudio() }
        drainTimer = timer; timer.resume()

        let formatText = String(format: "%.0f Hz • %u ch", format.mSampleRate, format.mChannelsPerFrame)
        updateStatus("LIVE • Core Audio system output • \(formatText)")
        RuntimeLog.write("AUDIO TAP LIVE • \(formatText) • tap \(tapID) • aggregate \(aggregateID)")
    }

    private func waitUntilAggregateIsReady() throws {
        var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        for _ in 0..<100 {
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            let aliveStatus = AudioObjectGetPropertyData(aggregateID, &aliveAddress, 0, nil, &aliveSize, &alive)
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(aggregateID, &streamAddress, 0, nil, &streamSize)
            if aliveStatus == noErr, alive == 1, streamStatus == noErr, streamSize >= MemoryLayout<AudioStreamID>.size { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw TapError.aggregateNotReady
    }

    private func drainAudio() {
        let samples = ring.read(maximum: 4096)
        if Date().timeIntervalSince(lastDiagnostic) >= 2 {
            lastDiagnostic = Date()
            let d = ring.diagnostic()
            RuntimeLog.write("AUDIO CALLBACKS \(d.callbacks) • buffers \(d.buffers) • channels \(d.channels) • bytes \(d.bytes) • queued \(d.queued)")
        }
        guard !samples.isEmpty else { return }
        analyzer.consume(samples: samples)
        if !loggedSignal, samples.contains(where: { abs($0) > 0.0001 }) {
            loggedSignal = true
            let peak = samples.lazy.map { abs($0) }.max() ?? 0
            RuntimeLog.write(String(format: "AUDIO SIGNAL CONFIRMED • peak %.5f", peak))
        }
    }

    private func property(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read tap format")
        return value
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw TapError.osStatus(operation, status) }
    }

    private func updateStatus(_ value: String) {
        status = value
        DispatchQueue.main.async { self.onStatus?(value) }
    }

    enum TapError: LocalizedError {
        case unsupportedOS, aggregateNotReady, missingIOProc, osStatus(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .unsupportedOS: "Core Audio system taps require macOS 14.2 or newer"
            case .aggregateNotReady: "Core Audio aggregate tap device did not initialize"
            case .missingIOProc: "Core Audio did not create an IO callback"
            case let .osStatus(operation, status): "\(operation) returned OSStatus \(status)"
            }
        }
    }
}

/// Bounded producer/consumer ring. The real-time callback only copies samples and never runs FFT work.
private final class AudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var callbacks = 0
    private var lastBuffers = 0
    private var lastChannels: UInt32 = 0
    private var lastBytes: UInt32 = 0

    init(capacity: Int) { self.capacity = capacity; storage = Array(repeating: 0, count: capacity) }

    func write(_ list: UnsafePointer<AudioBufferList>) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !buffers.isEmpty else { return }
        callbacks += 1
        lastBuffers = buffers.count
        lastChannels = buffers[0].mNumberChannels
        lastBytes = buffers[0].mDataByteSize
        let planar = buffers.count > 1
        let firstCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        guard firstCount > 0 else { return }
        if planar {
            for frame in 0..<firstCount {
                var mono: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    mono += data[frame] / Float(buffers.count)
                }
                append(mono)
            }
        } else if let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let channels = max(Int(buffers[0].mNumberChannels), 1)
            let frames = firstCount / channels
            for frame in 0..<frames {
                var mono: Float = 0
                for channel in 0..<channels { mono += data[frame * channels + channel] / Float(channels) }
                append(mono)
            }
        }
    }

    func read(maximum: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let count = min(maximum, available)
        guard count > 0 else { return [] }
        var result = Array(repeating: Float.zero, count: count)
        for i in 0..<count { result[i] = storage[readIndex]; readIndex = (readIndex + 1) % capacity }
        available -= count
        return result
    }

    func diagnostic() -> (callbacks: Int, buffers: Int, channels: UInt32, bytes: UInt32, queued: Int) {
        lock.lock(); defer { lock.unlock() }
        return (callbacks, lastBuffers, lastChannels, lastBytes, available)
    }

    private func append(_ sample: Float) {
        storage[writeIndex] = sample
        writeIndex = (writeIndex + 1) % capacity
        if available == capacity { readIndex = (readIndex + 1) % capacity } else { available += 1 }
    }
}
