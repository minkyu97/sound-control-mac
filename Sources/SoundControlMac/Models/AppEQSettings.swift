import Foundation

struct AppEQSettings: Codable, Hashable, Sendable {
    static let bandCount = 10
    static let centerFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels = ["32Hz", "64Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    static let minGainDB: Float = -12
    static let maxGainDB: Float = 12

    var gainsDB: [Float]

    init(gainsDB: [Float] = Array(repeating: 0, count: AppEQSettings.bandCount)) {
        self.gainsDB = Self.normalized(gainsDB)
    }

    static var flat: AppEQSettings {
        AppEQSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case gainsDB
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let rawGains = try container.decodeIfPresent([Float].self, forKey: .gainsDB) ?? []
            self.init(gainsDB: rawGains)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var rawGains: [Float] = []
            while !container.isAtEnd {
                if let floatValue = try? container.decode(Float.self) {
                    rawGains.append(floatValue)
                    continue
                }

                if let doubleValue = try? container.decode(Double.self) {
                    rawGains.append(Float(doubleValue))
                    continue
                }

                break
            }

            self.init(gainsDB: rawGains)
            return
        }

        self.init()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gainsDB, forKey: .gainsDB)
    }

    var isFlat: Bool {
        gainsDB.allSatisfy { abs($0) < 0.0001 }
    }

    func gain(at index: Int) -> Float {
        guard gainsDB.indices.contains(index) else {
            return 0
        }
        return gainsDB[index]
    }

    mutating func setGain(at index: Int, gainDB: Float) {
        guard gainsDB.indices.contains(index) else {
            return
        }

        gainsDB[index] = min(max(gainDB, AppEQSettings.minGainDB), AppEQSettings.maxGainDB)
    }

    private static func normalized(_ gains: [Float]) -> [Float] {
        var normalized = Array(gains.prefix(AppEQSettings.bandCount))
        if normalized.count < AppEQSettings.bandCount {
            normalized.append(contentsOf: repeatElement(0, count: AppEQSettings.bandCount - normalized.count))
        }

        return normalized.map {
            min(max($0, AppEQSettings.minGainDB), AppEQSettings.maxGainDB)
        }
    }
}
