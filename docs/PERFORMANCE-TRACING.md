# SAPHIR performance tracing

This is diagnostic instrumentation, not another application optimization. Caching, salary rules, authorization, shared locks, atomic writes, synchronization, worker limits and the single HTTP execution lane are unchanged.

## How to capture a real SAPHIR performance trace on a corporate Windows workstation

After a full deployment, double-click **Benchmark SAPHIR.bat** in the deployed
`SAPHIR-Distribution` folder. Enter your SAPHIR username/password once (password
hidden). It starts the published app against its real shared DATA, automatically
tests the main GET endpoints twice, and saves a report ZIP under
`%LOCALAPPDATA%\SAPHIR\diagnostics`. Send that ZIP. No browser exports or manual
log collection are needed. It restores normal, untraced operation afterward.

The report includes request duration/status/response size and matching sanitized
backend stdout aggregates, when available. A failed optional JSONL writer does
not prevent the HTTP benchmark or stdout aggregates. No response bodies, names,
salary values, password or token are exported. Business endpoints are GET-only;
the only POSTs are normal login and logout for the benchmark's own session.
Use an administrator account to measure management views; access-denied and
server-error responses are reported as failures, not successful load times.
This is an API benchmark, not a browser-render or isolated-cold-load benchmark.
Summary tracing still adds overhead. Do not run alongside other work in SAPHIR.

For manual browser tracing instead:

For summary mode from that same deployed folder, run
`.\scripts\start-performance-capture.ps1 -Level summary`.
The PowerShell command also works from the installed application folder. A bootstrap-only
deployment cannot add instrumentation to an older application release: publish a
full release containing diagnostics first.

1. Install/publish the version containing these diagnostics first. Open its installed application folder—the folder containing `app` and `scripts`. With the cached launcher, it is under `%LOCALAPPDATA%\SAPHIR\versions\<installed-release>`. Use the release shown by the launcher, not an arbitrary old version.
2. Open PowerShell in that folder and run:

   ```powershell
   .\scripts\start-performance-capture.ps1 -Level detailed
   ```

   This restarts only the verified SAPHIR backend using the existing launcher checks, enables diagnostics for that process, and opens the browser with diagnostics enabled. It does not edit shared configuration. If company policy blocks scripts or `Add-Type`, ask IT; do not disable security protection. A diagnostic initialization warning means persistent tracing is unavailable, not that business data should be changed.
3. Sign in normally. If the browser restores an existing session, the capture shows session restoration rather than a new login. To capture a fresh login, sign out and sign back in. Do not clear shared DATA or manually delete session files.
4. Open the administrator dashboard. Wait until its loading indicators disappear. A slow load is useful evidence: do not click refresh repeatedly while capturing it.
5. Click **Export performance trace** at the bottom right. Save that browser JSONL file locally; no data is uploaded. If the page freezes, export after it recovers if possible. The backend file remains useful even without the browser export.
6. Press Win+R and open:

   ```text
   %LOCALAPPDATA%\SAPHIR\diagnostics\performance
   ```

   Backend/launcher files are named `SAPHIR-performance-<UTC>-<PID>-<random>-0001.jsonl`. A capture can span rotated files and more than one process. Keep the complete set from your capture; the analyzer can read the folder. Do not automatically copy it to the business-data share. Browser exports are in the download location you selected.
7. Generate the report from the same application folder:

   ```powershell
   .\scripts\analyze-performance-trace.ps1 `
     -TracePath "$env:LOCALAPPDATA\SAPHIR\diagnostics\performance" `
     -BrowserTracePath "$env:USERPROFILE\Downloads\SAPHIR-browser-performance-<id>.jsonl" `
     -OutputBase "$env:LOCALAPPDATA\SAPHIR\diagnostics\performance\meeting-load" `
     -Csv
   ```

   Replace the browser filename with the one you saved. Omit `-BrowserTracePath` if unavailable. Open `meeting-load.md` for the readable report; `.json` and `.csv` contain the detailed results. Reading a single backend file automatically includes its rotated peers. A directory includes all JSONL files in that directory, so prefer a selected capture directory/file if older captures are present.
8. Disable diagnostics afterward: restart SAPHIR normally in a fresh terminal with:

   ```powershell
   .\scripts\launch-app.ps1 -Force
   ```

   Open `http://localhost:8081/` without `?saphirTrace=...`. Closing a browser tab or removing environment variables does not stop tracing inside an already-running backend; it needs that normal restart. `start-performance-capture.ps1` restores its caller's environment automatically, so future launches are not permanently opted in.

Detailed tracing has a measurable cost. Capture one slow load, then turn it off. For a lighter first comparison, use `-Level summary`; take an untraced run as well. Never infer the production bottleneck solely from a detailed run's total time.

## Configuration

For direct launches, set these variables **before starting the process**:

```powershell
$env:SAPHIR_PERFORMANCE_TRACE = "1"
$env:SAPHIR_TRACE_LEVEL = "summary" # or detailed
.\scripts\launch-app.ps1 -Force
```

The older `SAPHIR_PERF_TRACE=1` remains supported. Either flag enables tracing; clear both to disable it. The browser opt-in is separate: `http://localhost:8081/?saphirTrace=summary` or `detailed`. That separation avoids an extra diagnostic HTTP request and avoids modifying authentication headers. Correlation uses the backend's response header `X-SAPHIR-Trace`.

| Setting | Default | Bounds / purpose |
|---|---|---|
| `SAPHIR_PERFORMANCE_TRACE` | disabled | `1` explicitly enables it |
| `SAPHIR_TRACE_LEVEL` | `summary` | `summary` / `detailed` |
| `SAPHIR_TRACE_MAX_MB` | 16 | 1–128 MiB per backend/launcher file |
| `SAPHIR_TRACE_MAX_FILES` | 8 | 1–32 rotated files per producing process |
| `SAPHIR_TRACE_RETENTION_DAYS` | 7 | 1–90 days; cleanup when a writer starts |
| `SAPHIR_TRACE_DIR` | local diagnostics directory | Optional local subdirectory of local application data or local OS temporary storage; never a UNC/network destination |

The writer rejects network drives and redirected/junction/symlink ancestors where detected. Overrides cannot point at a workspace or DATA share merely because it is mounted locally. On Windows, the diagnostic directory's inherited ACL is replaced by access for the current user and SYSTEM. On Unix, directories use 0700 and trace files 0600. Failure to establish safe diagnostics disables the writer instead of failing a business request. Network-mounted home/temp locations and unusual filesystems are not universally detectable; use the default genuinely local Windows location.

File-count limits apply per process. Old captures within the retention window from other processes are not automatically capped as a global disk quota. Retention deletes only this writer's `SAPHIR-performance-*.jsonl` files, not reports/browser exports/unrelated files. Clock changes can affect retention dates and display ordering, never measured durations.

## What was already present, and what was missing

The previous `PerformanceTrace.ps1` emitted one `SAPHIR_PERF` stdout summary at request completion: inclusive/self totals for selected functions, filesystem-attempt counters, cache counters, anonymized resource counts, endpoint memory samples and cache inventory. It timed startup as a single total and merged worker totals with a `worker.` prefix.

It did **not** persist started operations before a hang, retain every call instance/order, provide span/parent IDs, give individual I/O latencies, reconstruct concurrent worker trees, isolate runspace setup/collection/disposal, or measure browser/session/rendering stages. The resource hash was unkeyed. The new implementation extends that same tracer, keeps the existing stdout summary contract for benchmarks, adds an ephemeral keyed resource hash, and persists schema-2 JSONL events.

## Implementation and scope

`app/backend/lib/PerformanceTrace.ps1` owns one record and stack **per runspace**. `PerformanceTraceWriter.cs` is an optional built-in .NET helper, compiled only when tracing is enabled. It has one background thread, one bounded 4,096-line producer queue and one file writer. Workers send redacted strings through this queue; they never append to shared files themselves. No PowerShell executes on the writer thread and no third-party runtime dependency or telemetry service is introduced.

The startup trace measures writer initialization/compilation, configuration import, each backend script/module-containing load, initial FileStore/schema/auth access, route compilation and listener startup. Startup failures get an error/incomplete trace and close the writer. The `launch-app.ps1` capture also measures its existing process-start/readiness boundary; it keeps normal ownership/port safety checks intact.

The only structural adjustments are the instrumented top-level script-loading loop (same files, same order, same scope), diagnostic wrappers preserving declared/inline/default/unbound arguments, optional traced callbacks around I/O, additional immutable worker diagnostic context, and diagnostic `try/finally` boundaries. Application data, scheduling batches, concurrent reader limits and cache algorithms are unchanged.

### Workflows/functions instrumented

| Component | Included work |
|---|---|
| Launcher | `Launcher.StartApplication`, `Launcher.StartManagedProcessAndWaitReady`, service helpers in detailed mode |
| Startup | configuration, `Startup.Load.*`, initial filesystem initialization, route compilation, listener startup |
| HTTP | arrival after `GetContext`, control/CORS/routing, route-dispatch span, request-body reader, authorization, response writing, critical bootstrap serialization |
| Authentication | user/session lookup, aggregate password validation, session creation/revocation/publication and their FileStore calls; never password/token values |
| Sync/cache | reconciliation functions, revision/fingerprint comparison, conservative fallback, file/cache lookup, source invalidation, affected model counts, LRU eviction, cache construction |
| Read models | dashboard/self/project/review/personnel builders, snapshots, normalization/projection facades, directory/project/history loading, per-employee contribution computation and scope projection |
| FileStore | existence helpers, metadata/parent metadata, enumeration, text/byte reads, parsing/serialization, temporary writes, replacement/move, ambiguous-commit verification, lock opening/metadata and lock/retry waiting |
| Runspaces | pool creation/opening, invocation creation, submission, worker entry/load/read, result collection, merging, invocation/pool disposal |
| Browser | AppShell initialization, restore/login/session application, bootstrap, dashboard initialization, fetch-to-headers, body reading, JSON parsing, state processing and rendering functions, successful refresh plus two animation frames |

Detailed mode automatically proxies eligible application-defined **non-module** backend functions, excluding the tracer itself. Internal PowerShell/.NET/cmdlet/private domain-module calls are not rewritten; they are inside the enclosing facade span. Summary mode proxies major service/storage boundaries and keeps aggregate counters, rather than every small helper. Browser summary measures critical workflows; browser detailed additionally retains individual state/render helper spans. This is intentionally a finite critical-workflow trace, not an interpreter profiler of every language/runtime operation.

### Event contract and privacy

Events include `trace_start`, `span_start`, `span_end`, `filesystem_operation`, `cache_event`, `worker_event`, `error`, `trace_end` and the compatible `trace_summary`. Spans carry trace/span/parent IDs, trusted operation/component/type labels, UTC display times, monotonic offsets/durations, status, process/thread/runspace identifiers and applicable bounded diagnostic fields.

Only an allowlist of numeric/boolean fields and trusted diagnostic labels is serialized. Error **types/categories** are recorded, not messages, stacks or exception data. Request query strings and dynamic route segments are removed. Resource/model identifiers are HMAC-SHA256-derived with a random per-trace secret shared only with that trace's workers; the secret is never persisted. Repeated resources correlate within a request, not across independent traces. No names, HRMIS values, salary values, request bodies, JSON business content, credential/session secrets or raw shared paths are copied into traces. Normal existing application stdout/stderr warnings are not part of the exported JSONL diagnostic bundle.

### Persistence and durability

Producers serialize already-redacted bounded events, then enqueue without blocking. One writer rotates JSONL files and flushes approximately every **250 ms or 64 events**. It flushes to the OS, not a physical-disk `fsync` on every operation. Normal shutdown drains the queue; writer shutdown waits at most five seconds. Each event is a complete JSON line.

The expected healthy-disk unflushed window is about 250 ms, not a crash/power-loss guarantee. A blocked disk, saturated queue, forced termination or storage/permission failure can lose more. Dropped/failed writer counters are captured at request completion when available; a crash may lose those counters too. Queue capacity and event-size limits bound memory. Rotation/retention can remove earlier span starts/parents; the analyzer flags missing context, malformed tails and unfinished spans rather than pretending the trace is complete. Worker events already enqueued remain recoverable even if result collection never finishes.

## Reading the report correctly

The analyzer writes A–H sections: lifecycle timeline, chronological parent/child tree, slowest calls, repeated operations, shared filesystem latency distribution, bounded worker concurrency, cache analysis, and measured facts versus interpretations/hypotheses. JSON contains all reconstructed spans, worker activity timelines, scheduling-delay samples, cache events, aggregate counters and correlated browser/backend requests. CSV optionally lists individual spans.

Inclusive durations overlap. Exclusive time subtracts the **union** of direct-child intervals clipped to the parent, so eight simultaneous 100-ms workers do not subtract 800 ms from a 150-ms parent. An unfinished/missing child makes exclusive time an upper bound. Inclusive sums and process CPU time across cores can exceed wall time.

Filesystem timings are **application-level** calls. They include OS/provider/security/diagnostic overhead; they are not a count of SMB packets or pure network waiting. Exclusive/unattributed time is not CPU time. Before-worker-entry delay includes scheduling/slot dispatch and engine entry; it cannot isolate every private PowerShell engine stage. Collection wait overlaps execution, and return/marshal costs are inside its boundary.

Browser and backend use separate monotonic clocks and are joined only by response trace IDs. HTTP-to-headers differs from backend response-close timing; a small negative difference is possible and not evidence of a clock defect. Body transfer/parsing and rendering have separate spans. “Usable” means successful dashboard refresh followed by two animation frames, not a full OS responsiveness measurement. Navigation-to-usable includes user interaction/think time; dashboard-refresh-to-usable does not include time spent entering credentials.

## Sample report and measured overhead

A real headless Chromium sample against a **synthetic 40-employee domestic SMB fixture** produced 10,459 events in two JSONL files, four browser/backend correlations, zero incomplete/missing-parent spans, and an observed maximum of eight workers. The fixture contained 40 hours and 40 pending approvals; no real account/DATA was used. The complete generated Markdown/JSON/CSV report is in `output/performance-browser-sample-final/complete-report.*` in the development workspace.

Measured sample facts:

| Stage | Duration |
|---|---:|
| Backend startup | 6,784.0 ms |
| Backend login request | 1,525.6 ms |
| Backend cold dashboard request | 3,150.1 ms |
| Browser dashboard request to headers | 3,150.9 ms |
| Dashboard refresh start to usable after paint | 3,242.3 ms |
| Employee-file prefetch wall time | 1,112.9 ms |
| Sum of overlapping worker durations | 6,365.3 ms |

Startup initialization is real work that older cold-request comparisons excluded. These figures are evidence for this fixture, **not** the corporate Windows bottleneck. Startup used an incomplete synthetic baseline that legitimately initialized missing auxiliary files; established production DATA may behave differently.

Overhead was measured separately on macOS/Apple M2 Pro, PowerShell 7, the same domestic Windows SMB share, 40 employees, eight readers and three fresh backend samples per mode. Startup/login precede the cold request; OS/SMB caches were not purged. The final nine samples had identical dashboard DTO hashes.

| Mode | Cold median | Change | Process CPU delta median | Endpoint working set | Process trace size / events median |
|---|---:|---:|---:|---:|---:|
| Disabled | 2,608.8 ms | baseline | 2,214.3 ms | 281.0 MiB | 0 / 0 |
| Summary | 2,759.6 ms | +5.8% | 2,840.4 ms | 351.8 MiB | 364,574 bytes / 624 |
| Detailed | 4,135.7 ms | +58.5% | 5,364.8 ms | 372.8 MiB | 11,210,492 bytes / 21,568 |

Tracing is not overhead-free. CPU deltas include diagnostic activity observed during the cold request; working set is an endpoint sample, not peak memory/retained heap. File size/event counts cover startup, login, cold, warm, remote change and shutdown together. Three samples and sequential mode order do not establish statistical confidence or predict an i5-1345U corporate Windows laptop. Initial summary instrumentation proxied too many small helpers; restricting **diagnostic** proxies to major boundaries reduced its measurement overhead without changing application algorithms.

Raw results: `output/performance-tracing-overhead*.json`; readable comparison: `output/performance-tracing-overhead.md`. Reproduce with:

```powershell
.\scripts\benchmark-performance-tracing.ps1 `
  -NetworkDataFolder '<mounted-test-DATA-folder>' `
  -EmployeeCount 40 -Iterations 3
```

This benchmark creates/removes only owned synthetic UUID subfolders and fresh local runtime copies. Do not point it at an unmounted path. It deliberately includes additional warm/remote-change requests to check correctness. The optional development browser fixture is `scripts/dev/capture-performance-browser-sample.js`; it uses an already-installed Playwright/Chromium via environment configuration and adds no SAPHIR runtime dependency.

## Tests and limits

New tests cover hierarchy, keyed anonymization, inline/default/unbound function parameters, monotonic durations, concurrent worker correlation, interval-union exclusive time, interrupted execution, valid JSONL, rotation/retention, local-only destinations, disabled mode, failure isolation, browser export/privacy/no telemetry and actual DOM/render flow. Existing HTTP/cache/authorization/atomic-lock/data-safety tests remain part of `scripts/test-all.ps1`.

Final workspace regression run: **131 selected, 131 passed, zero failures**, about 92 seconds; two Windows-only runtime tests internally skipped on macOS. Report: `output/persistent-tracing-regression-final.json`. The existing shared root JSON digest remained `2300b52148e8cdce5d6cde9f657be6978a0d5f9522117fcab2eee1d6d1bcce15`, matching the pre-existing baseline. Only synthetic benchmark fixture subfolders were created/removed. Local uncommitted DATA and the Mac-only SMB configuration were not changed by this task or included in any publication. As previously documented, a clean Git snapshot still has the pre-existing catalogue-accent fixture failure; local catalogues satisfy that separate test.

PowerShell 5.1 syntax/API compatibility is checked statically; the implementation uses .NET Framework-era threading/collections/crypto/IO APIs. PowerShell 7 and a real local browser sample were exercised here. **The new tracing runtime has not yet been executed on a corporate Windows workstation.** Windows ACL, corporate language/antivirus policy and Windows-specific performance must be verified there; no all-Windows-pass claim is made.

Known blind spots: VBS/cache-distribution/update/download/extraction before `launch-app.ps1`; PowerShell host initialization before the first script statement; OS-level CPU/network/SMB packet sampling; private domain-module calls; listener queueing before `GetContext`; browser work before AppShell (partly visible through navigation timing); asynchronous work after a request boundary; and dropped/rotated/malformed/incomplete events. Cross-origin browser fetches may not expose the trace header; the normal same-origin `localhost:8081` flow does.

No production optimization recommendation follows from this development capture. The next step is a summary/untraced comparison and one detailed capture on the actual corporate Windows laptop.
