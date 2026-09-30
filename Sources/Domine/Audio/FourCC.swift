enum FourCC {
    /// `'who?'` for printable four-char codes, the decimal value otherwise.
    static func string(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (32..<127).contains($0) }) else {
            return String(Int32(bitPattern: value))
        }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}
