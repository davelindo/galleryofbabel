@preconcurrency import Darwin
import Foundation

struct ProcessMemorySnapshot {
    let residentBytes: UInt64
    let physFootprintBytes: UInt64
}

enum ProcessMemory {
    static func snapshot() -> ProcessMemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return ProcessMemorySnapshot(residentBytes: info.resident_size, physFootprintBytes: info.phys_footprint)
    }
}
