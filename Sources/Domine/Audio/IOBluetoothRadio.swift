import Dispatch
import IOBluetooth

/// The real `BluetoothRadio`, backed by IOBluetooth. Only audio-class devices
/// are reported. Never opens anything for input; connecting is the same
/// `IOBluetoothConnector` path used to reconnect saved speakers.
@MainActor
final class IOBluetoothRadio: BluetoothRadio {
    private let connector = IOBluetoothConnector()
    private var search: SearchDelegate?
    private var pairing: PairDelegate?

    func pairedSpeakers() -> [BluetoothSpeaker] {
        let devices = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
        return devices.compactMap { device in
            guard Self.isAudio(device) else { return nil }
            return Self.speaker(device, isPaired: true)
        }
    }

    func startSearch(found: @escaping @MainActor (BluetoothSpeaker) -> Void,
                     finished: @escaping @MainActor () -> Void) {
        stopSearch()
        let delegate = SearchDelegate(found: found, finished: finished)
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: delegate) else {
            finished()
            return
        }
        inquiry.inquiryLength = 10
        inquiry.updateNewDeviceNames = true
        inquiry.setSearchCriteria(BluetoothServiceClassMajor(kBluetoothServiceClassMajorAny),
                                  majorDeviceClass: BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio),
                                  minorDeviceClass: BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAny))
        delegate.inquiry = inquiry
        search = delegate
        if inquiry.start() != kIOReturnSuccess {
            delegate.finish()
        }
    }

    func stopSearch() {
        guard let delegate = search else { return }
        search = nil
        delegate.inquiry?.stop()
        delegate.finish()
    }

    func connect(_ address: BluetoothAddress) async -> Bool {
        await connector.connect(address)
    }

    func disconnect(_ address: BluetoothAddress) async -> Bool {
        let text = address.string
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let status = IOBluetoothDevice(addressString: text)?.closeConnection()
                continuation.resume(returning: status == kIOReturnSuccess)
            }
        }
    }

    func pair(_ address: BluetoothAddress) async -> Bool {
        guard pairing == nil,
              let device = IOBluetoothDevice(addressString: address.string),
              let pair = IOBluetoothDevicePair(device: device) else { return false }
        stopSearch()
        let paired = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = PairDelegate(pair: pair, continuation: continuation)
            pairing = delegate
            pair.delegate = delegate
            if pair.start() != kIOReturnSuccess {
                delegate.finish(false)
                return
            }
            Task { @MainActor [weak delegate] in
                try? await Task.sleep(for: .seconds(30))
                delegate?.finish(false)
            }
        }
        pairing = nil
        return paired ? await connect(address) : false
    }

    fileprivate static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }

    fileprivate static func speaker(_ device: IOBluetoothDevice, isPaired: Bool) -> BluetoothSpeaker? {
        guard let text = device.addressString, let address = BluetoothAddress(deviceUID: text) else { return nil }
        let name = device.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.string
        return BluetoothSpeaker(address: address, name: name, isPaired: isPaired,
                                isConnected: device.isConnected())
    }
}

/// Receives inquiry callbacks (delivered on the main thread) and reports
/// each unpaired audio device once.
@MainActor
private final class SearchDelegate: NSObject {
    var inquiry: IOBluetoothDeviceInquiry?
    private var found: (@MainActor (BluetoothSpeaker) -> Void)?
    private var finished: (@MainActor () -> Void)?
    private var seen: Set<BluetoothAddress> = []

    init(found: @escaping @MainActor (BluetoothSpeaker) -> Void, finished: @escaping @MainActor () -> Void) {
        self.found = found
        self.finished = finished
    }

    func report(_ device: IOBluetoothDevice) {
        guard IOBluetoothRadio.isAudio(device), !device.isPaired(),
              let speaker = IOBluetoothRadio.speaker(device, isPaired: false),
              seen.insert(speaker.address).inserted else { return }
        found?(speaker)
    }

    func finish() {
        let done = finished
        found = nil
        finished = nil
        done?()
    }
}

extension SearchDelegate: @preconcurrency IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        if let device { report(device) }
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!,
                                        devicesRemaining: UInt32) {
        if let device { report(device) }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        finish()
    }
}

/// Holds the pairing object alive and resumes the waiting `pair` call once.
@MainActor
private final class PairDelegate: NSObject {
    private var pair: IOBluetoothDevicePair?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(pair: IOBluetoothDevicePair, continuation: CheckedContinuation<Bool, Never>) {
        self.pair = pair
        self.continuation = continuation
    }

    func finish(_ success: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if !success { pair?.stop() }
        pair?.delegate = nil
        pair = nil
        continuation.resume(returning: success)
    }
}

extension PairDelegate: @preconcurrency IOBluetoothDevicePairDelegate {
    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        finish(error == kIOReturnSuccess)
    }
}
