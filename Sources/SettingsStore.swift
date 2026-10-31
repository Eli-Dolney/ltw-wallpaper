import Foundation

/// Per-scene overrides, stored as flat JSON objects (dotted keys allowed) in settings/<scene>.json.
/// Defaults never live here; each scene's CONFIG is the default.
final class SettingsStore {
    let dir: URL
    private var cache: [String: [String: Any]] = [:]
    private var writeWork: [String: DispatchWorkItem] = [:]

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func url(for scene: String) -> URL {
        dir.appendingPathComponent(scene.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    func load(_ scene: String) -> [String: Any] {
        if let c = cache[scene] { return c }
        let d = (try? Data(contentsOf: url(for: scene)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cache[scene] = d
        return d
    }

    func set(_ scene: String, key: String, value: Any) {
        var d = load(scene)
        d[key] = value
        cache[scene] = d
        scheduleWrite(scene)
    }

    func reset(_ scene: String) {
        cache[scene] = [:]
        writeWork[scene]?.cancel()
        try? FileManager.default.removeItem(at: url(for: scene))
    }

    private func scheduleWrite(_ scene: String) {
        writeWork[scene]?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, let d = self.cache[scene] else { return }
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.url(for: scene))
            }
        }
        writeWork[scene] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
