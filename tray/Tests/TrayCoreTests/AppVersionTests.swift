import XCTest
import TrayCore

final class AppVersionTests: XCTestCase {
    func testVersaoECommit() {
        XCTAssertEqual(AppVersion.line(version: "0.7.42", commit: "54e0c51"), "OuteTray 0.7.42 (54e0c51)")
    }

    func testSemCommitSoAVersao() {
        XCTAssertEqual(AppVersion.line(version: "0.7.42", commit: nil), "OuteTray 0.7.42")
        XCTAssertEqual(AppVersion.line(version: "0.7.42", commit: ""), "OuteTray 0.7.42")
    }

    func testForaDoAppNaoHaVersao() {
        XCTAssertEqual(AppVersion.line(version: nil, commit: nil), "OuteTray (fora do .app: sem versão)")
        XCTAssertEqual(AppVersion.line(version: "", commit: "54e0c51"), "OuteTray (fora do .app: sem versão)")
    }

    func testEspacosEmVoltaSaem() {
        XCTAssertEqual(AppVersion.line(version: " 0.7.42\n", commit: " 54e0c51 "), "OuteTray 0.7.42 (54e0c51)")
    }
}
