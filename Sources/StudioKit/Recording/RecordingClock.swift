import Foundation
import CoreMedia

/// Shared timeline for one Studio recording. Every recorder (screen, audio, camera, input trackers) maps its
/// host-clock timestamps through this, so screen.mov, camera.mov and events.json line up exactly, with pauses
/// removed. Thread-safe.
public final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startHost: Double?
    private var stopHost: Double?
    /// Pause intervals in host seconds; the last one may still be open.
    private var pauses: [(start: Double, end: Double?)] = []

    public init() {}

    public static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    public func start(atHost h: Double = RecordingClock.hostNow()) {
        lock.lock(); startHost = h; stopHost = nil; pauses = []; lock.unlock()
    }
    public func pause(atHost h: Double = RecordingClock.hostNow()) {
        lock.lock(); defer { lock.unlock() }
        guard startHost != nil, pauses.last.map({ $0.end != nil }) ?? true else { return }
        pauses.append((h, nil))
    }
    public func resume(atHost h: Double = RecordingClock.hostNow()) {
        lock.lock(); defer { lock.unlock() }
        guard let last = pauses.last, last.end == nil else { return }
        pauses[pauses.count - 1].end = max(h, last.start)
    }
    public func stop(atHost h: Double = RecordingClock.hostNow()) {
        lock.lock(); defer { lock.unlock() }
        if let last = pauses.last, last.end == nil { pauses[pauses.count - 1].end = h }
        stopHost = h
    }

    public var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return startHost != nil }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return pauses.last.map { $0.end == nil } ?? false }

    /// Media seconds for a host timestamp, or nil if it falls before start, inside a pause, or after stop.
    public func mediaTime(forHost h: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let start = startHost, h >= start else { return nil }
        if let stop = stopHost, h > stop { return nil }
        var paused = 0.0
        for p in pauses {
            if h >= p.start && (p.end.map { h < $0 } ?? true) { return nil }
            if let e = p.end, e <= h { paused += e - p.start }
        }
        return h - start - paused
    }

    /// Recorded length so far (frozen while paused, final after stop).
    public func elapsed(atHost now: Double = RecordingClock.hostNow()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let start = startHost else { return 0 }
        let end = stopHost ?? now
        var paused = 0.0
        for p in pauses { paused += (p.end ?? end) - p.start }
        return max(0, end - start - paused)
    }
}

/// Shifts every timing entry of a sample buffer so its presentation time becomes `newPTS`.
func retimed(_ sb: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
    if count > 0 {
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    } else {
        timing[0] = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                       decodeTimeStamp: .invalid)
    }
    let delta = newPTS - CMSampleBufferGetPresentationTimeStamp(sb)
    for i in timing.indices {
        timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + delta
        timing[i].decodeTimeStamp = .invalid
    }
    var out: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                                       sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
                                                       sampleBufferOut: &out)
    return status == noErr ? out : nil
}
