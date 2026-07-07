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

final class PrivateCoreGraphics {
    private let handle: UnsafeMutableRawPointer
    private let setEnabled: CGSSetDisplayEnabledFunction?
    private let configureEnabled: CGSConfigureDisplayEnabledFunction?
    private let getEnabled: CGSGetDisplayEnabledFunction?

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
                throw CLIError.ddcFailed(Display(index: 0, id: 0, name: "packet", vendor: 0, product: 0, serial: 0, bounds: .zero, isMain: false, isBuiltin: false, isActive: false, isOnline: false, enabled: nil), ["empty packet"])
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
      screenoff off <display> [--force-main] [--backend auto|ddc|m1ddc|coregraphics]
      screenoff on <display|all> [--backend auto|ddc|m1ddc|coregraphics]
      screenoff toggle <display> [--force-main]

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

func fetchDisplays(coreGraphics: PrivateCoreGraphics? = nil) throws -> [Display] {
    var count: UInt32 = 0
    var result = CGGetOnlineDisplayList(0, nil, &count)
    guard result == .success else {
        throw CLIError.coreGraphicsFailed("Read display count", result)
    }

    var ids = Array(repeating: CGDirectDisplayID(0), count: Int(count))
    result = CGGetOnlineDisplayList(count, &ids, &count)
    guard result == .success else {
        throw CLIError.coreGraphicsFailed("Read display list", result)
    }

    let names = displayNameMap()
    let mainID = CGMainDisplayID()

    return ids.prefix(Int(count)).enumerated().map { offset, id in
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let key = "\(vendor):\(product):\(serial)"
        let fallbackKey = "\(vendor):\(product):0"
        let name = names[key] ?? names[fallbackKey] ?? "Display \(id)"
        return Display(
            index: offset + 1,
            id: id,
            name: name,
            vendor: vendor,
            product: product,
            serial: serial,
            bounds: CGDisplayBounds(id),
            isMain: id == mainID,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            enabled: coreGraphics?.enabled(display: id)
        )
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
            flags: displayFlags(display)
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

func syntheticDisplay(id: CGDirectDisplayID, selector: String) -> Display {
    Display(
        index: Int(id),
        id: id,
        name: "Display \(selector)",
        vendor: 0,
        product: 0,
        serial: 0,
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

enum Backend: String {
    case auto
    case ddc
    case coreGraphics = "coregraphics"
    case m1ddc
}

func setDisplay(_ display: Display, enabled: Bool, backend: Backend) throws {
    switch backend {
    case .coreGraphics:
        try PrivateCoreGraphics().set(display: display.id, enabled: enabled)
    case .ddc:
        try DDCController().setPowerMode(enabled ? .on : .off, for: display)
    case .m1ddc:
        try M1DDCController().setPowerMode(enabled ? .on : .off, for: display)
    case .auto:
        do {
            try PrivateCoreGraphics().set(display: display.id, enabled: enabled)
        } catch {
            let coreGraphicsError = error
            do {
                try DDCController().setPowerMode(enabled ? .on : .off, for: display)
            } catch {
                let ddcError = error
                do {
                    try M1DDCController().setPowerMode(enabled ? .on : .off, for: display)
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

func canRestoreSyntheticDisplay(command: String, backend: Backend) -> Bool {
    command == "on" && (backend == .coreGraphics || backend == .auto)
}

func run(arguments: [String]) throws {
    guard let command = arguments.first else {
        throw CLIError.usage(usage())
    }

    switch command {
    case "help", "-h", "--help":
        print(usage())

    case "list":
        let coreGraphics = try? PrivateCoreGraphics()
        let displays = try fetchDisplays(coreGraphics: coreGraphics)
        if containsFlag("--json", in: arguments) {
            try printDisplaysJSON(displays)
        } else {
            printDisplays(displays)
        }

    case "off", "on", "toggle":
        let coreGraphics = try? PrivateCoreGraphics()
        let displays = try fetchDisplays(coreGraphics: coreGraphics)

        guard arguments.count >= 2 else {
            throw CLIError.usage(usage())
        }

        let forceMain = containsFlag("--force-main", in: arguments)
        let backendName = optionValue("--backend", in: arguments) ?? "auto"
        guard let backend = Backend(rawValue: backendName) else {
            throw CLIError.usage("Unknown backend '\(backendName)'. Use auto, ddc, m1ddc, or coregraphics.")
        }
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

        try setDisplay(display, enabled: shouldEnable, backend: backend)
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
