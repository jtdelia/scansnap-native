import Darwin
import Foundation

/// Runs work with Mach time-constraint (real-time) scheduling, as audio apps do.
///
/// The S1300 streams ~10 MB/s through a small buffer; if the reading thread is woken late (for
/// example while Spotlight indexes the previous PDF) the buffer fills and the scanner pauses the
/// paper mid-sheet. Real-time scheduling keeps wake-up latency low; the thread mostly sleeps in
/// USB reads, so it uses little CPU.
enum RealtimeThread {
    /// Whether the most recent `run` obtained real-time scheduling.
    nonisolated(unsafe) static var lastApplied = false

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ticks(_ milliseconds: Double) -> UInt32 {
            UInt32(milliseconds * 1_000_000 * Double(timebase.denom) / Double(timebase.numer))
        }

        var policy = thread_time_constraint_policy_data_t(
            period: ticks(10), computation: ticks(3), constraint: ticks(10), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let applied = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        lastApplied = applied == KERN_SUCCESS
        defer {
            if applied == KERN_SUCCESS {
                var standard = thread_standard_policy_data_t(no_data: 0)
                let standardCount = mach_msg_type_number_t(MemoryLayout<thread_standard_policy_data_t>.size / MemoryLayout<integer_t>.size)
                withUnsafeMutablePointer(to: &standard) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: max(1, Int(standardCount))) {
                        _ = thread_policy_set(thread, thread_policy_flavor_t(THREAD_STANDARD_POLICY), $0, standardCount)
                    }
                }
            }
        }
        return try body()
    }
}
