import Darwin
import Foundation

public struct SharedVMHardwareFacts: Equatable, Sendable {
    public let activeCPUCount: Int
    public let performanceCoreCount: Int?
    public let physicalMemoryMiB: UInt64

    public init(activeCPUCount: Int, performanceCoreCount: Int?, physicalMemoryMiB: UInt64) {
        self.activeCPUCount = activeCPUCount
        self.performanceCoreCount = performanceCoreCount
        self.physicalMemoryMiB = physicalMemoryMiB
    }

    public static func discover(processInfo: ProcessInfo = .processInfo) -> Self {
        let activeCPUCount = processInfo.activeProcessorCount
        let physicalMemoryMiB = processInfo.physicalMemory / (1024 * 1024)
        assert(activeCPUCount > 0, "ProcessInfo must report at least one active CPU")
        assert(physicalMemoryMiB > 0, "ProcessInfo must report physical memory")
        return Self(
            activeCPUCount: activeCPUCount,
            performanceCoreCount: discoverPerformanceCoreCount(),
            physicalMemoryMiB: physicalMemoryMiB)
    }

    private static func discoverPerformanceCoreCount() -> Int? {
        var coreCount: CInt = 0
        var size = MemoryLayout<CInt>.size
        let status = sysctlbyname("hw.perflevel0.physicalcpu", &coreCount, &size, nil, 0)
        guard status == 0, size == MemoryLayout<CInt>.size, coreCount > 0 else { return nil }
        assert(size == MemoryLayout<CInt>.size, "sysctl must return a complete core count")
        assert(coreCount > 0, "sysctl must return a positive core count")
        return Int(coreCount)
    }
}

public struct SharedVMSizing: Equatable, Sendable {
    public let cpuCount: Int
    public let memoryMiB: UInt64

    public init(cpuCount: Int, memoryMiB: UInt64) {
        precondition(cpuCount >= 1, "CPU count must be positive")
        precondition(memoryMiB >= 1024, "memory must satisfy the balloon floor")
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
    }

    public static func resolve(for facts: SharedVMHardwareFacts) -> Self {
        let activeCPUCount = max(1, facts.activeCPUCount)
        let performanceCoreCount = validPerformanceCoreCount(
            facts.performanceCoreCount, activeCPUCount: activeCPUCount)
        let hostLimitedCPUCount = activeCPUCount > 2 ? activeCPUCount - 2 : 1
        let cpuCount = max(1, min(8, min(performanceCoreCount, hostLimitedCPUCount)))
        let memoryMiB = resolvedMemoryMiB(physicalMemoryMiB: facts.physicalMemoryMiB)
        assert((1...8).contains(cpuCount), "policy must produce a supported CPU count")
        assert(memoryMiB >= 1024, "policy must satisfy the balloon floor")
        assert(cpuCount <= activeCPUCount, "guest CPUs cannot exceed active host CPUs")
        assert(cpuCount <= performanceCoreCount, "guest CPUs cannot exceed eligible host CPUs")
        return Self(cpuCount: cpuCount, memoryMiB: memoryMiB)
    }

    public static func current() -> Self {
        let facts = SharedVMHardwareFacts.discover()
        assert(facts.activeCPUCount > 0, "discovery must report an active CPU")
        assert(facts.physicalMemoryMiB > 0, "discovery must report physical memory")
        return resolve(for: facts)
    }

    private static func validPerformanceCoreCount(_ count: Int?, activeCPUCount: Int) -> Int {
        precondition(activeCPUCount >= 1, "active CPU count must be normalized")
        guard let count, count > 0, count <= activeCPUCount else { return activeCPUCount }
        assert(count <= activeCPUCount, "performance cores cannot exceed active CPUs")
        return count
    }

    private static func resolvedMemoryMiB(physicalMemoryMiB: UInt64) -> UInt64 {
        let quarterMemory = physicalMemoryMiB / 4
        var memoryMiB = min(8192, max(2048, quarterMemory))
        if physicalMemoryMiB > 4096 {
            memoryMiB = min(memoryMiB, physicalMemoryMiB - 4096)
        }
        memoryMiB = max(1024, memoryMiB)
        assert(memoryMiB >= 1024, "memory must satisfy the balloon floor")
        assert(memoryMiB <= 8192, "memory must respect the guest cap")
        return memoryMiB
    }
}
