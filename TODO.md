# TODO — remaining known gaps (Tasks 1–16 all merged)

`OLD-PLAN.md` (Tasks 1–10) and `PLAN.md` (Tasks 11–16) were deleted after all
PRs merged to `development`. Only the still-open items below are kept —
each verified against code. Build/test gotchas and seams now live in
`AGENTS.md` and are not repeated here.

## Correctness gaps

- **Partial staging commits full files.** `ChangesStore.performCommit`
  (`Views/Changes/ChangesStore.swift:275-299`) stages `filePaths` wholesale
  via `git add` (`Git/GitService.swift:169-172,198-207`). Needs
  `git apply --cached` patch staging before commit.
- **Banner undo is acknowledge-only (no undo SHA).**
  `shellUndoBanner` (`Views/Shell/ShellPipelineActions.swift:413-436`) only
  refreshes + posts `*Undone` banners; `Banner` carries counts/token, no SHA
  (`Models/Banner.swift:36-41`). True undo needs SHA plumbing + `reset --hard`.
- **`findDefaultBranch` is heuristic.** Local `main` → `master` → first sorted
  (`Stores/GitStore.swift:79-92`, ignores remote). Add `symbolic-ref
  origin/HEAD` call — `RefsParser.swift:77` helper exists with no live caller.
- **Stale `.error` sheets never auto-clear.** `showPopup` always appends
  (`App/AppState.swift:170-190`); successful refresh only updates state
  (`App/AppStore+GitPipeline.swift:66-82`). Decide whether success clears errors.
- **`Popup.multiCommitOperation` has no mode discriminator**
  (`Models/Popup.swift:119` — only `repositoryID`). Merge/squash/rebase/update
  all open the same dialog; add the kind + preselect `defaultBranch` for
  update-from-default.

## Release blockers (need pbxproj-adjacent changes)

- **Sparkle not bundled.** `Services/UpdateService.swift:1,7-13` is a
  state machine only (SPM needs a banned `pbxproj` edit). Release step: set
  `SUFeedURL` to the real appcast (`feedURLFromInfoDictionary`, :104-108;
  dev builds have no key → checks stay local).
- **Deeplink handler without registration.**
  `Services/DeepLinkService.swift:15` + `MyApp.swift:22-24,62-74` parse
  `x-gitdesktop-client://openrepo/…`, but no `CFBundleURLTypes`/Info.plist
  exists in the synced group.
- **Persistence still UserDefaults JSON**
  (`Persistence/RepositoryPersistence.swift:4-8,36-60`). GRDB vs SwiftData
  decision never made — migrate `save`/`load`/`nextID`/`matchExisting` then.

## Polish / small deviations

- **`.cloning` selection unreachable.** Defined (`App/AppState.swift:14`) and
  rendered (`ContentView.swift:98-99`, `CloningRepositoryView`) but nothing
  ever selects it (`CloneDispatcher.swift:74-120` never touches `AppStore`;
  `RepositoryDialogs.swift:329-335` selects the finished repo directly). Wire
  select-on-clone or delete the view.
- **`GitIgnoreEditor` duplicated.** Reusable editor exists
  (`Views/StashTagsWorktrees/GitIgnoreEditor.swift:8`) but
  `RepositorySettingsView.swift:85-96,159-165` rolls its own `TextEditor` +
  direct `readGitIgnore`/`saveGitIgnore`. Unify.
- **Menu routing is focus-unaware.** `Cmd+A` in the commit box also selects
  the file list (`ChangesSidebarView.swift:114-125`; `TextDiffView.swift:167-179`
  likewise). Scope to the focused view if it annoys. Pre-existing: `Cmd+A` in
  plain text fields lost native select-all when the Edit menu was overridden.
- **`DeleteTag` assumes unpushed** (no remote-ls pushed guard);
  `UnreachableCommits` uses a first-reachable heuristic; dirty-WD checkout
  surfaces `.localChangesOverwritten` with no auto-stash (by design).

## Behavioral caveats (by design — callers beware)

- `createStash` does NOT stage first (`Git/Operations/StashOperations.swift:60-62,157-168`
  runs bare `stash push`). Callers must stage, or only tracked mods are stashed.
- `StashOperations.totalCount` mirrors `entries.count - 1` (non-Desktop-stash
  signal). Display `entries.count`.
- `AmendState` stays amending only while HEAD matches the target and no
  conflict flow runs (`Git/Operations/UndoResetOperations.swift`).
- Sync progress is buffered-replay, not streaming (`GitProcess` buffer mode;
  `LFSProgressParser` ready, file-tailing missing; `isLFSFilterLine` skips
  smudge lines). Proxy env respects explicit `*_proxy` only (no system lookup).
