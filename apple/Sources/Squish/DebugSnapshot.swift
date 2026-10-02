#if DEBUG
import AppKit

/// Debug-only: drives the UI through its states and saves window snapshots.
///   SQUISH_SNAPSHOT=<dir> SQUISH_FILES=<a:b:c> .build/debug/Squish
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SQUISH_SNAPSHOT"] else { return }
        let files = (env["SQUISH_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        Task { await run(dir: URL(fileURLWithPath: dir), files: files) }
    }

    private static func run(dir: URL, files: [URL]) async {
        let model = AppModel.shared
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "fineTune")
        defaults.set(1, forKey: "appearance")
        let env = ProcessInfo.processInfo.environment
        model.settings = env["SQUISH_SETTINGS"].flatMap { try? JSONDecoder().decode(Settings.self, from: Data($0.utf8)) } ?? Settings()
        if let preset = env["SQUISH_PRESET"].flatMap(Preset.init) { model.settings.apply(preset) }
        model.settings.destination = env["SQUISH_OUT"].map { URL(fileURLWithPath: $0) }

        await pause(1.5); capture("1-empty", in: dir)
        model.add(files)
        let start = Date()
        while Date().timeIntervalSince(start) < 120,
              model.settings.mode == .compress
                ? !Preset.allCases.allSatisfy({ model.prediction(for: $0)?.complete == true })
                : model.prediction(for: nil)?.complete != true {
            await pause(0.1)
        }
        print(String(format: "estimates ready in %.1fs", Date().timeIntervalSince(start)))
        await pause(0.8); capture("2-queued", in: dir)
        model.compress()
        await pause(0.4); capture("3-working", in: dir)
        while model.isRunning { await pause(0.2) }
        await pause(0.8); capture("4-done", in: dir)
        defaults.set(true, forKey: "fineTune")
        await pause(0.8); capture("5-finetune", in: dir)
        defaults.set(2, forKey: "appearance")
        await pause(0.8); capture("6-dark", in: dir)

        for preset in Preset.allCases {
            if let p = model.prediction(for: preset) {
                print("predicted \(preset.title): \(Format.size(p.after))\(p.complete ? "" : " (partial)")")
            }
        }
        var outputs = Set<URL>()
        let actual = model.items.reduce(Int64(0)) { total, item in
            guard item.status == .done, let output = item.output else { return total + item.size }
            return outputs.insert(output).inserted ? total + (item.outputSize ?? 0) : total
        }
        if model.settings.mode == .convert, let p = model.prediction(for: nil) {
            print("predicted Convert: \(Format.size(p.after))\(p.complete ? "" : " (partial)")")
        }
        print("actual (\(model.settings.mode == .convert ? "convert" : model.settings.preset?.title ?? "custom")): \(Format.size(actual))")
        for item in model.items {
            let out = item.outputSize.map(Format.size) ?? "-"
            print("\(item.name)\t\(item.status)\t\(Format.size(item.size)) → \(out)\t\(item.output?.lastPathComponent ?? "")\t\(item.outputFormat) \(item.outputInfo)")
        }
        model.settings = Settings()
        defaults.set(0, forKey: "appearance")
        defaults.set(false, forKey: "fineTune")
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func capture(_ name: String, in dir: URL) {
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return print("snapshot failed: \(name)") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
#endif
