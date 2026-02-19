import Foundation

struct AppEQSettings: Codable, Hashable, Sendable {
    static let bandCount = 5
    static let centerFrequencies: [Float] = [80, 250, 1000, 4000, 12000]
    static let bandLabels = ["80Hz", "250Hz", "1k", "4k", "12k"]
    static let minGainDB: Float = -12
    static let maxGainDB: Float = 12

    var gainsDB: [Float]

    init(gainsDB: [Float] = Array(repeating: 0, count: AppEQSettings.bandCount)) {
        var normalized = Array(gainsDB.prefix(AppEQSettings.bandCount))
        if normalized.count < AppEQSettings.bandCount {
            normalized.append(contentsOf: repeatElement(0, count: AppEQSettings.bandCount - normalized.count))
        }

        self.gainsDB = normalized.map {
            min(max($0, AppEQSettings.minGainDB), AppEQSettings.maxGainDB)
        }
    }

    static var flat: AppEQSettings {
        AppEQSettings()
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
}
