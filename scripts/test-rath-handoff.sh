#!/bin/zsh
# Exercise the actual handoff service and its fake-only tests when CLT lacks XCTest.
set -euo pipefail
ROOT_DIR="${0:A:h}/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profiles-handoff-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY'
from pathlib import Path
import re
import sys

root, target = map(Path, sys.argv[1:])
app = (root / 'Sources/CodexProfiles/CodexProfilesApp.swift').read_text()
models = app[app.index('struct Profile:'):app.index('struct ProfileRenameRequest:')]
# The production adapters cannot run in this harness: they intentionally trap.
stubs = '''
enum ProfileError: Error { case appServerError(String) }
final class ProfileStore {
    func loadProfiles() throws -> [Profile] { fatalError("Real store prohibited") }
    func readAuth(for profileID: UUID) throws -> Data { fatalError("Real store prohibited") }
    func saveAuth(_ data: Data, for profileID: UUID) throws { fatalError("Real store prohibited") }
}
final class KeychainStore {
    func readHandoffPolicy() throws -> Data? { nil }
    func saveHandoffPolicy(_ data: Data) throws {}
}
final class AppServerClient {
    func readAccountAndUsage(auth: Data, refreshToken: Bool) async throws -> (UsageSnapshot, Data?) {
        fatalError("Real app-server prohibited")
    }
}
'''
(target / 'Models.swift').write_text('import Foundation\n' + models + stubs)
tests = (root / 'Tests/CodexProfilesTests/RathHandoffTests.swift').read_text()
tests = tests.replace('import XCTest', 'import Foundation').replace('@testable import CodexProfiles', '')
(target / 'Tests.swift').write_text(tests)
shim = '''
import Foundation
import Darwin
class XCTestCase {}
var failures = 0
func XCTFail(_ message: String = "") { failures += 1 }
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { if !value() { failures += 1 } }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { if value() { failures += 1 } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T) {
    if a() != b() { failures += 1 }
}
enum HarnessError: Error { case missingValue }
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { failures += 1; throw HarnessError.missingValue }; return value
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); failures += 1 } catch {}
}
@main enum Runner {
    static func main() async {
        let tests = RathHandoffTests()
'''
methods = re.findall(r'    func (test\w+)\(\)([^\{]*)\{', tests)
assert methods, 'No handoff tests found'
for name, signature in methods:
    call = ('try ' if 'throws' in signature else '') + ('await ' if 'async' in signature else '') + f'tests.{name}()'
    shim += (f'        do {{ {call} }} catch {{ failures += 1 }}\n' if 'throws' in signature
             else f'        {call}\n')
shim += f'''        print("Handoff fake-only tests: {len(methods)} cases, \\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }}
}}
'''
(target / 'Runner.swift').write_text(shim)
PY
swiftc -swift-version 5 -o "$TEST_DIR/run-tests" \
  "$TEST_DIR/Models.swift" "$ROOT_DIR/Sources/CodexProfiles/RathHandoff.swift" \
  "$TEST_DIR/Tests.swift" "$TEST_DIR/Runner.swift"
"$TEST_DIR/run-tests"
