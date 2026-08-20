import XCTest
import Foundation
@testable import ResumePlayer

final class ResumePlayerTests: XCTestCase {
    func testContentViewCanBeCreated() {
        XCTAssertNotNil(ContentView())
    }

    func testResumePositionPolicyRetainsOnlyPositionsAfterOpeningThresholdWithMoreThanTenSecondsRemaining() {
        let cases: [(position: TimeInterval, duration: TimeInterval, shouldSave: Bool)] = [
            (position: 0, duration: 60, shouldSave: false),
            (position: 5, duration: 60, shouldSave: false),
            (position: 5.1, duration: 20, shouldSave: true),
            (position: 10, duration: 20, shouldSave: false),
            (position: 10.1, duration: 20, shouldSave: false),
            (position: 6, duration: 12, shouldSave: false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                ResumePositionPolicy.shouldSave(position: testCase.position, duration: testCase.duration),
                testCase.shouldSave,
                "position \(testCase.position), duration \(testCase.duration)"
            )
        }
    }

    func testResumeStorePersistsBookmarkAcrossMoveAndClearsOpeningThresholdPosition() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let storageURL = temporaryDirectory.appendingPathComponent("resume-positions.json")
        let originalAudioURL = temporaryDirectory.appendingPathComponent("original.mp3")
        XCTAssertTrue(FileManager.default.createFile(atPath: originalAudioURL.path, contents: Data()))

        let position: TimeInterval = 20
        let store = ResumeStore(storageURL: storageURL)
        try await store.save(position: position, duration: 60, for: originalAudioURL)

        let reloadedStore = ResumeStore(storageURL: storageURL)
        let persistedPosition = try await reloadedStore.position(for: originalAudioURL)
        XCTAssertEqual(persistedPosition, position)

        let movedAudioURL = temporaryDirectory.appendingPathComponent("moved.mp3")
        try FileManager.default.moveItem(at: originalAudioURL, to: movedAudioURL)

        let movedStore = ResumeStore(storageURL: storageURL)
        let movedPosition = try await movedStore.position(for: movedAudioURL)
        XCTAssertEqual(movedPosition, position)

        try await movedStore.save(position: 5, duration: 60, for: movedAudioURL)

        let clearedStore = ResumeStore(storageURL: storageURL)
        let clearedPosition = try await clearedStore.position(for: movedAudioURL)
        XCTAssertNil(clearedPosition)
    }
}
