# PLAN.md — GitDesktop integration (task list)

Context: `OLD-PLAN.md` (Tasks 1–10, all merged) built every feature as
standalone views/services against Task-1 contracts. This plan composes them
into a working app: the repo detail still shows placeholders, no data
pipeline feeds the UI, and several menu actions have no subscribers.

Run agents with: `do PLAN.md Task N` (one task per session/branch).
Rules: see `AGENTS.md`. Reference app lives in `electron/` (read-only). Spec lives in `GitDesktop/Docs/`.
Handoff notes live in `TODO.md` (append, don't rewrite history).

> Numbering continues at 11 (Tasks 1–10 are archived in `OLD-PLAN.md`), so
> new `task/<n>-<slug>` branches cannot collide with the old ones.

## Dependency graph + worktrees

```
Task 11 pipeline (BLOCKS 12–14 — do first, merge before parallel work)
  ├─ Task 12 detail composition (RepositoryView: Changes + History)
  ├─ Task 13 foldouts/dialogs composition
  └─ Task 14 menu/toolbar action subscriptions
Task 15 productionize services (INDEPENDENT — anytime, parallel with all)
Task 16 end-to-end fixture pass (needs Tasks 12–14)
```

After Task 11 lands on `development`, Tasks 12–14 can run in parallel worktrees
(they code against the Task 11 `GitStore` contract, never redefine it). Task 15
runs anytime fully parallel. Task 16 runs last.

Branch per task: `task/<n>-<slug>`. Verify every task with:
`xcodebuild -project GitDesktop/GitDesktop.xcodeproj -scheme GitDesktop -destination 'platform=macOS' build`

---

## Task 11 — Data pipeline: GitStore actor + refresh on selection

Read: `GitDesktop/Docs/02-architecture.md`, `09-git-layer.md`.
Implement:
- `Stores/GitStore.swift`: `actor GitStore` per repository owning a
  `LiveGitService`; `refresh()` loads status + branches + recent log +
  remotes and publishes a `RepositoryState`; mutations (stage/unstage/commit/
  branch ops/sync ops) run through the actor then re-refresh. Errors map to
  the `GitError` taxonomy and surface via the `Error` popup — never crash.
- `App/AppStore` (additive): `GitStore` cache keyed by repository hash,
  `selectRepository` triggers `Task { await store.refresh() }`, refresh
  failures for missing repos route to the Missing view.
- Keep `MockGitService` working for all previews/tests (pipeline takes any
  `GitService`).
Files: `GitDesktop/GitDesktop/Stores/GitStore.swift`, additive edits to
`App/*`, `Tests/GitStoreTests.swift` (refresh against a fixture repo:
status/branch/log populate state; git failure posts `.error`).
Accept: selecting a real fixture repo populates working-directory/branches/
history in state; build green; parser/test suites still pass.
Depends: none.

## Task 12 — Repository detail composition (Changes + History)

Read: `GitDesktop/Docs/05-changes-commit.md`, `06-history-diff.md` (§1–3).
Implement: replace the `SidebarPlaceholder`/`DetailPlaceholder` in
`Views/Shell/RepositoryView.swift` with the real views, fed by Task 11 state:
Changes tab → `ChangesTabView` (with `ChangesStore` built from the selected
repo + pipeline service) beside `SeamlessDiffSwitcher`; History tab →
`CompareSidebar` + `CommitListView` + `SelectedCommits` (read-only diff);
empty states from Task 10 (`NoChangesEmptyState`, no-commit-selected,
noncontiguous) where the views don't already cover them. Delete the
placeholder structs when unreferenced. Keep `Ctrl+Tab` + `Cmd+1/2` switching.
Files: `Views/Shell/RepositoryView.swift` (+ thin adapters only — do not
rewrite the feature views).
Accept: fixture repo shows real file list → diff → commit box; history shows
real commits → files → read-only diff; build green.
Depends: Task 11.

## Task 13 — Foldouts + dialogs composition

Read: `GitDesktop/Docs/04-shell-toolbar.md`, `07-branches-operations.md`.
Implement: wire the chrome to the real views/state: branch dropdown →
`BranchesContainerView` (checkout/create/rename/delete via pipeline);
push/pull button primary action + split menu → real fetch/pull/push with
progress wired to the button (`ToolbarView.pushPullPrimaryAction` TODO);
worktree dropdown → `WorktreeList` (+ switch); `DialogHost`: replace
`GenericPopupDialog` cases owned by Tasks 5–8 with the bespoke dialogs
(Create/Rename/Delete branch, MergeWizard, tag/worktree dialogs,
UnreachableCommits) and delete the dead `AcknowledgementsDialog` stub.
`BannerRow.performAction` undo/reopen TODOs (Tasks 5–6) get real handlers.
Files: `Views/Shell/*` (Toolbar/FoldoutViews/DialogHost/BannerHost),
adapters only.
Accept: branch/worktree switching, merge flow, tag/worktree CRUD reachable
from the shell on a fixture repo; no `GenericPopupDialog` for owned cases;
build green.
Depends: Task 11 (parallel with Tasks 12, 14 after Task 11 lands).

## Task 14 — Menu + toolbar action subscriptions

Read: `GitDesktop/Docs/10-interactions.md` (§1–2).
Implement: subscribe every subscriber-less `GitDesktopMenuAction`
(push/pull/fetch, stash-all, update-from-default, compare, merge,
squash-and-merge, rebase, create-tag, rename/delete branch, discard-all)
plus `selectAll`/`findInDiff` gaps to real pipeline operations; disabled
states when no repo is selected; destructive ops keep their confirms.
Unify with the toolbar so menu and button run the same code path (no
duplicate implementations).
Files: `App/Commands.swift` (+ a `Services/MenuActionRouter.swift` if the
routing outgrows the commands file), observers in owning views.
Accept: menu checklist from `Task10Tests.testMenuInventory` every item
executes the real op (or its confirm) on a fixture repo; build green.
Depends: Task 11 (parallel with Tasks 12–13 after Task 11 lands; coordinate
dialog cases with Task 13).

## Task 15 — Productionize services (fully parallel)

Read: `GitDesktop/Docs/01-scope.md` (§3), `TODO.md` (Task 10 follow-ups).
Implement (independent subtasks, no ordering):
- `AppleIntelligenceService`: replace the `streamFoundationModel` /
  `runFoundationModel` placeholders with real `LanguageModelSession`
  streaming. Keep the Explain-only contract (no file writes, no auto-apply).
- `UpdateService`: point `feedURL` at the real appcast (or finish the
  Sparkle `SPUUpdater` drop-in); keep the state machine + banner API.
- Clone cancel: thread cancellation through a clone dispatcher so
  `CloningRepositoryView` Cancel aborts the in-flight clone (currently only
  clears the banner).
Files: `Services/*` only — no view contracts change.
Accept: AI streams real tokens on a macOS 26 Mac (graceful unavailable
elsewhere); update check hits the feed; clone cancel kills the process;
build green.
Depends: none (parallel with everything).

## Task 16 — End-to-end fixture pass + bugfix

Read: all of the above + `TODO.md`.
Implement: scripted pass on a fixture repo covering add → stage → commit →
branch → merge (clean + conflict) → push, plus stash/tag/worktree round
trips and the Task 10 menu/shortcut checklist; file every failure, fix in
this task (additive fixes only — no refactors of other tasks' views).
Extend `Tests/*` for each regression fixed.
Accept: full script passes on a fresh fixture repo; release `xcodebuild`
green; `electron/` untouched.
Depends: Tasks 12–14.

---

## Appendix — composition gotchas (read before Tasks 12–14)

- Task 11's `GitStore` contract is the seam: Tasks 12–14 code against it (plus
  `MockGitService` for previews), never redefine it — extend by additive PRs.
- Views take explicit props + callbacks and do NOT depend on `AppStore`
  (established pattern) — write thin adapters in `Views/Shell/*`, don't
  rewrite feature views to take the store.
- `DialogHost` sheets only `currentPopup` (top of the ≤50 stack);
  `Popup.id` is stable per type. New popup cases are additive to
  `Models/Popup.swift` + `PopupDescriptors.swift` (see `.shortcuts` precedent).
- Menu actions travel via `GitDesktopMenuAction` notifications — Task 14 owns
  the subscriber map; check it before adding new observers.
- Previews/smoke data: `makePreviewStore()` / `populatePreviewData(_:)`;
  DEBUG launch with `GITDESKTOP_SEED_PREVIEW=1` seeds mock repos.
- Gotchas: SwiftUI has no `.accessibilityLiveRegion` — use
  `accessibilityAnnouncement(_:)`; target compiles with
  `-default-isolation=MainActor` + `InferIsolatedConformances` — new
  associated-value enums compared off the main actor must NOT be `Equatable`
  (see `AIAvailability` precedent: use `isAvailable` + `case` matching).
