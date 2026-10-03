import Foundation

/// Compatibility surface for settings and tests written before Quad was
/// renamed to Surround. The UI and persisted routing mode remain Surround.
extension RoutingMode {
    static var quad: Self { .surround }
}

@MainActor
extension AppModel {
    var isQuadAvailable: Bool {
        let assigned = [leftUID, rightUID, rearLeftUID, rearRightUID].compactMap { $0 }
        return assigned.count == 4 && Set(assigned).count == 4
    }

    var quadSettings: QuadSettings {
        guard let leftUID, let rightUID, let rearLeftUID, let rearRightUID else {
            return QuadSettings()
        }
        return store.quadSettings(uids: [leftUID, rightUID, rearLeftUID, rearRightUID])
    }

    func setRearTrim(_ value: Float) {
        guard let leftUID, let rightUID, let rearLeftUID, let rearRightUID else { return }
        var settings = quadSettings
        settings.rearTrim = value
        store.setQuadSettings(settings, uids: [leftUID, rightUID, rearLeftUID, rearRightUID])
        updateSurroundSettings { $0.surroundLevel = value }
    }

    func setRearMode(_ value: Int) {
        guard let leftUID, let rightUID, let rearLeftUID, let rearRightUID else { return }
        var settings = quadSettings
        settings.rearMode = value
        store.setQuadSettings(settings, uids: [leftUID, rightUID, rearLeftUID, rearRightUID])
        updateSurroundSettings { $0.spatialAmount = value == 0 ? 0 : 0.6 }
    }
}

extension MainWindowState {
    var isQuadAvailable: Bool { isSurroundAvailable }
    var rearMode: QuadRearMode {
        surround.level == 0 ? .mirror : .matrix
    }
    var spatialAmount: Double { surround.level }
}

enum QuadRearMode: Equatable, Sendable {
    case mirror
    case matrix
    case spatial
}

@MainActor
extension Engine {
    var rearTrim: Float {
        get { surroundLevel }
        set { surroundLevel = newValue }
    }

    var rearMode: Int {
        get { spatialAmount == 0 ? 0 : 1 }
        set { spatialAmount = newValue == 0 ? 0 : 0.6 }
    }

    var quadUIDs: [String]? { surroundRoute }

    func start(quad uids: [String]) async {
        let azimuths: [Float] = [-30, 30, -110, 110]
        await start(surround: zip(uids, azimuths).map {
            SurroundSpeaker(uid: $0.0, azimuth: $0.1)
        })
    }

    func start(quad uids: [String?]) async {
        guard uids.allSatisfy({ $0 != nil }) else {
            await start(surround: [])
            return
        }
        await start(quad: uids.compactMap { $0 })
    }
}
