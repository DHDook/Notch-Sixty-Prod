import CoreAudio
import Darwin
import Foundation
import os

/// E20 S6: the realtime worker threads that run the unified graph's parallel FIR phases (`n60_graph_worker_run`).
///
/// Every worker is a realtime thread (`THREAD_TIME_CONSTRAINT_POLICY`) that joins the output device's Audio Workgroup, so
/// the scheduler treats it as part of the device's IO deadline, and sleeps on a Mach semaphore until the audio thread's
/// wake function signals it (`N60WorkerWake.h`).
///
/// - allocation: threads, semaphores and the join token are created in `start()` on the control thread. The worker loop
///   allocates nothing.
/// - synchronisation: the audio thread only signals a semaphore. `start`/`stop` are control-thread calls (the host calls
///   them under its lock). `stop` clears the wake function, sets the worker count to 0, stops and joins every thread
///   before returning, so the graph can then be retired.
/// - latency: none added; a wake that arrives late costs the audio thread the job it would have handed over.
/// - rates / channels: independent; the time-constraint period is the IO block period.
/// - reset: a pool is not restarted. Rejoin (reconfiguration, rate change, device loss) is `stop()` then a new pool on
///   the new device's workgroup, which the host does in `beginParallelRender`.
final class AudioWorkgroupWorkerPool: @unchecked Sendable {
    /// Counters for tests and diagnostics. Read after `stop()` for exact values.
    struct Stats: Equatable, Sendable {
        var started = 0
        var joined = 0
        var joinFailed = 0
        var left = 0
        var policySet = 0
        var policyFailed = 0
    }

    let workerCount: Int
    private let graph: OpaquePointer
    private let workgroup: WorkGroup?
    private let periodSeconds: Double
    private let wake: UnsafeMutableRawPointer
    private let stateLock = NSLock()
    private var statsStorage = Stats()
    private var threads: [Thread] = []
    private var exited: [DispatchSemaphore] = []
    private var running = false

    /// `workgroup` nil: the workers are still realtime threads, just not in a workgroup (no device workgroup available).
    init?(graph: OpaquePointer, workers: Int, workgroup: WorkGroup?, periodSeconds: Double) {
        let n = max(0, min(Int(N60_GRAPH_MAX_WORKERS), workers))
        guard n > 0, let wake = N60WorkerWakeCreate() else { return nil }
        self.graph = graph
        self.workerCount = n
        self.workgroup = workgroup
        self.periodSeconds = periodSeconds
        self.wake = wake
    }

    deinit {
        stop()
        N60WorkerWakeDestroy(wake)
    }

    var stats: Stats {
        stateLock.lock(); defer { stateLock.unlock() }
        return statsStorage
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Wake calls the audio thread has made (diagnostic).
    var wakeCount: Int { Int(N60WorkerWakeSignalCount(wake)) }

    /// Starts the threads and registers the wake function. Returns once every thread has joined its workgroup (or failed
    /// to), so the first callback sees a complete pool. The graph must not be rendering (`n60_graph_set_wake` rule).
    func start() {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        running = true
        stateLock.unlock()
        let ready = DispatchSemaphore(value: 0)
        for index in 1...workerCount {
            let done = DispatchSemaphore(value: 0)
            let thread = Thread { [self] in
                workerMain(index: index, ready: ready)
                done.signal()
            }
            thread.name = "com.notchsixty.render-worker.\(index)"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 512 * 1024
            exited.append(done)
            threads.append(thread)
            thread.start()
        }
        for _ in 1...workerCount { ready.wait() }
        _ = n60_graph_set_wake(graph, N60WorkerWakeSignal, wake)
        _ = n60_graph_set_workers(graph, UInt32(workerCount))
    }
    /// Lowers (or raises, up to the thread count) the number of workers the audio thread wakes. Atomic in the core, so it
    /// is safe while rendering.
    func setActiveWorkers(_ count: Int) {
        guard isRunning else { return }
        _ = n60_graph_set_workers(graph, UInt32(max(0, min(workerCount, count))))
    }

    /// Stops the workers and waits until every thread has left its workgroup and exited. Idempotent. Call before
    /// `n60_graph_retire`.
    func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        let waits = exited
        exited = []
        threads = []
        stateLock.unlock()
        // Order matters: no more wakes, no more jobs offered, then release the sleepers.
        _ = n60_graph_set_workers(graph, 0)
        _ = n60_graph_set_wake(graph, nil, nil)
        N60WorkerWakeStop(wake)
        for done in waits { done.wait() }
    }

    private func bump(_ keyPath: WritableKeyPath<Stats, Int>) {
        stateLock.lock(); statsStorage[keyPath: keyPath] += 1; stateLock.unlock()
    }

    private func workerMain(index: Int, ready: DispatchSemaphore) {
        bump(\.started)
        if Self.makeRealtime(periodSeconds: periodSeconds) { bump(\.policySet) } else { bump(\.policyFailed) }
        let groupPointer = workgroup.map { UnsafeMutableRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        var membership: UnsafeMutableRawPointer?
        if let groupPointer {
            membership = N60WorkgroupJoin(groupPointer)
            if membership != nil { bump(\.joined) } else { bump(\.joinFailed) }
        }
        ready.signal()
        while N60WorkerWakeWait(wake, UInt32(index)) {
            _ = n60_graph_worker_run(graph, UInt32(index))
        }
        if let groupPointer, let membership {
            N60WorkgroupLeave(groupPointer, membership)
            bump(\.left)
        }
    }

    /// Time-constraint policy: the thread needs half the IO period of CPU, must finish inside the period, and may be
    /// preempted. Returns false when the kernel refuses.
    static func makeRealtime(periodSeconds: Double) -> Bool {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer != 0 else { return false }
        let nanos = max(100_000.0, min(50_000_000.0, periodSeconds * 1_000_000_000.0))
        let period = UInt32(nanos * Double(timebase.denom) / Double(timebase.numer))
        var policy = thread_time_constraint_policy_data_t(period: period, computation: period / 2, constraint: period, preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return result == KERN_SUCCESS
    }

    /// The device's IO-thread Audio Workgroup (`kAudioDevicePropertyIOThreadOSWorkgroup`), or nil when the device has none.
    /// The property returns a retained object; ARC owns it from here.
    static func deviceWorkgroup(_ device: AudioObjectID) -> WorkGroup? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOThreadOSWorkgroup,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw: UnsafeRawPointer?
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &raw)
        guard status == noErr, let raw else { return nil }
        return Unmanaged<WorkGroup>.fromOpaque(raw).takeRetainedValue()
    }
}
