import Foundation

/// As fixtures do `/v1/tray` (#344) ficam em `tray/Tests/Fixtures/`, conferidas pelo `tests/agent-studio-tray.test.sh`.
enum Fixture {
    static func data(_ name: String, file: StaticString = #filePath) throws -> Data {
        let dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: dir.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }
}
