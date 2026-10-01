// M0 spike (throwaway, SPEC 3.4). Builds an aggregate of two output devices,
// sets preferred stereo channels to [1, 3], and makes it the default output,
// so left plays on Device A and right on Device B with no custom DSP.
//
//   swiftc -O Spike/M0/main.swift -o /tmp/domine-spike
//   domine-spike list
//   domine-spike run [uidA uidB]     (defaults to the two "JBL Grip" outputs)
//
// Ctrl-C restores the previous default output and destroys the aggregate.

import CoreAudio
import Foundation

let uidPrefix = "com.domine.spike.aggregate"

struct SpikeError: Error, CustomStringConvertible {
    let description: String
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(v)
}

func check(_ status: OSStatus, _ what: String, _ selector: AudioObjectPropertySelector = 0) throws {
    guard status == noErr else {
        throw SpikeError(description: "\(what) failed: \(fourCC(UInt32(bitPattern: status))) (selector \(fourCC(selector)))")
    }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getArray<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _: T.Type) throws -> [T] {
    var a = addr
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size), "GetPropertyDataSize", a.mSelector)
    let count = Int(size) / MemoryLayout<T>.stride
    if count == 0 { return [] }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { buf.deallocate() }
    try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, buf), "GetPropertyData", a.mSelector)
    return Array(UnsafeBufferPointer(start: buf.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
}

func getValue<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) throws -> T {
    var a = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value), "GetPropertyData", a.mSelector)
    return value
}

func getString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var a = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value), "GetPropertyData", selector)
    return value?.takeRetainedValue() as String? ?? ""
}

func setValue<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) throws {
    var a = addr
    var v = value
    try check(AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v), "SetPropertyData", a.mSelector)
}

func outputChannelCount(_ dev: AudioObjectID) throws -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size), "GetPropertyDataSize", a.mSelector)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    try check(AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw), "GetPropertyData", a.mSelector)
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func outputStreamLayout(_ dev: AudioObjectID) throws -> [Int] {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size), "GetPropertyDataSize", a.mSelector)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    try check(AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw), "GetPropertyData", a.mSelector)
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
}

struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
    let transport: UInt32
}

func allDevices() throws -> [Device] {
    let ids = try getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioObjectID.self)
    return try ids.map { id in
        Device(id: id,
               uid: try getString(id, kAudioDevicePropertyDeviceUID),
               name: try getString(id, kAudioObjectPropertyName),
               outputChannels: try outputChannelCount(id),
               transport: try getValue(id, address(kAudioDevicePropertyTransportType), UInt32(0)))
    }
}

func defaultOutput() throws -> AudioObjectID {
    try getValue(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
}

func setDefaultOutput(_ id: AudioObjectID) throws {
    try setValue(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), id)
}

func latencyReport(_ dev: AudioObjectID) -> String {
    let scope = kAudioObjectPropertyScopeOutput
    let rate = (try? getValue(dev, address(kAudioDevicePropertyNominalSampleRate), Float64(0))) ?? 0
    let lat = (try? getValue(dev, address(kAudioDevicePropertyLatency, scope), UInt32(0))) ?? 0
    let safety = (try? getValue(dev, address(kAudioDevicePropertySafetyOffset, scope), UInt32(0))) ?? 0
    let buffer = (try? getValue(dev, address(kAudioDevicePropertyBufferFrameSize), UInt32(0))) ?? 0
    var streamLat: UInt32 = 0
    if let streams = try? getArray(dev, address(kAudioDevicePropertyStreams, scope), AudioObjectID.self), let s = streams.first {
        streamLat = (try? getValue(s, address(kAudioStreamPropertyLatency), UInt32(0))) ?? 0
    }
    let total = lat + safety + streamLat + buffer
    let ms = rate > 0 ? Double(total) / rate * 1000 : 0
    return "rate \(Int(rate)) Hz, device latency \(lat), stream latency \(streamLat), safety \(safety), buffer \(buffer) frames = ~\(String(format: "%.1f", ms)) ms"
}

func destroyStaleAggregates() throws {
    for d in try allDevices() where d.uid.hasPrefix(uidPrefix) {
        print("Destroying stale aggregate \(d.uid)")
        try check(AudioHardwareDestroyAggregateDevice(d.id), "AudioHardwareDestroyAggregateDevice")
    }
}

func list() throws {
    let def = try defaultOutput()
    for d in try allDevices() where d.outputChannels > 0 {
        let bt = d.transport == kAudioDeviceTransportTypeBluetooth || d.transport == kAudioDeviceTransportTypeBluetoothLE
        print("\(d.id == def ? "*" : " ") \(d.name)  [\(bt ? "Bluetooth" : fourCC(d.transport))]  \(d.outputChannels) ch  uid=\(d.uid)")
    }
}

func run(_ args: [String]) throws {
    try destroyStaleAggregates()
    let devices = try allDevices()
    let a: Device, b: Device
    if args.count == 2 {
        guard let da = devices.first(where: { $0.uid == args[0] }),
              let db = devices.first(where: { $0.uid == args[1] }) else {
            throw SpikeError(description: "UID not found. Run `list`.")
        }
        (a, b) = (da, db)
    } else {
        let grips = devices.filter { $0.name == "JBL Grip" && $0.outputChannels > 0 }
        guard grips.count == 2 else {
            throw SpikeError(description: "Expected 2 outputs named \"JBL Grip\", found \(grips.count). If 1, the Grips may still be stereo-paired in the JBL Portable app. Or pass two UIDs.")
        }
        (a, b) = (grips[0], grips[1])
    }
    guard a.uid != b.uid else { throw SpikeError(description: "Devices must be distinct.") }

    print("Device A (LEFT):  \(a.name)  uid=\(a.uid)")
    print("Device B (RIGHT): \(b.name)  uid=\(b.uid)")

    for d in [a, b] {
        do {
            try setValue(d.id, address(kAudioDevicePropertyNominalSampleRate), Float64(48000))
        } catch {
            print("warning: could not set 48 kHz on \(d.uid): \(error)")
        }
    }

    let previous = try defaultOutput()
    let aggUID = "\(uidPrefix).\(UUID().uuidString)"
    // Not private: a private aggregate cannot be picked as system default output
    // by other processes, and this spike relies on the system routing to it.
    // DOMINE_CLOCK=builtin: clock from the built-in output, both Grips drift
    // corrected at max quality (tests the 44.1 kHz AAC encoder finding).
    let clock = ProcessInfo.processInfo.environment["DOMINE_CLOCK"] == "builtin"
        ? devices.first { $0.uid == "BuiltInSpeakerDevice" } : nil
    let maxQ = kAudioSubDeviceDriftCompensationMaxQuality
    var subs: [[String: Any]] = []
    if let clock { subs.append([kAudioSubDeviceUIDKey: clock.uid, kAudioSubDeviceDriftCompensationKey: 0]) }
    subs.append([kAudioSubDeviceUIDKey: a.uid, kAudioSubDeviceDriftCompensationKey: clock == nil ? 0 : 1,
                 kAudioSubDeviceDriftCompensationQualityKey: maxQ])
    subs.append([kAudioSubDeviceUIDKey: b.uid, kAudioSubDeviceDriftCompensationKey: 1,
                 kAudioSubDeviceDriftCompensationQualityKey: maxQ])
    let mainUID = clock?.uid ?? a.uid
    print("Clock: \(mainUID)")
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Domine Spike",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceIsPrivateKey: 0,
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceMainSubDeviceKey: mainUID,
        kAudioAggregateDeviceClockDeviceKey: mainUID,
        kAudioAggregateDeviceSubDeviceListKey: subs,
    ]
    var agg: AudioObjectID = 0
    try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice")
    print("Created aggregate id=\(agg) uid=\(aggUID)")

    let cleanup = {
        print("\nRestoring previous default output and destroying aggregate…")
        do { try setDefaultOutput(previous) } catch { print("restore failed: \(error)") }
        do { try check(AudioHardwareDestroyAggregateDevice(agg), "AudioHardwareDestroyAggregateDevice") } catch { print("\(error)") }
    }

    do {
        // Aggregate needs a moment to publish its streams.
        Thread.sleep(forTimeInterval: 0.5)
        let layout = try outputStreamLayout(agg)
        print("Aggregate output streams (channels per stream): \(layout)")
        let chA = a.outputChannels
        let base = UInt32(clock?.outputChannels ?? 0)
        let stereo: [UInt32] = [base + 1, base + UInt32(chA + 1)]
        if chA != 2 { print("note: Device A has \(chA) output channels, so right goes to channel \(chA + 1)") }
        try setValue(agg, address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput), (stereo[0], stereo[1]))
        let readBack = try getValue(agg, address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput), (UInt32(0), UInt32(0)))
        print("Preferred stereo channels: [\(readBack.0), \(readBack.1)]")
        try setDefaultOutput(agg)
        print("Default output is now the aggregate.")
        print("A: \(latencyReport(a.id))")
        print("B: \(latencyReport(b.id))")
    } catch {
        cleanup()
        throw error
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { cleanup(); exit(0) }
        s.resume()
        return s
    }
    _ = sources
    print("Playing. Press Ctrl-C to stop.")
    dispatchMain()
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "list": try list()
    case "run": try run(Array(args.dropFirst()))
    case "cleanup": try destroyStaleAggregates()
    default: print("usage: domine-spike list | run [uidA uidB] | cleanup")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
