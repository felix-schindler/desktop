import XCTest

// MARK: - XCTest wrappers for the in-app harness suites
// The suites in `Tests/` predate the test target and expose `runAll()`
// (failure count) instead of `XCTestCase` methods. These thin wrappers make
// them runnable via `xcodebuild test` without changing the harness
// convention.
//
// Isolation notes: the app target compiles with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, but this target does not —
// `XCTestCase` inits are nonisolated and would conflict. Methods that call
// `@MainActor` suites are annotated individually instead. Sync methods stay
// sync on purpose: `Task15Tests.runAll()` pumps `RunLoop.main` internally
// and must not run inside an async `Task`.

@MainActor
final class HarnessSuiteTests: XCTestCase {
    // MARK: Sync suites

    @MainActor func testChangesLogic() {
        XCTAssertEqual(ChangesLogicTests.runAll(), 0)
    }

    @MainActor func testDiff() {
        XCTAssertEqual(DiffTests.runAll(), 0)
    }

    func testParser() {
        XCTAssertEqual(ParserTests.runAll(), 0)
    }

    @MainActor func testHistory() {
        XCTAssertEqual(HistoryTests.runAll(), 0)
    }

    @MainActor func testMultiCommit() async {
        let failures = await MultiCommitTests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testTask8() {
        XCTAssertEqual(Task8Tests.runAll(), 0)
    }

    func testTask9() {
        XCTAssertEqual(Task9Tests.runAll(), 0)
    }

    func testTask10() {
        XCTAssertEqual(Task10Tests.runAll(), 0)
    }

    func testShell() {
        XCTAssertEqual(ShellTests.runAll(), 0)
    }

    @MainActor func testTask15() {
        XCTAssertEqual(Task15Tests.runAll(), 0)
    }

    // MARK: Async (@MainActor) suites

    @MainActor func testGitStore() async {
        let failures = await GitStoreTests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testRepositoryDetail() async {
        let failures = await RepositoryDetailTests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testTask14() async {
        let failures = await Task14Tests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testTask16() async {
        let failures = await Task16Tests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testPartialStaging() async {
        let failures = await PartialStagingTests.runAll()
        XCTAssertEqual(failures, 0)
    }

    @MainActor func testUndo() async {
        let failures = await UndoTests.runAll()
        XCTAssertEqual(failures, 0)
    }
}
