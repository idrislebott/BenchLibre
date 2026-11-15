import Foundation
import Metal
import IOKit.ps
import Darwin

public enum SystemInfo {
    private static func sysctlString(_ name: String) -> String {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0, count <= 4_096 else { return "" }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctlbyname(name, &bytes, &count, nil, 0) == 0, count > 0, count <= bytes.count else { return "" }
        let end = bytes[..<count].firstIndex(of: 0) ?? count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    public static func capture() -> HardwareSummary {
        let rawChip = sysctlString("machdep.cpu.brand_string")
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Metal indisponible"
        let model = sysctlString("hw.model")
        let power: String
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            let value = source as String
            power = value == "AC Power" ? "Secteur" : value == "Battery Power" ? "Batterie" : value
        } else { power = "Inconnue" }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return HardwareSummary(model: model.isEmpty ? "Mac" : model,
                               chip: rawChip.isEmpty ? gpu : rawChip,
                               gpu: gpu, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                               logicalCores: ProcessInfo.processInfo.activeProcessorCount,
                               operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                               architecture: architecture, powerSource: power)
    }

    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Modéré"
        case .serious: return "Élevé"
        case .critical: return "Critique"
        @unknown default: return "Inconnu"
        }
    }
}
