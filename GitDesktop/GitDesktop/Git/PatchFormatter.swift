import Foundation

// MARK: - PatchFormatter
// Pure port of `electron/app/src/lib/patch-formatter.ts` (`formatPatch` +
// header helpers). Foundation-only so it stays harness-testable without git
// or AppKit: `formatPatch` turns a working-directory `Diff` plus the file's
// `DiffSelection` into a GNU unified diff suitable for
// `git apply --cached` (see `StageLiveOperations`).

public enum PatchFormatterError: Error, Sendable, Equatable {
    case emptyPatch(path: String)
    case unsupportedDiff(path: String)
}

/// `--- <from>` / `+++ <to>` header (no timestamps, matching git).
/// Port of `formatPatchHeader`.
nonisolated public func formatPatchHeader(from: String?, to: String?) -> String {
    let fromPath = from.map { "a/\($0)" } ?? "/dev/null"
    let toPath = to.map { "b/\($0)" } ?? "/dev/null"
    return "--- \(fromPath)\n+++ \(toPath)\n"
}

/// Header paths for a file. New/untracked files diff against `/dev/null`;
/// renames target the new path (the patch applies on top of the recreated
/// rename in the index — see `applyPatchToIndex`). Port of
/// `formatPatchHeaderForFile`.
nonisolated public func formatPatchHeaderForFile(_ file: WorkingDirectoryFileChange) -> String {
    switch file.status.kind {
    case .new, .untracked:
        return formatPatchHeader(from: nil, to: file.path)
    case .renamed, .deleted, .modified, .copied, .conflicted:
        return formatPatchHeader(from: file.path, to: file.path)
    }
}

/// `@@ -l,s +l,s @@` header (single-line counts omit `,1`, matching git).
/// Port of `formatHunkHeader`.
nonisolated public func formatHunkHeader(
    oldStartLine: Int, oldLineCount: Int,
    newStartLine: Int, newLineCount: Int
) -> String {
    let before = oldLineCount == 1 ? "\(oldStartLine)" : "\(oldStartLine),\(oldLineCount)"
    let after = newLineCount == 1 ? "\(newStartLine)" : "\(newStartLine),\(newLineCount)"
    return "@@ -\(before) +\(after) @@\n"
}

/// Text hunks for patch formatting. Binary/submodule/image/unrenderable
/// diffs cannot be partially staged (mirrors the `applyPatchToIndex` guard).
nonisolated public func patchTextDiffData(from diff: Diff) -> TextDiffData? {
    switch diff {
    case .text(let data): return data
    case .largeText(let data): return data
    case .image, .binary, .submodule, .unrenderable: return nil
    }
}

/// Build a `git apply --cached` patch containing only the selected lines.
/// Port of `formatPatch`: context flows through, selected adds/deletes flow
/// through, unselected adds are dropped (new/untracked lines vanish as if
/// never added), unselected deletes become context. Hunk headers are
/// recomputed for the surviving lines; hunks with no surviving
/// addition/deletion are skipped. Throws `.emptyPatch` when nothing
/// survives and `.unsupportedDiff` for non-text diffs.
nonisolated public func formatPatch(file: WorkingDirectoryFileChange, diff: Diff) throws -> String {
    guard let textDiff = patchTextDiffData(from: diff) else {
        throw PatchFormatterError.unsupportedDiff(path: file.path)
    }
    var patch = ""
    for hunk in textDiff.hunks {
        var hunkBuf = ""
        var oldCount = 0
        var newCount = 0
        var anyAdditionsOrDeletions = false
        for (lineIndex, line) in hunk.lines.enumerated() {
            let absoluteIndex = hunk.unifiedDiffStart + lineIndex
            // We write our own hunk headers.
            if line.type == .hunk { continue }
            if line.type == .context {
                hunkBuf += "\(line.text)\n"
                oldCount += 1
                newCount += 1
            } else if file.selection.isSelected(lineIndex: absoluteIndex) {
                hunkBuf += "\(line.text)\n"
                if line.type == .add { newCount += 1 }
                if line.type == .delete { oldCount += 1 }
                anyAdditionsOrDeletions = true
            } else {
                // Unselected lines in new files are dropped: the partial
                // patch pretends the line never existed.
                switch file.status.kind {
                case .new, .untracked:
                    continue
                default:
                    break
                }
                // An unselected add never happened as far as this patch is
                // concerned.
                if line.type == .add { continue }
                // An unselected delete is still in the old file: keep it as
                // context.
                if line.type == .delete {
                    hunkBuf += " \(line.content)\n"
                    oldCount += 1
                    newCount += 1
                }
            }
            if line.noTrailingNewLine {
                hunkBuf += "\\ No newline at end of file\n"
            }
        }
        // Skip hunks that are context-only after filtering.
        if !anyAdditionsOrDeletions { continue }
        patch += formatHunkHeader(
            oldStartLine: hunk.header.oldStartLine, oldLineCount: oldCount,
            newStartLine: hunk.header.newStartLine, newLineCount: newCount)
        patch += hunkBuf
    }
    if patch.isEmpty {
        throw PatchFormatterError.emptyPatch(path: file.path)
    }
    return formatPatchHeaderForFile(file) + patch
}
