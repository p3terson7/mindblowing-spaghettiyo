# SAPHIR view-loading audit — 2026-10-15

Baseline: `31a09b7`. Changes avoid work rather than increasing read concurrency.

The measurements below describe the view-loading changes through `6897673`, before the persisted-money cutover. Current monetary behavior is documented in [COMPENSATION-BACKFILL.md](COMPENSATION-BACKFILL.md): no read-time salary calculation remains, and Approved-tab navigation no longer refetches the same stored amounts. Do not interpret these historical timings as a benchmark of that subsequent change.
No DATA schema, lock, write protocol, sync protocol, reader limit, database,
persistent index or additional threading changes.

## Before / after

Median of three fresh backend processes per initial view:

| View | API requests | Payload bytes | Request time | Shared reads | Shared metadata | Enumerations |
|---|---|---|---|---|---|---|
| Personnel, active | 1 → 1 | 87,322 → 24,692 | 1,619 → 255 ms | 48 → 3 | 51 → 3 | 0 → 0 |
| Review, pending | 1 → 1 | 278,803 → 232,526 | 2,625 → 1,383 ms | 47 → 44 | 7 → 3 | 1 → 1 |
| Dashboard | 1 → 1 | 23,155 → 23,155 | 1,884 → 1,454 ms | 46 → 46 | 6 → 5 | 1 → 1 |
| Projects, portfolio | 1 → 1 | 4,818 → 4,818 | 2,188 → 2,234 ms | 46 → 46 | 46 → 5 | 0 → 1 |

Personnel: 84% less first-load time and 72% less payload. Review: 47% less time,
17% less payload. Dashboard: 23% less time with the same DTO size. Projects has
no demonstrated improvement; a 2% difference is not a meaningful performance
claim from three samples.
Projects does avoid 41 individual file-metadata probes using the existing cold
directory scan: total measured shared calls decrease from 92 to 52. Content
reads and salary/statistics work remain necessary. This is an operation-count
reduction, **not** evidence of faster local-disk latency.

Optional history (one supplementary sample): 167 entries / 39,054 bytes became
25 entries / 6,494 bytes, about 83% smaller. **Pagination does not eliminate the
first full JSON file read/parse/sort.** It reduces payload and row projection;
subsequent pages reuse the raw history cache.

Personnel also avoids one initial Chart.js request / 208,522 source bytes. That
is local HTTP from the cached Windows app, not SMB DATA I/O.

### Limits of these measurements

- macOS / Apple M2 Pro, PowerShell 7.4.6, summary tracing, 3 samples per view.
- 40 employees × 4 entries (120 approved, 40 pending), 2 projects, 167 history
  actions, plus one empty supervisor employee file from the permission fixture.
  Missing final snapshots exercise legacy read-time monetary estimation.
- **The SMB test share was unavailable. These are local-disk timings, not R:
  timings.** `fs.shared.*` means application FileStore calls to the configured
  DATA root. Counts represent potential SMB calls on deployment, not packets or
  measured SMB round trips. Actual corporate-Windows performance remains to test.
- Each view has an independent backend; startup/login run first, naturally warm
  auth/config caches, and are excluded from view time. Startup time is retained
  separately. No OS cache purge; no competing suite during measurements.
- Request count excludes login, common shell/assets and periodic sync polling.
  Times include full response transfer, not browser rendering or CPU time.
  Payload is UTF-8 body bytes, not compressed wire bytes.
- Repeat timings were recorded separately, never substituted for cold results.

Raw development reports: `output/view-loading-before-final.json`,
`output/view-loading-after-final.json`, and optional history sample
`output/view-loading-sections-before.json` / `...-after.json`.
The final Projects metadata-batch measurement is in
`output/view-loading-projects-after-final.json` (superseding the Projects row in
the general after report).

## Trace and changes per view

### Review

`loadReviewView` → `/review/bootstrap` → `Get-ApprovalsEntriesModel` → scoped
snapshot → employee contributions → FileStore metadata/prefetch/text/JSON.

Initial bootstrap now returns approvals and project-filter metadata only: no
history read, history factory or audit-row projection. History is a closed
disclosure, not loading skeletons for unrequested data.

Initial approvals preserve stored monetary results. In the measured version,
the Approved tab requested `includeMonetary=true` to estimate missing legacy
amounts. That behavior has since been removed: both bootstrap and the legacy
`/approvals/entries` API read saved amounts or N/A, without estimation. Switching
to Approved uses the already loaded entries, with no additional request.

History opens through `/history?page=1&category=all`, manager-only, fixed at 25
rows. Page/category/date/search validation, filtering, totals and category
counts are server-side. Past-end pages clamp; empty results have one empty page.
Employee-name projection happens on the selected rows (or rows inspected during
requested search), never by loading employee entry files. Search retains case/
accent-insensitive names and English/French action/date labels.

Tabs, filters, refresh and pagination use server pages. Identical in-flight
requests/current pages are reused; old filters/session responses cannot overwrite
new results. Raw sorted history uses the existing `history` dependency/cache;
there is no new high-cardinality page cache. Unpaged `/history` remains for legacy
exports, but the interactive UI no longer uses it.

### Personnel

`loadEmployeesView` → `/employees/bootstrap?scope=active` → metadata-only
`Get-EmployeeDirectoryList` → user/name/project caches → FileStore source files.
No employee DATA files, entry normalization, stats or compensation estimates are
needed to open the directory. Active/archived/all filtering happens before
entry-file/statistics work, not after computing all employees.

The response keeps directory/edit metadata: names, codes, roles, profiles and
project responsibilities. It omits duplicate form lookups and unrequested stats.
Unknown counts/amounts are not rendered as misleading zeros.

- Select a person: existing `/employee/<code>`, scoped as before, one employee.
- Open Analytics or select a project-entry filter: same bootstrap with
  `includeStats=true`; existing stats/monetary caches, not a duplicate endpoint.
- Chart.js loads only when Analytics opens. Closing it makes no request.
  Already-requested card amounts/counts remain visible and synchronized when
  the chart closes; reopening reuses those stats without another data request.
- Open an entry form: existing shared `fetchOvertimeEntryLookups` cache and
  `/self/options`; no eager directory request for these lookup files.
- Direct entry links use `scope=all`, retaining archived navigation. Details
  coalesce in flight, reuse cached entries and discard invalidated results using
  per-resource versions. Unrelated employee changes do not cancel each other.
- After an entry edit/import, only the selected person's detail is reloaded
  unless directory analytics/project filtering is actually visible. The former
  unconditional `/employees?scope=all` refresh is removed.

All-person analytics still needs relevant employee data when requested. That
cost is **deferred**, not claimed to disappear.

### Dashboard

`refreshDashboardView` → `/dashboard/bootstrap` → dashboard → scoped snapshot →
employee contributions + recent history → FileStore.

Scoped snapshots now use raw contributions, avoiding global entry projections
which were immediately projected again for manager permissions. The unscoped
snapshot/export API and scope keys remain unchanged. Diverse privileges survive
the raw path. Recent history sorts raw rows once and projects only seven, not
all 167. DTO size is unchanged. This saves processing, not cold history reads.
Department totals/queues still need employee data; no stale persisted totals.

### Projects and other views

Projects: `refreshProjectsView` → `/projects/bootstrap?...&includeDetail=false`
→ summary/trend/project-entry models → monetary scoped contributions → FileStore.
Its measured portfolio DTO is only 4,818 bytes. Workspace details already load
on open; `/stats/budget-periods` loads only when comparison expands; exports are
explicit. These boundaries are retained/tested. Cold Projects now reuses the
existing synchronous metadata batch instead of probing each employee file;
small/warm/single-file changes keep that helper's no-scan path. No workers were
added. A listing failure falls back to the existing per-file checks (listing
permissions must not become a new requirement). Global project share and historical totals require the relevant dataset;
excluding unseen projects would
change denominators. No payload-only rewrite is called an I/O saving.

Self bootstrap already reads one employee and selectors needed by visible punch
controls. Settings/grid configuration and exports are user-triggered. Bug-report
list/detail and image-binary retrieval are already separate. These paths were
audited and preserved; splitting their useful bootstrap into extra sequential
HTTP calls would not be an improvement.

## Sync and freshness

Revision protocol, auth/revocation checks, atomic writes, capacity, bounded
reconciliation, reconnect fallback and five-minute conservative content-safety
reset remain unchanged. This change does not solve that periodic cold rebuild.

- Entry mutation: invalidate that employee's detail; do not reload a metadata-
  only directory. Refresh selected details only if affected. Visible analytics
  still refreshes its aggregates.
- History mutation: invalidate/refresh the visible page, not approvals. Closed
  history is only marked stale. Reopen/navigation restores fresh data.
- Project/auth mutation: invalidate form lookups and permission-sensitive
  details; refresh project-aware directory metadata where needed.
- Hidden tabs do not start optional requests; returning refreshes stale sections.
  Session changes clear optional caches and cancel old response publication.
- Version gaps/unknown changes retain conservative invalidation.

No new polling or HTTP concurrency. Each initial bootstrap is still one API
request; requested history adds one per page, requested Analytics one bootstrap.

## Tests and reproduction

New: `test-view-loading-laziness.ps1`, `test-view-loading-architecture.js`.
Expanded HTTP tests cover anonymous/employee denial, manager access, fixed page
size, invalid pages and lightweight payloads. Existing monetary, navigation,
asset loading, remote mutation, dependency, revocation and export tests remain.

Validation: **135 selected, 135 passed, zero failures** in about 90 seconds on
macOS. Windows-only runtime checks retain their platform skips; static Windows
PowerShell 5.1 checks passed, not a claim of executing the new UI on Windows.
A real Chromium smoke run also exercised lazy Personnel directory/detail/
analytics, Review/history, and Projects: 10 browser/backend correlations, no
JavaScript errors, no incomplete spans, and preserved 40-employee/40-pending
dashboard totals. Artifacts: `output/view-loading-browser-smoke-final`. Reproduce that
optional development smoke with `SAPHIR_VALIDATE_LAZY_VIEWS=1` and the existing
`scripts/dev/capture-performance-browser-sample.js` (installed Playwright and
Chromium required; no SAPHIR runtime dependency was added).

From a **source checkout**, not an installed distribution:

```powershell
.\scripts\benchmark-view-loading.ps1 -ReportPath .\output\view-loading.json
.\scripts\benchmark-view-loading.ps1 -FixtureParent 'R:\approved-test-folder' `
  -ReportPath .\output\view-loading-smb.json
```

Only owned GUID fixture/runtime subfolders are created/removed; existing DATA is
not used. `-ApplicationRoot <baseline-checkout>\app` selects baseline sources;
`-Views 'history?page=1'` measures optional history. Missing matching backend
summaries fail the benchmark instead of yielding incomplete counts. The caller's
PowerShell runtime is reused, including Windows PowerShell 5.1.

The deployed **Benchmark SAPHIR.bat** remains the automatic real-data API report
collector. Its sequential rounds are not independent per-view cold tests.
