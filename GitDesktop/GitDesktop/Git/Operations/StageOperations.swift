import Foundation

// MARK: - StageOperations
// Port of `electron/app/src/lib/git/update-index.ts` (`updateIndex`,
// `stageFiles`) and the `applyPatchToIndex` flow in
// `electron/app/src/lib/git/apply.ts`.
// Pure builders/partitioning are `nonisolated` and Foundation-only so they
// stay harness-testable; `StageLiveOperations` runs the git commands with
// the same args/env as the reference (`GitProcess` buffer mode).

// MARK: Pure

/// Options for `git update-index`. Defaults mirror the reference: new files
/// are added and removals honored (unlike bare git, which ignores both).
public struct UpdateIndexOptions: Sendable, Equatable {
    public var add: Bool
    public var remove: Bool
    public var forceRemove: Bool
    public var replace: Bool

    nonisolated public init(
        add: Bool = true, remove: Bool = true,
        forceRemove: Bool = false, replace: Bool = true
    ) {
        self.add = add
        self.remove = remove
        self.forceRemove = forceRemove
        self.replace = replace
    }
}

/// Args for `git update-index … -z --stdin` (paths on NUL-separated stdin).
/// Port of `updateIndex`.
nonisolated public func updateIndexArgs(options: UpdateIndexOptions = UpdateIndexOptions()) -> [String] {
    var args = ["update-index"]
    if options.add { args.append("--add") }
    if options.remove || options.forceRemove { args.append("--remove") }
    if options.forceRemove { args.append("--force-remove") }
    if options.replace { args.append("--replace") }
    args += ["-z", "--stdin"]
    return args
}

/// Args for `git apply --cached` of a selection patch.
/// Port of the `applyArgs` in `applyPatchToIndex`.
nonisolated public func applyPatchToIndexArgs() -> [String] {
    ["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-"]
}

/// Split to-be-committed files into full-file paths (staged via
/// `update-index`) and partial files (staged via `git apply --cached`).
/// Port of the `stageFiles` partitioning: fully selected files land in
/// `fullPaths` (renamed sources also in `oldRenamedPaths`, deletions also
/// in `deletedPaths`); partially selected files land in `partialFiles`.
/// `.none` files are skipped defensively (callers pass the already-filtered
/// `filesToBeCommitted`, so they never occur — the reference relies on the
/// same filtering).
public struct PartitionedCommitFiles: Sendable, Equatable {
    public var fullPaths: [String]
    public var oldRenamedPaths: [String]
    public var deletedPaths: [String]
    public var partialFiles: [WorkingDirectoryFileChange]

    nonisolated public init(
        fullPaths: [String] = [], oldRenamedPaths: [String] = [],
        deletedPaths: [String] = [], partialFiles: [WorkingDirectoryFileChange] = []
    ) {
        self.fullPaths = fullPaths
        self.oldRenamedPaths = oldRenamedPaths
        self.deletedPaths = deletedPaths
        self.partialFiles = partialFiles
    }
}

nonisolated public func partitionCommitFiles(_ files: [WorkingDirectoryFileChange]) -> PartitionedCommitFiles {
    var full: [String] = []
    var oldRenamed: [String] = []
    var deleted: [String] = []
    var partial: [WorkingDirectoryFileChange] = []
    for file in files {
        switch file.selection.getSelectionType() {
        case .all:
            full.append(file.path)
            if case .renamed(let oldPath, _, _) = file.status {
                oldRenamed.append(oldPath)
            } else if file.status.kind == .deleted {
                deleted.append(file.path)
            }
        case .partial:
            partial.append(file)
        case .none:
            continue
        }
    }
    return PartitionedCommitFiles(
        fullPaths: full, oldRenamedPaths: oldRenamed,
        deletedPaths: deleted, partialFiles: partial)
}

/// True when the status carries a submodule payload (partial staging of
/// submodules is unsupported, mirroring the reference guard).
nonisolated public func fileHasSubmoduleStatus(_ status: AppFileStatus) -> Bool {
    switch status {
    case .new(let s): return s != nil
    case .modified(let s): return s != nil
    case .deleted(let s): return s != nil
    case .copied(_, _, let s): return s != nil
    case .renamed(_, _, let s): return s != nil
    case .conflictedWithMarkers(_, _, _, _, let s): return s != nil
    case .manualConflict(_, _, _, let s): return s != nil
    case .untracked(let s): return s != nil
    }
}

/// Parse the first `git ls-tree HEAD -- <path>` line
/// (`<mode> SP <type> SP <object> TAB <file>`) into `(mode, oid)`.
/// Port of the `ls-tree` parsing in `applyPatchToIndex`.
nonisolated public func parseLsTreeModeAndOid(_ stdout: String) -> (mode: String, oid: String)? {
    guard let first = stdout.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true).first else {
        return nil
    }
    let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count == 3 else { return nil }
    return (String(parts[0]), String(parts[2]))
}

// MARK: Live

public enum StageLiveOperations {
    /// Run `git update-index` for `paths` (NUL-separated on stdin).
    /// Noop for an empty list.
    nonisolated public static func updateIndex(
        repositoryPath: String,
        paths: [String],
        options: UpdateIndexOptions = UpdateIndexOptions()
    ) async throws {
        guard !paths.isEmpty else { return }
        let args = updateIndexArgs(options: options)
        let result = try await GitProcess.run(
            args, workingDirectory: repositoryPath,
            stdin: Data(paths.joined(separator: "\0").utf8))
        if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
    }

    /// Fresh workdir-vs-HEAD diff for staging (unexpanded, whitespace shown —
    /// the reference `applyPatchToIndex` always diffs without `-w`).
    /// Same `git diff` args as `RepositoryDetailLoading.workingDirectoryDiff`,
    /// kept here so the Git layer stays free of View-layer isolation.
    nonisolated public static func workingDirectoryDiffForStaging(
        repositoryPath: String,
        file: WorkingDirectoryFileChange
    ) async throws -> Diff {
        if fileHasSubmoduleStatus(file.status) {
            throw PatchFormatterError.unsupportedDiff(path: file.path)
        }
        var args = ["diff", "--no-ext-diff", "--patch-with-raw", "-z", "--no-color"]
        switch file.status.kind {
        case .new, .untracked:
            args += ["--no-index", "--", "/dev/null", file.path]
        case .renamed:
            args += ["--", file.path]
        default:
            args += ["HEAD", "--", file.path]
        }
        let result = try await GitProcess.run(args, workingDirectory: repositoryPath)
        // `--no-index` exits 1 when differences exist.
        if result.exitCode != 0 && result.exitCode != 1 {
            if let error = classifyGitResult(result, args: args, successExitCodes: [0, 1]) { throw error }
            throw GitError(
                kind: nil, args: args,
                stdout: result.stdoutString, stderr: result.stderrString,
                exitCode: result.exitCode)
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let patchText = text.components(separatedBy: "\0").last ?? ""
        let parsed: RawDiff
        do {
            parsed = try DiffParser.parse(patchText)
        } catch {
            throw PatchFormatterError.unsupportedDiff(path: file.path)
        }
        if parsed.isBinary {
            throw PatchFormatterError.unsupportedDiff(path: file.path)
        }
        return .text(TextDiffData(
            text: parsed.contents, hunks: parsed.hunks,
            lineEndingsChange: nil,
            maxLineNumber: parsed.maxLineNumber,
            hasHiddenBidiChars: parsed.hasHiddenBidiChars))
    }

    /// Stage one partially selected file via `git apply --cached`.
    /// Port of `applyPatchToIndex` (including the rename preamble, which
    /// recreates the `git mv` in the index before applying the patch).
    nonisolated public static func applyPatchToIndex(
        repositoryPath: String,
        file: WorkingDirectoryFileChange,
        diff: Diff
    ) async throws {
        if case .renamed(let oldPath, _, _) = file.status {
            let addArgs = ["add", "--update", "--", oldPath]
            let addResult = try await GitProcess.run(addArgs, workingDirectory: repositoryPath)
            if let error = classifyGitResult(addResult, args: addArgs, successExitCodes: [0]) { throw error }
            let lsArgs = ["ls-tree", "HEAD", "--", oldPath]
            let lsResult = try await GitProcess.run(lsArgs, workingDirectory: repositoryPath)
            if let error = classifyGitResult(lsResult, args: lsArgs, successExitCodes: [0]) { throw error }
            guard let (mode, oid) = parseLsTreeModeAndOid(lsResult.stdoutString) else {
                throw PatchFormatterError.unsupportedDiff(path: file.path)
            }
            let cacheArgs = ["update-index", "--add", "--cacheinfo", mode, oid, file.path]
            let cacheResult = try await GitProcess.run(cacheArgs, workingDirectory: repositoryPath)
            if let error = classifyGitResult(cacheResult, args: cacheArgs, successExitCodes: [0]) { throw error }
        }
        // Non-text diffs (binary/submodule/image/unrenderable) cannot be
        // partially committed — mirrors the reference guard.
        if patchTextDiffData(from: diff) == nil {
            throw PatchFormatterError.unsupportedDiff(path: file.path)
        }
        let patch = try formatPatch(file: file, diff: diff)
        let args = applyPatchToIndexArgs()
        let result = try await GitProcess.run(
            args, workingDirectory: repositoryPath, stdin: Data(patch.utf8))
        if let error = classifyGitResult(result, args: args, successExitCodes: [0]) { throw error }
    }

    /// Set up the index to reflect the user's selection, after the caller
    /// reset it. Port of `stageFiles`: force-remove rename sources, stage
    /// full files, force-remove deletions, then apply per-file patches.
    nonisolated public static func stageFiles(
        repositoryPath: String,
        files: [WorkingDirectoryFileChange]
    ) async throws {
        let partitioned = partitionCommitFiles(files)
        try await updateIndex(
            repositoryPath: repositoryPath,
            paths: partitioned.oldRenamedPaths,
            options: UpdateIndexOptions(forceRemove: true))
        try await updateIndex(
            repositoryPath: repositoryPath,
            paths: partitioned.fullPaths)
        try await updateIndex(
            repositoryPath: repositoryPath,
            paths: partitioned.deletedPaths,
            options: UpdateIndexOptions(forceRemove: true))
        for file in partitioned.partialFiles {
            let diff = try await workingDirectoryDiffForStaging(
                repositoryPath: repositoryPath, file: file)
            try await applyPatchToIndex(
                repositoryPath: repositoryPath, file: file, diff: diff)
        }
    }
}
