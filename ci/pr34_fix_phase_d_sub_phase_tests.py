from pathlib import Path

path = Path("NotchSixtyTests/NotchSixtyTests.swift")
text = path.read_text()

start = text.find("    func testSubBassPhaseAlignmentPublishesAuditedDefaults() throws {")
end = text.find("    func testCrosstalkCancellationGraphPublishesAuditedDefaults() throws {", start)
if start < 0 or end < 0:
    raise SystemExit("Expected sub-bass phase alignment test block was not found")

block = text[start:end]
needle = "            bassManagementConfiguration: bass\n"
replacement = "            bassManagementConfiguration: bass,\n            playbackConfiguration: PlaybackControlConfiguration()\n"
count = block.count(needle)
if count == 0 and block.count("playbackConfiguration: PlaybackControlConfiguration()") == 4:
    print("PR34 sub-phase generated graph tests are already current.")
    raise SystemExit(0)
if count != 4:
    raise SystemExit(f"Expected 4 sub-phase graph calls to patch, found {count}")

block = block.replace(needle, replacement)
text = text[:start] + block + text[end:]
path.write_text(text)
print("Patched 4 PR34 sub-phase graph tests for the current graph API.")
