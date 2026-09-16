# TODO — remaining known gaps (Tasks 1–16 all merged)

`OLD-PLAN.md` (Tasks 1–10) and `PLAN.md` (Tasks 11–16) were deleted after all
PRs merged to `development`. Only the still-open items below are kept —
each verified against code. Build/test gotchas and seams now live in
`AGENTS.md` and are not repeated here.

Since the last revision two items landed and are removed below:
`findDefaultBranch` now resolves `origin/HEAD` via `symbolic-ref`
(`Git/Operations/DefaultBranchOperations.swift`, `Stores/GitStore.swift:87`),
and there is a real unit-test target (`GitDesktopTests`, `xcodebuild test`).
The test target also proves `project.pbxproj` hand-edits are feasible again
(`plutil -lint` + full `build`/`test` to verify) — so the release blockers in
§2 are actionable now, not banned.

## Correctness gaps

None open — the last two landed: banner undo now resets `--hard` to the
recorded pre-op tip (`shellUndoBanner`, `MultiCommitUndoState`), and a
successful refresh clears stale `.error` sheets (`clearErrorPopups`).

## Release drive (Sparkle / deeplink / persistence)

- **Sparkle: framework still not bundled.** Sparkle is the standard macOS
  auto-update framework (outside the App Store): the app polls an
  appcast-XML feed for new versions and installs them in place.
  Already done: `Services/UpdateService.swift` implements the full state
  machine (check → available → downloading → installing →
  installedPendingRestart) against a Sparkle-format appcast, including feed
  parsing/version compare (`feedURLFromInfoDictionary`, :104-108), the
  update banner + showcase + `InstallingUpdate` quit-guard, menu wiring, and
  tests (`Task10Tests`/`Task15Tests`, `simulatedRemoteVersion` seam).
  Still to do:
  1. Add the Sparkle SPM package (Xcode → Package Dependencies; needs a
     `pbxproj` edit — proven feasible since `GitDesktopTests`).
  2. Stand up `SPUStandardUpdaterController` and forward its states into
     `UpdateService.state`; banner/showcase/quit-guard stay as-is.
  3. Set `SUFeedURL` to the real appcast URL (dev builds have no key →
     checks stay local) and host `appcast.xml` + signed update artifacts
     (EdDSA `SUPublicEDKey`).
  4. Verify end to end on a signed release build (old version offers update,
     downloads, installs, restarts).
- **Deeplink handler without registration.** Parsing exists:
  `Services/DeepLinkService.swift:15` (`scheme = "x-gitdesktop-client"`) +
  `MyApp.swift:22-24` (`.onOpenURL`) `,59-74` (`handleDeepLink`: match known
  clone by URL, else `.cloneRepository` popup). But the scheme is not
  registered — no `CFBundleURLTypes` exists (the project uses
  `GENERATE_INFOPLIST_FILE = YES`, so there is no physical Info.plist).
  Still to do:
  1. Register the scheme (`INFOPLIST_KEY_CFBundleURLTypes` entries or a real
     `Info.plist`; needs a `pbxproj`-adjacent edit).
  2. Verify with `open 'x-gitdesktop-client://openrepo/<url>'`: known repo
     gets selected, unknown repo opens the clone dialog.
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
