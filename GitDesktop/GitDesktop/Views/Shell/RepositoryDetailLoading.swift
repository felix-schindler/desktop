import Foundation

// MARK: - RepositoryDetailLoading (Task 12)
// Thin data adapters for `Views/Shell/RepositoryView.swift`.
// Pure helpers are unit-testable without git; async loaders use `GitProcess`
// with the same args/env as the reference (`electron/app/src/lib/git/diff.ts`
// + `log.ts`). Tasks 12–14 code against the Task-11 `GitStore` seam and never
// call these directly from feature views — only the shell adapters do.

public let repositoryNullTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

// MARK: - Pure helpers

/// Branch name for the Changes commit box. Mirrors `repository.tsx`
/// `renderChangesSidebar`: valid → branch name, unborn → ref short name.
public func repositoryBranchName(tip: Tip) -> String? {
    switch tip {
    case .valid(let branch):
        return branch.name
    case .unborn(let ref):
        let prefix = "refs/heads/"
        if ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    case .detached, .unknown:
        return nil
    }
}

/// Commit author for the commit box: explicit global git identity when set,
/// else the most recent commit's author (avatar still renders).
public func repositoryCommitAuthor(
    state: RepositoryState,
    globalName: String? = UserDefaults.standard.string(forKey: Defaults.globalGitAuthorName),
    globalEmail: String? = UserDefaults.standard.string(forKey: Defaults.globalGitAuthorEmail)
) -> CommitIdentity? {
    let name = (globalName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let email = (globalEmail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty && !email.isEmpty {
        return CommitIdentity(name: name, email: email, date: Date(), tzOffset: 0)
    }
    return state.recentCommits.first?.author
}

/// Local author suggestions from history (deduped by email, capped).
public func repositoryLocalAuthors(commits: [Commit], limit: Int = 20) -> [Author] {
    var seen = Set<String>()
    var out: [Author] = []
    for commit in commits {
        let email = commit.author.email.lowercased()
        if email.isEmpty || seen.contains(email) { continue }
        seen.insert(email)
        out.append(.known(name: commit.author.name, email: commit.author.email, username: nil))
        if out.count >= limit { break }
    }
    return out
}

/// Most recent commit for the Undo slide. Task 11 has no unpushed tracking,
/// so the tip commit is the best signal (matches `mostRecentLocalCommit` use).
public func repositoryMostRecentCommit(state: RepositoryState) -> Commit? {
    state.recentCommits.first
}

/// Case-insensitive history filter (summary + sha + author), port of the
/// `compare.tsx` filter box.
public func filterHistoryCommits(_ commits: [Commit], filterText: String) -> [Commit] {
    let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return commits }
    return commits.filter { commit in
        commit.summary.lowercased().contains(query)
            || commit.sha.lowercased().contains(query)
            || commit.shortSha.lowercased().contains(query)
            || commit.author.name.lowercased().contains(query)
            || commit.author.email.lowercased().contains(query)
    }
}

/// Unpushed marker: the first `ahead` commits are local-only. Mirrors the
/// `↑` badge in `commit-list.tsx` without extra git calls.
public func localCommitSHAs(commits: [Commit], ahead: Int?) -> Set<String> {
    guard let ahead, ahead > 0 else { return [] }
    return Set(commits.prefix(ahead).map(\.sha))
}

/// Preserve display order (newest-first) for the detail pane.
public func orderedSelectedCommits(commits: [Commit], selectedSHAs: Set<String>) -> [Commit] {
    commits.filter { selectedSHAs.contains($0.sha) }
}

private let imageExtensions: Set<String> = [
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".bmp", ".avif",
]

public func isImagePath(_ path: String) -> Bool {
    let lower = (path as NSString).pathExtension.lowercased()
    return !lower.isEmpty && imageExtensions.contains(".\(lower)")
}

func submoduleStatus(of status: AppFileStatus) -> SubmoduleStatus? {
    switch status {
    case .new(let s): return s
    case .modified(let s): return s
    case .deleted(let s): return s
    case .copied(_, _, let s): return s
    case .renamed(_, _, let s): return s
    case .conflictedWithMarkers(_, _, _, _, let s): return s
    case .manualConflict(_, _, _, let s): return s
    case .untracked(let s): return s
    }
}

func oldPath(of status: AppFileStatus) -> String? {
    DiffSupport.oldPath(for: status)
}

// MARK: - Async loaders (shell adapters only)

public enum RepositoryDetailLoading {
    // MARK: Working directory

    public struct WorkingDirectoryDiff: Sendable {
        public var diff: Diff
        public var contents: DiffFileContents?
    }

    /// `getWorkingDirectoryDiff` equivalent: `git diff` vs HEAD (or
    /// `--no-index /dev/null` for new/untracked), classified to `Diff`.
    public static func workingDirectoryDiff(
        repositoryPath: String,
        file: WorkingDirectoryFileChange,
        hideWhitespace: Bool
    ) async throws -> WorkingDirectoryDiff {
        if submoduleStatus(of: file.status) != nil {
            let url = try? await configValue(repositoryPath: repositoryPath, name: "submodule.\(file.path).url")
            return WorkingDirectoryDiff(
                diff: .submodule(SubmoduleDiffData(
                    fullPath: (repositoryPath as NSString).appendingPathComponent(file.path),
                    path: file.path,
                    url: url,
                    status: submoduleStatus(of: file.status)!,
                    oldSHA: nil,
                    newSHA: nil)),
                contents: nil)
        }
        var args = [
            "diff",
            hideWhitespace ? "-w" : nil,
            "--no-ext-diff",
            "--patch-with-raw",
            "-z",
            "--no-color",
        ].compactMap { $0 }
        let successCodes: Set<Int32> = [0, 1]
        switch file.status.kind {
        case .new, .untracked:
            args += ["--no-index", "--", "/dev/null", file.path]
        case .renamed:
            args += ["--", file.path]
        default:
            args += ["HEAD", "--", file.path]
            if let old = oldPath(of: file.status) {
                // Renames already covered; copies include both paths.
                _ = old
            }
        }
        let result = try await GitProcess.run(args, workingDirectory: repositoryPath)
        // `--no-index` exits 1 when differences exist; anything else throws.
        if !successCodes.contains(result.exitCode) {
            if let error = classifyGitResult(result, args: args, successExitCodes: [0, 1]) {
                throw error
            }
            throw GitError(kind: nil, args: args, stdout: result.stdoutString, stderr: result.stderrString, exitCode: result.exitCode)
        }
        let lineEndings = DiffParser.parseLineEndingsChange(result.stderrString)
        let diff = await classifyDiffBuffer(
            result.stdout,
            repositoryPath: repositoryPath,
            path: file.path,
            status: file.status,
            newestCommitish: "HEAD",
            oldestCommitish: "HEAD",
            lineEndingsChange: lineEndings)
        let contents = await workingDirectoryContents(repositoryPath: repositoryPath, file: file)
        return WorkingDirectoryDiff(diff: diff, contents: contents)
    }

    public static func workingDirectoryContents(
        repositoryPath: String,
        file: WorkingDirectoryFileChange
    ) async -> DiffFileContents? {
        // Deleted files have no new content; new/untracked have no old content.
        let oldLines: [String]
        let newLines: [String]
        switch file.status.kind {
        case .new, .untracked:
            oldLines = []
            newLines = readWorkdirLines(repositoryPath: repositoryPath, path: file.path) ?? []
        case .deleted:
            oldLines = await showLines(repositoryPath: repositoryPath, commitish: "HEAD", path: oldPath(of: file.status) ?? file.path) ?? []
            newLines = []
        default:
            let oldPathValue = oldPath(of: file.status) ?? file.path
            oldLines = await showLines(repositoryPath: repositoryPath, commitish: "HEAD", path: oldPathValue) ?? []
            newLines = readWorkdirLines(repositoryPath: repositoryPath, path: file.path) ?? []
        }
        // Binary/submodule files have no expandable text contents.
        if submoduleStatus(of: file.status) != nil { return nil }
        if oldLines.isEmpty && newLines.isEmpty { return nil }
        return DiffFileContents(oldLines: oldLines, newLines: newLines, canBeExpanded: true)
    }

    // MARK: History

    public struct CommitChangeset: Sendable {
        public var files: [CommittedFileChange]
        public var linesAdded: Int
        public var linesDeleted: Int
    }

    /// `getChangedFiles` (single) / `getCommitRangeChangedFiles` (multi).
    /// `selected` must be in display order (newest-first).
    public static func commitChangedFiles(
        repositoryPath: String,
        selected: [Commit]
    ) async throws -> CommitChangeset {
        guard !selected.isEmpty else {
            return CommitChangeset(files: [], linesAdded: 0, linesDeleted: 0)
        }
        let latest = selected.first!
        let oldest = selected.last!
        let oldestParent = oldest.parentSHAs.first ?? repositoryNullTreeSHA
        let stdout: String
        if selected.count == 1 {
            let sha = latest.sha
            let parent = latest.parentSHAs.first
            if parent == nil {
                // Root commit: diff against the null tree (matches the
                // BadRevision → NullTreeSHA retry in `diff.ts`).
                let args = ["diff", repositoryNullTreeSHA, sha, "-C", "-M", "-z", "--raw", "--numstat", "--"]
                let result = try await GitProcess.run(args, workingDirectory: repositoryPath)
                if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
                stdout = result.stdoutString
            } else {
                let args = ["log", sha, "-C", "-M", "-m", "-1", "--no-show-signature",
                            "--first-parent", "--raw", "--format=format:", "--numstat", "-z", "--"]
                let result = try await GitProcess.run(args, workingDirectory: repositoryPath)
                if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
                stdout = result.stdoutString
            }
            let files = LogParser.parseChangedFiles(stdout, commitish: sha, parentCommitish: parent ?? repositoryNullTreeSHA)
            let (added, deleted) = numstatTotals(stdout)
            return CommitChangeset(files: files, linesAdded: added, linesDeleted: deleted)
        } else {
            let oldestRef = "\(oldest.sha)^"
            // Probe for a root oldest (BadRevision → retry with null tree).
            let probe = try await GitProcess.run(
                ["rev-parse", "--verify", oldestRef], workingDirectory: repositoryPath)
            let useNullTree = probe.exitCode != 0
            let baseRef = useNullTree ? repositoryNullTreeSHA : oldestRef
            let args = ["diff", baseRef, latest.sha, "-C", "-M", "-z", "--raw", "--numstat", "--"]
            let result = try await GitProcess.run(args, workingDirectory: repositoryPath)
            if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
            stdout = result.stdoutString
            let files = LogParser.parseChangedFiles(stdout, commitish: latest.sha, parentCommitish: useNullTree ? repositoryNullTreeSHA : oldestRef)
            let (added, deleted) = numstatTotals(stdout)
            _ = oldestParent
            return CommitChangeset(files: files, linesAdded: added, linesDeleted: deleted)
        }
    }

    public struct CommitDiffResult: Sendable {
        public var diff: Diff
        public var contents: DiffFileContents?
    }

    /// `getCommitDiff` (single) / `getCommitRangeDiff` (multi) for one file.
    public static func commitDiff(
        repositoryPath: String,
        file: CommittedFileChange,
        selected: [Commit],
        hideWhitespace: Bool
    ) async throws -> CommitDiffResult {
        guard !selected.isEmpty else {
            return CommitDiffResult(diff: .unrenderable, contents: nil)
        }
        if submoduleStatus(of: file.status) != nil {
            let url = try? await configValue(repositoryPath: repositoryPath, name: "submodule.\(file.path).url")
            let shas = await parseSubmoduleSHAs(repositoryPath: repositoryPath, file: file, selected: selected)
            return CommitDiffResult(
                diff: .submodule(SubmoduleDiffData(
                    fullPath: (repositoryPath as NSString).appendingPathComponent(file.path),
                    path: file.path,
                    url: url,
                    status: submoduleStatus(of: file.status)!,
                    oldSHA: shas.old,
                    newSHA: shas.new)),
                contents: nil)
        }
        let latest = selected.first!
        let oldest = selected.last!
        let result: GitResult
        let newestCommitish = latest.sha
        let oldestCommitish = oldest.sha
        if selected.count == 1 {
            var args = ["log", latest.sha]
            if hideWhitespace { args.append("-w") }
            args += ["-m", "-1", "--first-parent", "--patch-with-raw", "--format=", "-z", "--no-color", "--", file.path]
            if let old = oldPath(of: file.status) { args.append(old) }
            result = try await GitProcess.run(args, workingDirectory: repositoryPath)
            if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
        } else {
            let probe = try await GitProcess.run(
                ["rev-parse", "--verify", "\(oldest.sha)^"], workingDirectory: repositoryPath)
            let useNullTree = probe.exitCode != 0
            let oldestRef = useNullTree ? repositoryNullTreeSHA : "\(oldest.sha)^"
            var args = ["diff", oldestRef, latest.sha]
            if hideWhitespace { args.append("-w") }
            args += ["--patch-with-raw", "--format=", "-z", "--no-color", "--", file.path]
            if let old = oldPath(of: file.status) { args.append(old) }
            result = try await GitProcess.run(args, workingDirectory: repositoryPath)
            if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
        }
        let diff = await classifyDiffBuffer(
            result.stdout,
            repositoryPath: repositoryPath,
            path: file.path,
            status: file.status,
            newestCommitish: newestCommitish,
            oldestCommitish: oldestCommitish,
            lineEndingsChange: nil)
        let contents = await commitContents(
            repositoryPath: repositoryPath, file: file, selected: selected)
        return CommitDiffResult(diff: diff, contents: contents)
    }

    public static func commitContents(
        repositoryPath: String,
        file: CommittedFileChange,
        selected: [Commit]
    ) async -> DiffFileContents? {
        guard let latest = selected.first, let oldest = selected.last else { return nil }
        let newRef = latest.sha
        let oldRef: String = oldest.parentSHAs.first ?? repositoryNullTreeSHA
        // Deleted → no new content; added → no old content.
        switch file.status.kind {
        case .new, .untracked:
            let newLines = await showLines(repositoryPath: repositoryPath, commitish: newRef, path: file.path) ?? []
            guard !newLines.isEmpty else { return nil }
            return DiffFileContents(oldLines: [], newLines: newLines, canBeExpanded: true)
        case .deleted:
            let oldPathValue = oldPath(of: file.status) ?? file.path
            let oldLines = await showLines(repositoryPath: repositoryPath, commitish: oldRef, path: oldPathValue) ?? []
            guard !oldLines.isEmpty else { return nil }
            return DiffFileContents(oldLines: oldLines, newLines: [], canBeExpanded: true)
        default:
            let oldPathValue = oldPath(of: file.status) ?? file.path
            let oldLines = await showLines(repositoryPath: repositoryPath, commitish: oldRef, path: oldPathValue) ?? []
            let newLines = await showLines(repositoryPath: repositoryPath, commitish: newRef, path: file.path) ?? []
            if oldLines.isEmpty && newLines.isEmpty { return nil }
            return DiffFileContents(oldLines: oldLines, newLines: newLines, canBeExpanded: true)
        }
    }

    // MARK: - Internals

    static func classifyDiffBuffer(
        _ buffer: Data,
        repositoryPath: String,
        path: String,
        status: AppFileStatus,
        newestCommitish: String,
        oldestCommitish: String,
        lineEndingsChange: LineEndingsChange?
    ) async -> Diff {
        if buffer.count > maxDiffBufferSize { return .unrenderable }
        let text = String(data: buffer, encoding: .utf8) ?? ""
        // `--patch-with-raw -z` separates the raw header from the patch with
        // NUL; the patch is the last piece (mirrors `diffFromRawDiffOutput`).
        let pieces = text.components(separatedBy: "\0")
        let patch = pieces.last ?? ""
        let parsed: RawDiff
        do {
            parsed = try DiffParser.parse(patch)
        } catch {
            return .unrenderable
        }
        if parsed.isBinary {
            if isImagePath(path) {
                if let image = await imageDiff(
                    repositoryPath: repositoryPath, path: path,
                    status: status, newestCommitish: newestCommitish,
                    oldestCommitish: oldestCommitish) {
                    return image
                }
            }
            // Image loads can fail (e.g. file deleted); fall back to binary.
            // Non-image binaries never attempt pixel loads (no DDS per scope).
            return .binary
        }
        if parsed.hunks.isEmpty {
            // Empty patch (e.g. mode-only change) renders the empty state in
            // `SeamlessDiffSwitcher`; keep it as text so the header shows.
            return .text(TextDiffData(
                text: parsed.contents, hunks: [],
                lineEndingsChange: lineEndingsChange,
                maxLineNumber: parsed.maxLineNumber,
                hasHiddenBidiChars: parsed.hasHiddenBidiChars))
        }
        if buffer.count >= maxReasonableDiffSize || isDiffTooLarge(parsed) {
            return .largeText(TextDiffData(
                text: parsed.contents, hunks: parsed.hunks,
                lineEndingsChange: lineEndingsChange,
                maxLineNumber: parsed.maxLineNumber,
                hasHiddenBidiChars: parsed.hasHiddenBidiChars))
        }
        // Image check for text-classified diffs with image extensions:
        // `git diff` emits a text patch for SVGs; keep text (matches ref).
        return .text(TextDiffData(
            text: parsed.contents, hunks: parsed.hunks,
            lineEndingsChange: lineEndingsChange,
            maxLineNumber: parsed.maxLineNumber,
            hasHiddenBidiChars: parsed.hasHiddenBidiChars))
    }

    static func isDiffTooLarge(_ diff: RawDiff) -> Bool {
        for hunk in diff.hunks {
            for line in hunk.lines {
                if line.text.count > maxCharactersPerLine { return true }
            }
        }
        return false
    }

    static func imageDiff(
        repositoryPath: String,
        path: String,
        status: AppFileStatus,
        newestCommitish: String,
        oldestCommitish: String
    ) async -> Diff? {
        // Working-directory images are handled by the caller passing
        // HEAD/workdir refs; history passes commit/parent refs. Distinguish
        // by whether newest == "HEAD" (workdir) or a SHA (history).
        let isWorkdir = newestCommitish == "HEAD" && oldestCommitish == "HEAD"
        if isWorkdir {
            var current: DiffImage?
            var previous: DiffImage?
            if status.kind != .deleted {
                current = readWorkdirImage(repositoryPath: repositoryPath, path: path)
            }
            if status.kind != .new && status.kind != .untracked {
                previous = await blobImage(
                    repositoryPath: repositoryPath,
                    commitish: "HEAD",
                    path: oldPath(of: status) ?? path)
            }
            guard current != nil || previous != nil else { return nil }
            return .image(previous: previous, current: current)
        } else {
            var current: DiffImage?
            var previous: DiffImage?
            if status.kind != .deleted {
                current = await blobImage(
                    repositoryPath: repositoryPath, commitish: newestCommitish, path: path)
            }
            if status.kind != .new && status.kind != .untracked && status.kind != .deleted {
                previous = await blobImage(
                    repositoryPath: repositoryPath, commitish: "\(oldestCommitish)^",
                    path: oldPath(of: status) ?? path)
            } else if status.kind == .deleted {
                previous = await blobImage(
                    repositoryPath: repositoryPath, commitish: oldestCommitish + "^",
                    path: oldPath(of: status) ?? path)
                if previous == nil {
                    previous = await blobImage(
                        repositoryPath: repositoryPath, commitish: repositoryNullTreeSHA,
                        path: oldPath(of: status) ?? path)
                }
            }
            guard current != nil || previous != nil else { return nil }
            return .image(previous: previous, current: current)
        }
    }

    static func blobImage(repositoryPath: String, commitish: String, path: String) async -> DiffImage? {
        guard let data = await showData(repositoryPath: repositoryPath, commitish: commitish, path: path) else {
            return nil
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return DiffImage(
            base64Contents: data.base64EncodedString(),
            mediaType: mediaType(forExtension: ext),
            bytes: data.count)
    }

    static func readWorkdirImage(repositoryPath: String, path: String) -> DiffImage? {
        let full = (repositoryPath as NSString).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return DiffImage(
            base64Contents: data.base64EncodedString(),
            mediaType: mediaType(forExtension: ext),
            bytes: data.count)
    }

    static func mediaType(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "avif": return "image/avif"
        default: return "text/plain"
        }
    }

    static func showLines(repositoryPath: String, commitish: String, path: String) async -> [String]? {
        guard let data = await showData(repositoryPath: repositoryPath, commitish: commitish, path: path) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Keep empty trailing line semantics simple: split on "\n".
        return text.components(separatedBy: "\n")
    }

    static func showData(repositoryPath: String, commitish: String, path: String) async -> Data? {
        // `git show <commit>:<path>` — failures (missing blob, root without
        // parent) return nil so callers fall back to empty content.
        let result = try? await GitProcess.run(
            ["show", "\(commitish):\(path)"], workingDirectory: repositoryPath)
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout
    }

    static func readWorkdirLines(repositoryPath: String, path: String) -> [String]? {
        let full = (repositoryPath as NSString).appendingPathComponent(path)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
    }

    static func configValue(repositoryPath: String, name: String) async throws -> String? {
        let result = try await GitProcess.run(
            ["config", "--get", name], workingDirectory: repositoryPath)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func parseSubmoduleSHAs(
        repositoryPath: String,
        file: CommittedFileChange,
        selected: [Commit]
    ) async -> (old: String?, new: String?) {
        // Best-effort parse of the submodule patch (`-Subproject commit …`
        // / `+Subproject commit …`). Failures leave SHAs nil (view handles it).
        guard let latest = selected.first else { return (nil, nil) }
        let args: [String]
        if selected.count == 1 {
            args = ["log", latest.sha, "-m", "-1", "--first-parent",
                    "--patch-with-raw", "--format=", "-z", "--no-color", "--", file.path]
        } else if let oldest = selected.last {
            args = ["diff", "\(oldest.sha)^", latest.sha,
                    "--patch-with-raw", "--format=", "-z", "--no-color", "--", file.path]
        } else {
            return (nil, nil)
        }
        guard let result = try? await GitProcess.run(args, workingDirectory: repositoryPath),
              result.exitCode == 0 else { return (nil, nil) }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        var old: String?
        var new: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("-Subproject commit ") {
                old = line.replacingOccurrences(of: "-Subproject commit ", with: "")
                    .replacingOccurrences(of: "-dirty", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("+Subproject commit ") {
                new = line.replacingOccurrences(of: "+Subproject commit ", with: "")
                    .replacingOccurrences(of: "-dirty", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (old, new)
    }

    /// Sum `numstat` added/deleted columns (`-` binary rows count 0).
    static func numstatTotals(_ stdout: String) -> (added: Int, deleted: Int) {
        var added = 0
        var deleted = 0
        for piece in stdout.components(separatedBy: "\0") {
            for line in piece.components(separatedBy: "\n") {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3,
                      let a = Int(cols[0]),
                      let d = Int(cols[1]) else { continue }
                added += a
                deleted += d
            }
        }
        return (added, deleted)
    }
}
