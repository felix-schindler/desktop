# AGENTS.md — GitDesktop (native SwiftUI) + electron (reference)

## Layout

- `electron/` — ORIGINAL Electron+React app. READ-ONLY reference. Never edit, never build unless asked. Old paths in `GitDesktop/Docs/*.md` that say `app/src/...` now mean `electron/app/src/...`. `git status` must never show `electron/` modifications.
- `GitDesktop/` — native macOS SwiftUI app. All work happens here.
  - `GitDesktop/GitDesktop/` — Swift sources (filesystem-synced group: just add files, NEVER hand-edit `project.pbxproj`).
  - `GitDesktop/GitDesktop.xcodeproj` — scheme `GitDesktop`, target macOS 26.0, Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  - `GitDesktop/Docs/` (`00-README.md` → `12-task1-handoff.md`) — reimplementation spec, source of truth for behavior.
- `TODO.md` — remaining known gaps (Tasks 1–16 plans archived and removed after merge).

## Scope (hard exclusions — do not implement)

No GitHub integration (OAuth, PRs, issues, forks, publish-to-GitHub, `View on GitHub`, avatars, checks). No editor/terminal integration — only `Show in Finder` via `NSWorkspace`. No Copilot. No theme setting (system appearance only). No OS notifications. No date/number format settings (system formatters only). GH/editor/Copilot/theme code in `electron/` tells you what to OMIT, not to port. No third-party deps (Sparkle SPM still needs a banned `pbxproj` edit — forward states into `UpdateService` when that happens).

## Build / verify

```bash
xcodebuild -project GitDesktop/GitDesktop.xcodeproj -scheme GitDesktop -destination 'platform=macOS' build
```

- No test target (pbxproj is hands-off). Suites in `GitDesktop/GitDesktop/Tests/*Tests.swift` expose `runAll()` and compile via a `swiftc` harness: pass `-module-name GitDesktop`, name the entry file `main.swift`. Example file set is documented atop `Tests/Task15Tests.swift` / `Tests/Task16Tests.swift` (whole app minus `MyApp.swift` for end-to-end; smaller Foundation-only subsets per-suite).
- Harness deadlock trap: `Task15Tests.runAll()` is sync but pumps `RunLoop.main` internally — run it standalone, never from inside `Task { @MainActor }`. Keep `@MainActor` suites (`GitStoreTests`, `Task14Tests`, `RepositoryDetailTests`, `Task16Tests`) in a separate binary via the `Task { @MainActor … }; dispatchMain()` pattern.
- Keep pure logic in Foundation-only files (e.g. `ChangesLogic.swift`, `Git/Parsers/`, `Git/Progress/`) so it stays harness-testable without git or AppKit.

## Architecture seams (code against these, never redefine)

- Per-repo git work lives in `actor GitStore` (`Stores/GitStore.swift`), cached by `AppStore` keyed on `Repository.hash`. `selectRepository` triggers async `refresh()` (status + branches + recent log + remotes → `RepositoryState`); selection never blocks on git. Mutations go through `performPipelineMutation` / `performSyncPipelineMutation` (serial through the actor, then re-refresh; failures post `.error` popup or route vanished paths to the Missing view — never throw to views, never crash).
- Feature views take explicit props + callbacks and do NOT depend on `AppStore` — write thin adapters in `Views/Shell/*` (`RepositoryDetailLoading.swift`, `ShellPipelineActions.swift`), don't rewrite feature views to take the store. Menu + toolbar share one path: menus post `GitDesktopMenuAction` notifications, `MenuActionRouter` + `AppStore.handleMenuAction` execute (observed once in `ContentView.mainShell`); toolbar calls the same `AppStore` methods directly.
- `DialogHost` sheets only `currentPopup` (top of the ≤50 stack); `Popup.id` is stable per type — new cases are additive. `BannerHost` auto-dismisses success/info after 5s. `MockGitService` backs all previews/tests; `makePreviewStore()` / `populatePreviewData(_:)` + DEBUG `GITDESKTOP_SEED_PREVIEW=1` seed smoke data.
- Compare repo/worktree paths canonicalized (`resolvingSymlinksInPath`) — git returns `/private/var/…`, stored paths may be `/tmp/…`.
- `Process`-based git (`GitProcess`) with reference-identical env (`TERM=dumb`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_PARAMETERS`, `GIT_USER_AGENT`); buffer mode except `runCancellable` (clone cancel via `CloneDispatcher`, which owns partial-dir cleanup). Map failures to the `GitError` taxonomy.

## Swift 6 / SDK gotchas (all verified — do not reintroduce)

- Associated-value enums compared off the main actor must NOT be `Equatable` (synthesized `==` infers MainActor-isolated and breaks Swift 6 builds; see `AIAvailability`: test via `isAvailable` + `case` matching).
- No `.accessibilityLiveRegion` on macOS — use `accessibilityAnnouncement(_:)`.
- `onKeyPress` closure form only (`onKeyPress { press in … }`, `KeyPress.key`); no `.foregroundStyle(cond ? … : …)` Color-vs-style ternaries — use `.foregroundColor` with explicit `Color`s.
- Two swift-frontend crashers: `if let x` shadowing an `@State var x` while assigning `x = …` inside the closure — bind a different name; `try? await … ?? try? await …` is illegal (`??` RHS is a sync autoclosure) — split into separate `let`s.
- Pure helpers must stay free functions, not `static` on a `@MainActor` class, or the non-isolated `swiftc` harness won't link them.

## Git workflow

- Branch per change: `task/<n>-<slug>` or `fix/<slug>` off `development`. Push only to `origin` (`felix-schindler/desktop`) — never push to or open PRs against `upstream` (`desktop/desktop`, the Electron reference). Leave `electron/` untouched.
