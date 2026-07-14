# Stable Popup and Deferred Updater Plan

1. Add RED tests for stable slideout height, exact footer modifier matching,
   and disabled updater initialization.
2. Run one CI workflow and confirm only the new contracts fail (plus verify the
   already-implemented search invalidation tests are green).
3. Preserve `NSWindow.frame.height` in `SlideoutController` preview toggles and
   remove the now-unused preferred-height dependency.
4. Move clear-all modifier classification into a pure `Footer` operation and
   require equality after device-independent masking.
5. Initialize `SPUStandardUpdaterController` with `startingUpdater: false`, add
   an idempotent start gate, and invoke it only for enabled automatic checks or
   explicit checks.
6. Run the complete workflow, self-review the diff, record evidence, and
   fast-forward the branch into `master` while preserving the primary worktree.

## Execution record

Steps 1–6 completed. RED run `29295765539` isolated the three intended behavior
failures after run `29295646454` exposed and supplied the generated-project
registration diff. GREEN run `29296154347` passed the full matrix on attempt 2
after one failed-job retry for the documented `testCopyImage` 3-second
contention flake.
