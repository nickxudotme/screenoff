import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.i2c
import IOKit.graphics

struct Display: Equatable {
    let index: Int
    let id: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    let systemUUID: String?
    let bounds: CGRect
    let isMain: Bool
    let isBuiltin: Bool
    let isActive: Bool
    let isOnline: Bool
    let enabled: Bool?
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case coreGraphicsSymbolMissing(String)
    case displayNotFound(String)
    case ambiguousDisplay(String, [Display])
    case refusingMainDisplay(Display)
    case coreGraphicsFailed(String, CGError)
    case iokitFailed(String, IOReturn)
    case ddcUnavailable(Display)
    case ddcFailed(Display, [String])
    case helperMissing(String)
    case helperFailed(String, Int32, String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .coreGraphicsSymbolMissing(let name):
            return "CoreGraphics symbol \(name) is not available on this macOS version."
        case .displayNotFound(let query):
            return "No display matched '\(query)'. Run `screenoff list` to see available displays."
        case .ambiguousDisplay(let query, let displays):
            let matches = displays.map { "#\($0.index) \($0.name) [id=\($0.id)]" }.joined(separator: ", ")
            return "'\(query)' matched multiple displays: \(matches)"
        case .refusingMainDisplay(let display):
            return "Refusing to disable the main display (#\(display.index) \(display.name)). Add --force-main if you really want this."
        case .coreGraphicsFailed(let operation, let error):
            return "\(operation) failed with CGError(\(error.rawValue))."
        case .iokitFailed(let operation, let result):
            return "\(operation) failed with IOReturn(\(String(format: "0x%08x", result)))."
        case .ddcUnavailable(let display):
            return "Display #\(display.index) \(display.name) does not expose an I2C/DDC interface."
        case .ddcFailed(let display, let errors):
            return "DDC/CI command failed for #\(display.index) \(display.name): \(errors.joined(separator: "; "))"
        case .helperMissing(let name):
            return "Required helper '\(name)' was not found next to screenoff or in PATH."
        case .helperFailed(let name, let status, let output):
            return "\(name) failed with exit code \(status). \(output)"
        }
    }
}

typealias CGSSetDisplayEnabledFunction = @convention(c) (CGDirectDisplayID, Bool) -> CGError
typealias CGSGetDisplayEnabledFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> CGError
typealias CGSConfigureDisplayEnabledFunction = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias CGDisplayIOServicePortFunction = @convention(c) (CGDirectDisplayID) -> io_service_t
typealias CoreDisplayCreateInfoDictionaryFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
typealias CGSGetDisplayListFunction = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
typealias CGDisplayCreateUUIDFromDisplayIDFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?

final class PrivateCoreGraphics {
    private let handle: UnsafeMutableRawPointer
    private let setEnabled: CGSSetDisplayEnabledFunction?
    private let configureEnabled: CGSConfigureDisplayEnabledFunction?
    private let getEnabled: CGSGetDisplayEnabledFunction?
    private let getDisplayList: CGSGetDisplayListFunction?

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
            throw CLIError.coreGraphicsSymbolMissing("CoreGraphics")
        }
        self.handle = handle

        if let setSymbol = dlsym(handle, "CGSSetDisplayEnabled") {
            self.setEnabled = unsafeBitCast(setSymbol, to: CGSSetDisplayEnabledFunction.self)
        } else {
            self.setEnabled = nil
        }

        if let configureSymbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
            self.configureEnabled = unsafeBitCast(configureSymbol, to: CGSConfigureDisplayEnabledFunction.self)
        } else {
            self.configureEnabled = nil
        }

        if self.setEnabled == nil, self.configureEnabled == nil {
            throw CLIError.coreGraphicsSymbolMissing("CGSConfigureDisplayEnabled/CGSSetDisplayEnabled")
        }

        if let getSymbol = dlsym(handle, "CGSGetDisplayEnabled") {
            self.getEnabled = unsafeBitCast(getSymbol, to: CGSGetDisplayEnabledFunction.self)
        } else {
            self.getEnabled = nil
        }

        if let listSymbol = dlsym(handle, "CGSGetDisplayList") {
            self.getDisplayList = unsafeBitCast(listSymbol, to: CGSGetDisplayListFunction.self)
        } else {
            self.getDisplayList = nil
        }
    }

    deinit {
        dlclose(handle)
    }

    func set(display id: CGDirectDisplayID, enabled: Bool) throws {
        if let configureEnabled {
            var config: CGDisplayConfigRef?
            var result = CGBeginDisplayConfiguration(&config)
            guard result == .success else {
                throw CLIError.coreGraphicsFailed("Begin display configuration", result)
            }

            result = configureEnabled(config, id, enabled)
            guard result == .success else {
                CGCancelDisplayConfiguration(config)
                throw CLIError.coreGraphicsFailed(enabled ? "Configure enable display \(id)" : "Configure disable display \(id)", result)
            }

            result = CGCompleteDisplayConfiguration(config, .permanently)
            if enabled, result.rawValue == 1001 {
                return
            }
            guard result == .success else {
                throw CLIError.coreGraphicsFailed(enabled ? "Commit enable display \(id)" : "Commit disable display \(id)", result)
            }
            return
        }

        if let setEnabled {
            let result = setEnabled(id, enabled)
            guard result == .success else {
                throw CLIError.coreGraphicsFailed(enabled ? "Enable display \(id)" : "Disable display \(id)", result)
            }
            return
        }

        throw CLIError.coreGraphicsSymbolMissing("CGSConfigureDisplayEnabled/CGSSetDisplayEnabled")
    }

    func enabled(display id: CGDirectDisplayID) -> Bool? {
        guard let getEnabled else {
            return nil
        }
        var enabled = false
        let result = getEnabled(id, &enabled)
        return result == .success ? enabled : nil
    }

    /// Unlike CGGetOnlineDisplayList, this WindowServer inventory keeps a display
    /// that ScreenOff disconnected. That makes reconnect work even if ScreenOff's
    /// own restore-history file was removed.
    func allDisplayIDs() -> [CGDirectDisplayID]? {
        guard let getDisplayList else { return nil }
        var count: UInt32 = 0
        let countResult = getDisplayList(0, nil, &count)
        guard countResult == .success else { return nil }
        var ids = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        let listResult = getDisplayList(count, &ids, &count)
        guard listResult == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }
}

enum DisplayPowerMode: UInt16 {
    case on = 0x01
    case standby = 0x02
    case suspend = 0x03
    case off = 0x04
    case hardOff = 0x05
}

struct DDCController {
    private let ddcWriteAddress: UInt8 = 0x6e
    private let hostAddress: UInt8 = 0x51
    private let setVCPCommand: UInt8 = 0x03
    private let powerModeVCP: UInt8 = 0xd6

    private func framebuffer(for display: Display) -> io_service_t {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
            return 0
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "CGDisplayIOServicePort") else {
            return 0
        }

        let function = unsafeBitCast(symbol, to: CGDisplayIOServicePortFunction.self)
        return function(display.id)
    }

    private func candidateFramebuffers(for display: Display) -> [io_service_t] {
        var candidates: [io_service_t] = []
        _ = display

        for className in ["IOFramebuffer", "IOMobileFramebufferShim"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == kIOReturnSuccess else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 {
                    break
                }
                if !candidates.contains(service) {
                    candidates.append(service)
                } else {
                    IOObjectRelease(service)
                }
            }
        }

        return candidates
    }

    func setPowerMode(_ mode: DisplayPowerMode, for display: Display) throws {
        guard !display.isBuiltin else {
            throw CLIError.ddcUnavailable(display)
        }

        let framebuffers = candidateFramebuffers(for: display)
        guard !framebuffers.isEmpty else {
            throw CLIError.ddcUnavailable(display)
        }
        defer {
            for framebuffer in framebuffers {
                IOObjectRelease(framebuffer)
            }
        }

        var errors: [String] = []
        for (framebufferIndex, framebuffer) in framebuffers.enumerated() {
            var busCount: IOItemCount = 0
            let countResult = IOFBGetI2CInterfaceCount(framebuffer, &busCount)
            guard countResult == kIOReturnSuccess else {
                errors.append("framebuffer \(framebufferIndex): I2C count failed \(String(format: "0x%08x", countResult))")
                continue
            }

            if busCount == 0 {
                errors.append("framebuffer \(framebufferIndex): no I2C bus")
                continue
            }

            for bus in 0..<busCount {
                do {
                    try sendSetVCP(mode.rawValue, feature: powerModeVCP, framebuffer: framebuffer, bus: IOOptionBits(bus))
                    return
                } catch let error as CLIError {
                    errors.append("framebuffer \(framebufferIndex) bus \(bus): \(error.description)")
                } catch {
                    errors.append("framebuffer \(framebufferIndex) bus \(bus): \(error.localizedDescription)")
                }
            }
        }

        throw CLIError.ddcFailed(display, errors)
    }

    private func sendSetVCP(_ value: UInt16, feature: UInt8, framebuffer: io_service_t, bus: IOOptionBits) throws {
        var interface: io_service_t = 0
        let copyResult = IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface)
        guard copyResult == kIOReturnSuccess, interface != 0 else {
            throw CLIError.iokitFailed("Open I2C bus \(bus)", copyResult)
        }
        defer { IOObjectRelease(interface) }

        var connect: IOI2CConnectRef?
        let openResult = IOI2CInterfaceOpen(interface, IOOptionBits(0), &connect)
        guard openResult == kIOReturnSuccess, let connect else {
            throw CLIError.iokitFailed("Connect to I2C bus \(bus)", openResult)
        }
        defer { IOI2CInterfaceClose(connect, IOOptionBits(0)) }

        var packet = ddcSetVCPPacket(feature: feature, value: value)
        try packet.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CLIError.ddcFailed(Display(index: 0, id: 0, name: "packet", vendor: 0, product: 0, serial: 0, systemUUID: nil, bounds: .zero, isMain: false, isBuiltin: false, isActive: false, isOnline: false, enabled: nil), ["empty packet"])
            }

            var request = IOI2CRequest()
            request.sendAddress = UInt32(ddcWriteAddress)
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer = vm_address_t(UInt(bitPattern: baseAddress))
            request.sendBytes = UInt32(buffer.count)
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)

            let sendResult = IOI2CSendRequest(connect, IOOptionBits(0), &request)
            guard sendResult == kIOReturnSuccess else {
                throw CLIError.iokitFailed("Send DDC/CI request", sendResult)
            }
            guard request.result == kIOReturnSuccess else {
                throw CLIError.iokitFailed("Run DDC/CI request", request.result)
            }
        }
    }

    private func ddcSetVCPPacket(feature: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            hostAddress,
            0x80 | 0x04,
            setVCPCommand,
            feature,
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
            0
        ]

        var checksum = ddcWriteAddress
        for byte in packet.dropLast() {
            checksum ^= byte
        }
        packet[packet.count - 1] = checksum
        return packet
    }
}

struct M1DDCController {
    func setPowerMode(_ mode: DisplayPowerMode, for display: Display) throws {
        guard !display.isBuiltin else {
            throw CLIError.ddcUnavailable(display)
        }

        let helper = try helperURL()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["display", "\(display.index)", "set", "standby", "\(mode.rawValue)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw CLIError.helperFailed(helper.lastPathComponent, process.terminationStatus, output)
        }
    }

    private func helperURL() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundled = executable.deletingLastPathComponent().appendingPathComponent("m1ddc")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        for directory in pathDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("m1ddc")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw CLIError.helperMissing("m1ddc")
    }

    private func pathDirectories() -> [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
    }
}

func usage() -> String {
    """
    Usage:
      screenoff list [--json]
      screenoff disconnect <display|all> [--force-main] [--backend auto|ddc|m1ddc|coregraphics]
      screenoff reconnect <display|all> [--backend auto|ddc|m1ddc|coregraphics]
      screenoff toggle <external|all> [--backend auto|ddc|m1ddc|coregraphics]

    Legacy compatibility:
      screenoff off <display> [--force-main] [--backend auto|ddc|m1ddc|coregraphics]
      screenoff on <display|all> [--backend auto|ddc|m1ddc|coregraphics]
      screenoff toggle <display> [--force-main]
      screenoff external <on|off|toggle> [--backend auto|ddc|m1ddc|coregraphics]

    Display selectors:
      1234567890      display id
      #2              1-based index from `list`
      studio          case-insensitive name fragment
    """
}

struct DisplayJSON: Encodable {
    let index: Int
    let id: UInt32
    let name: String
    let state: String
    let geometry: String
    let flags: [String]
    let identity: String?
    let uuid: String?
}

/// `CGDirectDisplayID` is a routing handle, not a persistent monitor identity. Only
/// expose an EDID-derived key when all fields are meaningful; many displays report
/// serial 0, and using that would incorrectly merge identical monitors.
func displayIdentity(vendor: UInt32, product: UInt32, serial: UInt32) -> String? {
    guard vendor != 0, vendor != UInt32.max,
          product != 0, product != UInt32.max,
          serial != 0, serial != UInt32.max else {
        return nil
    }
    return "edid:\(vendor):\(product):\(serial)"
}

/// Return the display that owns a CoreGraphics mirror set. A mirror member is a
/// second system-facing display ID for the same visible surface and must not become
/// another row or another target for `on all`.
func effectiveDisplayID(_ id: CGDirectDisplayID) -> CGDirectDisplayID {
    var effective = id
    var visited = Set<CGDirectDisplayID>()
    while !visited.contains(effective),
          CGDisplayIsInMirrorSet(effective) != 0 || CGDisplayIsInHWMirrorSet(effective) != 0 {
        visited.insert(effective)
        let mirrorMaster = CGDisplayMirrorsDisplay(effective)
        guard mirrorMaster != 0, mirrorMaster != effective else { break }
        effective = mirrorMaster
    }
    return effective
}

func displayNameMap() -> [String: String] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
        return [:]
    }
    defer { IOObjectRelease(iterator) }

    var names: [String: String] = [:]
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 {
            break
        }
        defer { IOObjectRelease(service) }

        guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as? [String: Any] else {
            continue
        }

        let vendor = (info[kDisplayVendorID as String] as? NSNumber)?.uint32Value ?? 0
        let product = (info[kDisplayProductID as String] as? NSNumber)?.uint32Value ?? 0
        let serial = (info[kDisplaySerialNumber as String] as? NSNumber)?.uint32Value ?? 0
        let productNames = info[kDisplayProductName as String] as? [String: String]
        let name = productNames?.values.first

        if let name, !name.isEmpty {
            names["\(vendor):\(product):\(serial)"] = name
            names["\(vendor):\(product):0"] = name
        }
    }

    return names
}

/// CoreGraphics display IDs do not reliably map back to `IODisplayConnect` on
/// Apple Silicon. CoreDisplay owns that mapping and exposes the localized EDID
/// product name in its per-display information dictionary.
func coreDisplayInfo(for id: CGDirectDisplayID) -> [String: Any]? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW) else {
        return nil
    }
    defer { dlclose(handle) }

    guard let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
        return nil
    }

    let createInfoDictionary = unsafeBitCast(symbol, to: CoreDisplayCreateInfoDictionaryFunction.self)
    return createInfoDictionary(id)?.takeRetainedValue() as? [String: Any]
}

func systemDisplayUUID(for id: CGDirectDisplayID) -> String? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
        return nil
    }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else { return nil }
    let createUUID = unsafeBitCast(symbol, to: CGDisplayCreateUUIDFromDisplayIDFunction.self)
    guard let value = createUUID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, value) as String
}

func coreDisplayName(from dictionary: [String: Any]?) -> String? {
    guard let dictionary else { return nil }
    if let names = dictionary["DisplayProductName"] as? [String: String] {
        let name = names[Locale.current.identifier]
            ?? names["en_US"]
            ?? names.values.first(where: { !$0.isEmpty })
        return name?.isEmpty == false ? name : nil
    }
    let name = dictionary["DisplayProductName"] as? String
    return name?.isEmpty == false ? name : nil
}

func preferredDisplayProductName(from info: [String: Any]) -> String? {
    guard let names = info[kDisplayProductName as String] as? [String: String] else {
        return nil
    }
    return names[Locale.current.identifier]
        ?? names["en_US"]
        ?? names.values.first(where: { !$0.isEmpty })
}

/// Ask CoreGraphics for the exact framebuffer belonging to this display, then
/// walk its service ancestry. This is the reliable IOKit path when a global
/// `IODisplayConnect` scan cannot be correlated with Apple-Silicon display IDs.
func ioRegistryDisplayName(for id: CGDirectDisplayID) -> String? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else {
        return nil
    }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "CGDisplayIOServicePort") else {
        return nil
    }

    let service = unsafeBitCast(symbol, to: CGDisplayIOServicePortFunction.self)(id)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var entry = service
    for _ in 0..<16 {
        if let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as? [String: Any],
           let name = preferredDisplayProductName(from: info) {
            if entry != service { IOObjectRelease(entry) }
            return name
        }

        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
            break
        }
        if entry != service { IOObjectRelease(entry) }
        entry = parent
    }
    if entry != service { IOObjectRelease(entry) }
    return nil
}

/// `system_profiler` is Apple's public-facing inventory view. It includes the
/// display ID next to the user-readable model name, which makes it a safe final
/// fallback on macOS releases where CoreDisplay and IOKit do not expose the
/// CoreGraphics-to-EDID association to third-party processes.
func systemProfilerDisplayNameMap() -> [CGDirectDisplayID: String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["-xml", "SPDisplaysDataType"]
    let output = Pipe()
    process.standardOutput = output

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: output.fileHandleForReading.readDataToEndOfFile(), options: [], format: nil)

        var names: [CGDirectDisplayID: String] = [:]
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let rawID = dictionary["_spdisplays_displayID"] as? String,
                   let id = CGDirectDisplayID(rawID),
                   let name = dictionary["_name"] as? String,
                   !name.isEmpty {
                    names[id] = name
                }
                dictionary.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(plist)
        return names
    } catch {
        return [:]
    }
}

func fetchDisplays(coreGraphics: PrivateCoreGraphics? = nil) throws -> [Display] {
    let ids: [CGDirectDisplayID]
    if let inventory = coreGraphics?.allDisplayIDs(), !inventory.isEmpty {
        ids = inventory
    } else {
        var count: UInt32 = 0
        var result = CGGetOnlineDisplayList(0, nil, &count)
        guard result == .success else {
            throw CLIError.coreGraphicsFailed("Read display count", result)
        }

        var onlineIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        result = CGGetOnlineDisplayList(count, &onlineIDs, &count)
        guard result == .success else {
            throw CLIError.coreGraphicsFailed("Read display list", result)
        }
        ids = Array(onlineIDs.prefix(Int(count)))
    }

    let names = displayNameMap()
    let profilerNames = systemProfilerDisplayNameMap()
    let mainID = CGMainDisplayID()

    let candidates = ids.compactMap { id -> Display? in
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let coreInfo = coreDisplayInfo(for: id)
        let uuid = systemDisplayUUID(for: id) ?? coreInfo?["kCGDisplayUUID"] as? String
        // CGSGetDisplayList includes reserved WindowServer slots (for example
        // ids 2–4 on this Mac). They are not a connected or disconnected panel.
        guard vendor != 0 || product != 0 || (uuid != nil && uuid != "00000000-0000-0000-0000-000000000000") else {
            return nil
        }
        let key = "\(vendor):\(product):\(serial)"
        let fallbackKey = "\(vendor):\(product):0"
        let name = coreDisplayName(from: coreInfo)
            ?? ioRegistryDisplayName(for: id)
            ?? profilerNames[id]
            ?? names[key]
            ?? names[fallbackKey]
            ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
        return Display(
            index: 0,
            id: id,
            name: name,
            vendor: vendor,
            product: product,
            serial: serial,
            systemUUID: uuid,
            bounds: CGDisplayBounds(id),
            isMain: id == mainID,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            enabled: coreGraphics?.enabled(display: id)
        )
    }

    // Keep one concrete operation target per mirror set. Prefer the effective/master
    // ID, then the main display, then an active member. Do not deduplicate merely by
    // EDID: two physical monitors can share incomplete or duplicate EDID fields.
    let grouped = Dictionary(grouping: candidates, by: { effectiveDisplayID($0.id) })
    return grouped.values.compactMap { members in
        members.sorted { lhs, rhs in
            let lhsEffective = lhs.id == effectiveDisplayID(lhs.id)
            let rhsEffective = rhs.id == effectiveDisplayID(rhs.id)
            if lhsEffective != rhsEffective { return lhsEffective }
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.id < rhs.id
        }.first
    }
    .sorted { lhs, rhs in
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        return lhs.id < rhs.id
    }
    .enumerated()
    .map { offset, display in
        Display(index: offset + 1, id: display.id, name: display.name, vendor: display.vendor, product: display.product, serial: display.serial, systemUUID: display.systemUUID, bounds: display.bounds, isMain: display.isMain, isBuiltin: display.isBuiltin, isActive: display.isActive, isOnline: display.isOnline, enabled: display.enabled)
    }
}

func displayState(_ display: Display) -> String {
    display.enabled.map { $0 ? "enabled" : "disabled" } ?? (display.isActive ? "active" : "inactive")
}

func displayFlags(_ display: Display) -> [String] {
    [
        display.isMain ? "main" : nil,
        display.isBuiltin ? "built-in" : nil,
        display.isOnline ? "online" : "offline"
    ].compactMap { $0 }
}

func displayGeometry(_ display: Display) -> String {
    let width = Int(display.bounds.width)
    let height = Int(display.bounds.height)
    let x = Int(display.bounds.origin.x)
    let y = Int(display.bounds.origin.y)
    return "\(width)x\(height)+\(x)+\(y)"
}

func printDisplays(_ displays: [Display]) {
    for display in displays {
        let flags = displayFlags(display).joined(separator: ", ")
        print("#\(display.index) id=\(display.id) \(displayState(display)) \(displayGeometry(display)) \(flags) \(display.name)")
    }
}

func printDisplaysJSON(_ displays: [Display]) throws {
    let payload = displays.map { display in
        DisplayJSON(
            index: display.index,
            id: display.id,
            name: display.name,
            state: displayState(display),
            geometry: displayGeometry(display),
            flags: displayFlags(display),
            identity: displayIdentity(vendor: display.vendor, product: display.product, serial: display.serial),
            uuid: display.systemUUID
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    guard let output = String(data: data, encoding: .utf8) else {
        throw CLIError.usage("Failed to encode display list as JSON.")
    }
    print(output)
}

func resolveDisplay(_ query: String, in displays: [Display]) throws -> Display {
    if query.hasPrefix("#"), let index = Int(query.dropFirst()) {
        if let display = displays.first(where: { $0.index == index }) {
            return display
        }
        throw CLIError.displayNotFound(query)
    }

    if let id = CGDirectDisplayID(query) {
        if let display = displays.first(where: { $0.id == id }) {
            return display
        }
        throw CLIError.displayNotFound(query)
    }

    let lowered = query.localizedLowercase
    let matches = displays.filter { $0.name.localizedLowercase.contains(lowered) }
    if matches.count == 1 {
        return matches[0]
    }
    if matches.isEmpty {
        throw CLIError.displayNotFound(query)
    }
    throw CLIError.ambiguousDisplay(query, matches)
}

func syntheticDisplay(id: CGDirectDisplayID, selector: String, name: String? = nil, index: Int? = nil, systemUUID: String? = nil) -> Display {
    Display(
        index: index ?? Int(id),
        id: id,
        name: name ?? "Display \(selector)",
        vendor: 0,
        product: 0,
        serial: 0,
        systemUUID: systemUUID,
        bounds: .zero,
        isMain: false,
        isBuiltin: false,
        isActive: false,
        isOnline: false,
        enabled: false
    )
}

func containsFlag(_ flag: String, in arguments: [String]) -> Bool {
    arguments.contains(flag)
}

func optionValue(_ name: String, in arguments: [String]) -> String? {
    for (index, argument) in arguments.enumerated() {
        if argument == name, arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if argument.hasPrefix("\(name)=") {
            return String(argument.dropFirst(name.count + 1))
        }
    }
    return nil
}

enum Backend: String, Codable {
    case auto
    case ddc
    case coreGraphics = "coregraphics"
    case m1ddc
}

@discardableResult
func setDisplay(_ display: Display, enabled: Bool, backend: Backend) throws -> Backend {
    switch backend {
    case .coreGraphics:
        try PrivateCoreGraphics().set(display: display.id, enabled: enabled)
        return .coreGraphics
    case .ddc:
        try DDCController().setPowerMode(enabled ? .on : .off, for: display)
        return .ddc
    case .m1ddc:
        try M1DDCController().setPowerMode(enabled ? .on : .off, for: display)
        return .m1ddc
    case .auto:
        do {
            try PrivateCoreGraphics().set(display: display.id, enabled: enabled)
            return .coreGraphics
        } catch {
            let coreGraphicsError = error
            do {
                try DDCController().setPowerMode(enabled ? .on : .off, for: display)
                return .ddc
            } catch {
                let ddcError = error
                do {
                    try M1DDCController().setPowerMode(enabled ? .on : .off, for: display)
                    return .m1ddc
                } catch {
                    throw CLIError.ddcFailed(display, [
                        "coregraphics: \(coreGraphicsError)",
                        "ddc: \(ddcError)",
                        "m1ddc: \(error)"
                    ])
                }
            }
        }
    }
}

private struct DisabledExternalDisplay: Codable {
    let id: CGDirectDisplayID
    let name: String
    let uuid: String?
    let identity: String?

    init(id: CGDirectDisplayID, name: String, uuid: String? = nil, identity: String? = nil) {
        self.id = id
        self.name = name
        self.uuid = uuid
        self.identity = identity
    }
}

private func disabledExternalDisplaysURL() throws -> URL {
    let manager = FileManager.default
    guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw CLIError.usage("Could not locate Application Support for external-display restore history.")
    }
    let directory = base.appendingPathComponent("ScreenOff", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("disabled-external-displays.json")
}

private func loadDisabledExternalDisplays() throws -> [DisabledExternalDisplay] {
    let url = try disabledExternalDisplaysURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([DisabledExternalDisplay].self, from: Data(contentsOf: url))
}

private func saveDisabledExternalDisplays(_ displays: [DisabledExternalDisplay]) throws {
    let url = try disabledExternalDisplaysURL()
    try JSONEncoder().encode(displays).write(to: url, options: .atomic)
}

private func rememberDisconnectedDisplay(_ display: Display) throws {
    guard !display.isBuiltin else { return }
    var remembered = try loadDisabledExternalDisplays()
    let identity = displayIdentity(vendor: display.vendor, product: display.product, serial: display.serial)
    remembered.removeAll {
        $0.id == display.id
            || (display.systemUUID != nil && $0.uuid == display.systemUUID)
            || (identity != nil && $0.identity == identity)
    }
    remembered.append(DisabledExternalDisplay(id: display.id, name: display.name, uuid: display.systemUUID, identity: identity))
    try saveDisabledExternalDisplays(remembered)
}

private func forgetDisconnectedDisplay(id: CGDirectDisplayID) throws {
    var remembered = try loadDisabledExternalDisplays()
    remembered.removeAll { $0.id == id }
    try saveDisabledExternalDisplays(remembered)
}

private func externalDisplays(in displays: [Display]) -> [Display] {
    displays.filter { !$0.isBuiltin }
}

private func connectedExternalDisplays(in displays: [Display]) -> [Display] {
    externalDisplays(in: displays).filter { display in
        display.isOnline && display.enabled != false
    }
}

private func isFallbackDisplayName(_ name: String, id: CGDirectDisplayID) -> Bool {
    name.isEmpty || name == "Display \(id)"
}

private func withCachedName(_ display: Display, name: String) -> Display {
    Display(
        index: display.index,
        id: display.id,
        name: name,
        vendor: display.vendor,
        product: display.product,
        serial: display.serial,
        systemUUID: display.systemUUID,
        bounds: display.bounds,
        isMain: display.isMain,
        isBuiltin: display.isBuiltin,
        isActive: display.isActive,
        isOnline: display.isOnline,
        enabled: display.enabled
    )
}

/// Some display paths disappear entirely from WindowServer after a physical
/// unplug. Keep our last known identity only for that last-resort case. A
/// normal ScreenOff disconnect is returned by `CGSGetDisplayList` instead.
private func displaysIncludingDisabled(_ liveDisplays: [Display]) throws -> [Display] {
    let savedDisplays = try loadDisabledExternalDisplays()
    let liveIDs = Set(liveDisplays.map(\.id))
    let enrichedLiveDisplays = liveDisplays.map { display in
        guard !display.isBuiltin, isFallbackDisplayName(display.name, id: display.id),
              let saved = savedDisplays.first(where: { saved in
                  saved.id == display.id
                      || (display.systemUUID != nil && saved.uuid == display.systemUUID)
                      || (displayIdentity(vendor: display.vendor, product: display.product, serial: display.serial) != nil
                          && saved.identity == displayIdentity(vendor: display.vendor, product: display.product, serial: display.serial))
              }) else {
            return display
        }
        return withCachedName(display, name: saved.name)
    }
    let remembered = savedDisplays.filter { !liveIDs.contains($0.id) }
    return enrichedLiveDisplays + remembered.enumerated().map { offset, saved in
        syntheticDisplay(
            id: saved.id,
            selector: String(saved.id),
            name: saved.name,
            index: enrichedLiveDisplays.count + offset + 1,
            systemUUID: saved.uuid
        )
    }
}

private func externalBackend(arguments: [String]) throws -> Backend {
    let name = optionValue("--backend", in: arguments) ?? "auto"
    guard let backend = Backend(rawValue: name) else {
        throw CLIError.usage("Unknown backend '\(name)'. Use auto, ddc, m1ddc, or coregraphics.")
    }
    return backend
}

private func turnOffExternalDisplays(_ displays: [Display], backend: Backend) throws {
    for display in displays {
        let usedBackend = try setDisplay(display, enabled: false, backend: backend)
        print("disabled #\(display.index) \(display.name) [id=\(display.id)]")
        if usedBackend == .coreGraphics {
            try rememberDisconnectedDisplay(display)
        }
    }
}

private func turnOnExternalDisplays(_ displays: [Display], backend: Backend) throws {
    let liveIDs = Set(displays.map(\.id))
    for display in displays {
        _ = try setDisplay(display, enabled: true, backend: backend)
        print("enabled #\(display.index) \(display.name) [id=\(display.id)]")
    }

    for saved in try loadDisabledExternalDisplays() where !liveIDs.contains(saved.id) {
        let display = syntheticDisplay(id: saved.id, selector: String(saved.id))
        _ = try setDisplay(display, enabled: true, backend: .coreGraphics)
        print("enabled \(saved.name) [id=\(saved.id)]")
    }
    try saveDisabledExternalDisplays([])
}

func canRestoreSyntheticDisplay(command: String, backend: Backend) -> Bool {
    command == "on" && (backend == .coreGraphics || backend == .auto)
}

func run(arguments: [String]) throws {
    // The product model is connection state. Keep the earlier verbs working for
    // scripts, but make the unambiguous public commands first-class.
    var arguments = arguments
    if let command = arguments.first, ["disconnect", "reconnect"].contains(command) {
        guard arguments.count >= 2 else { throw CLIError.usage(usage()) }
        let target = arguments[1]
        if target == "all" {
            arguments[0] = "external"
            arguments[1] = command == "disconnect" ? "off" : "on"
        } else {
            arguments[0] = command == "disconnect" ? "off" : "on"
        }
    }
    if arguments.first == "toggle", arguments.count >= 2, ["external", "all"].contains(arguments[1]) {
        arguments[0] = "external"
        arguments[1] = "toggle"
    }
    guard let command = arguments.first else {
        throw CLIError.usage(usage())
    }

    switch command {
    case "help", "-h", "--help":
        print(usage())

    case "list":
        let coreGraphics = try? PrivateCoreGraphics()
        let displays = try displaysIncludingDisabled(fetchDisplays(coreGraphics: coreGraphics))
        if containsFlag("--json", in: arguments) {
            try printDisplaysJSON(displays)
        } else {
            printDisplays(displays)
        }

    case "external":
        guard arguments.count >= 2, ["on", "off", "toggle"].contains(arguments[1]) else {
            throw CLIError.usage(usage())
        }
        let backend = try externalBackend(arguments: arguments)
        let coreGraphics = try? PrivateCoreGraphics()
        let allDisplays = try displaysIncludingDisabled(fetchDisplays(coreGraphics: coreGraphics))
        let displays = externalDisplays(in: allDisplays)
        switch arguments[1] {
        case "off":
            try turnOffExternalDisplays(connectedExternalDisplays(in: allDisplays), backend: backend)
        case "on":
            try turnOnExternalDisplays(displays, backend: backend)
        case "toggle":
            let connected = connectedExternalDisplays(in: allDisplays)
            let hasDisconnected = displays.contains { display in
                !connected.contains(where: { $0.id == display.id })
            }
            if connected.isEmpty || hasDisconnected {
                try turnOnExternalDisplays(displays, backend: backend)
            } else {
                try turnOffExternalDisplays(connected, backend: backend)
            }
        default:
            break
        }

    case "off", "on", "toggle":
        let coreGraphics = try? PrivateCoreGraphics()
        let displays = try displaysIncludingDisabled(fetchDisplays(coreGraphics: coreGraphics))

        guard arguments.count >= 2 else {
            throw CLIError.usage(usage())
        }

        let forceMain = containsFlag("--force-main", in: arguments)
        let backend = try externalBackend(arguments: arguments)
        let selector = arguments[1]

        if command == "on", selector == "all" {
            for display in displays {
                try setDisplay(display, enabled: true, backend: backend)
                print("enabled #\(display.index) \(display.name) [id=\(display.id)]")
            }
            return
        }

        let display: Display
        do {
            display = try resolveDisplay(selector, in: displays)
        } catch CLIError.displayNotFound where canRestoreSyntheticDisplay(command: command, backend: backend) {
            let rawSelector = selector.hasPrefix("#") ? String(selector.dropFirst()) : selector
            guard let id = CGDirectDisplayID(rawSelector) else {
                throw CLIError.displayNotFound(selector)
            }
            display = syntheticDisplay(id: id, selector: selector)
        }
        if (command == "off" || command == "toggle"), display.isMain, !forceMain {
            throw CLIError.refusingMainDisplay(display)
        }

        let shouldEnable: Bool
        if command == "toggle" {
            shouldEnable = !(display.enabled ?? display.isActive)
        } else {
            shouldEnable = command == "on"
        }

        let usedBackend = try setDisplay(display, enabled: shouldEnable, backend: backend)
        if shouldEnable {
            try forgetDisconnectedDisplay(id: display.id)
        } else if usedBackend == .coreGraphics {
            try rememberDisconnectedDisplay(display)
        }
        print("\(shouldEnable ? "enabled" : "disabled") #\(display.index) \(display.name) [id=\(display.id)]")

    default:
        throw CLIError.usage(usage())
    }
}

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    fputs("screenoff: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("screenoff: \(error.localizedDescription)\n", stderr)
    exit(1)
}
