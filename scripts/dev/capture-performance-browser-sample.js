// Optional development fixture, using an already-installed Playwright. No
// runtime dependency is added to SAPHIR. Only synthetic UUID subfolders are
// created; real shared DATA and real accounts are never read/copied/modified.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const net = require("node:net");
const assert = require("node:assert/strict");
const playwright = require(process.env.SAPHIR_PLAYWRIGHT_MODULE || "playwright");
const repo = path.resolve(__dirname, "../..");
const share = process.argv[2];
const output = path.resolve(process.argv[3] || path.join(repo, "output/performance-browser-sample"));
if (!share || !fs.statSync(share).isDirectory()) throw new Error("Supply the mounted test share root.");
const runtime = fs.mkdtempSync(path.join(os.tmpdir(), "saphir-trace-browser-"));
const fixture = path.join(share, `saphir-trace-browser-${crypto.randomUUID()}`);
const localData = process.env.LOCALAPPDATA || (process.platform === "darwin" ? path.join(os.homedir(), "Library/Application Support") : path.join(os.homedir(), ".local/share"));
const traces = path.join(localData, "SAPHIR/diagnostics/browser-sample-" + crypto.randomUUID());
const password = "Fixture-" + crypto.randomUUID() + "!";
const controlToken = crypto.randomUUID().replaceAll("-", "");
const executable = process.env.SAPHIR_POWERSHELL || "pwsh";
let server, browser, stdout, stderr;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function main() {
  fs.mkdirSync(output, { recursive: true });
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, "127.0.0.1", resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const environment = { ...process.env, SAPHIR_TRACE_FIXTURE_PASSWORD: password, SAPHIR_PERFORMANCE_TRACE: "0", SAPHIR_PERF_TRACE: "0" };
  const setup = spawnSync(executable, ["-NoProfile", "-File", path.join(repo, "tests/lib/PerformanceTraceBrowserFixture.ps1"), "-FixtureFolder", fixture, "-RuntimeFolder", runtime, "-Port", String(port)], { env: environment, encoding: "utf8" });
  if (setup.status !== 0) throw new Error(setup.stderr || "Synthetic fixture setup failed.");
  stdout = fs.openSync(path.join(runtime, "stdout.log"), "w"); stderr = fs.openSync(path.join(runtime, "stderr.log"), "w");
  server = spawn(executable, ["-NoProfile", "-File", path.join(runtime, "app/backend/saphir-server.ps1")], { env: { ...process.env, SAPHIR_PERFORMANCE_TRACE: "1", SAPHIR_PERF_TRACE: "1", SAPHIR_TRACE_LEVEL: "detailed", SAPHIR_TRACE_DIR: traces, SAPHIR_INSTANCE_TOKEN: controlToken }, stdio: ["ignore", stdout, stderr] });
  const origin = `http://localhost:${port}`;
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    if (server.exitCode !== null) throw new Error("Synthetic backend failed before becoming ready: " + fs.readFileSync(path.join(runtime, "stderr.log"), "utf8"));
    try { const response = await fetch(origin); if (response.ok) { ready = true; break; } } catch (_) { }
    await wait(100);
  }
  if (!ready) throw new Error("Synthetic backend readiness timed out.");
  browser = await playwright.chromium.launch({ headless: true, ...(process.env.SAPHIR_CHROMIUM_EXECUTABLE ? { executablePath: process.env.SAPHIR_CHROMIUM_EXECUTABLE } : {}) });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(origin + "/?saphirTrace=detailed", { waitUntil: "domcontentloaded" });
  await page.locator("#usernameInput").fill("audit-super");
  await page.locator("#passwordInput").fill(password);
  await page.locator("#loginSubmitButton").click();
  await page.waitForFunction(() => typeof dashboardState !== "undefined" && dashboardState.bootstrap && dashboardState.bootstrap.trackedEmployees === 40, undefined, { timeout: 60000 });
  await page.waitForTimeout(300);
  const state = await page.evaluate(() => ({ count: dashboardState.bootstrap.trackedEmployees, pending: dashboardState.bootstrap.pendingApprovals, total: dashboardState.bootstrap.totalOvertime }));
  assert.equal(state.count, 40); assert.equal(state.pending, 40);
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export performance trace" }).click();
  const download = await downloadPromise;
  const browserFile = path.join(output, "SAPHIR-browser-performance.jsonl");
  await download.saveAs(browserFile);
  await fetch(origin + "/__saphir/control/shutdown", { method: "POST", headers: { "X-SAPHIR-Control-Token": controlToken } });
  for (let attempt = 0; attempt < 100 && server.exitCode === null; attempt++) await wait(100);
  if (server.exitCode === null) throw new Error("Synthetic backend did not shut down gracefully.");
  for (const file of fs.readdirSync(traces).filter(file => file.endsWith(".jsonl"))) fs.copyFileSync(path.join(traces, file), path.join(output, file));
  const analysis = spawnSync(executable, ["-NoProfile", "-File", path.join(repo, "scripts/analyze-performance-trace.ps1"), "-TracePath", output, "-OutputBase", path.join(output, "complete-report"), "-Csv"], { encoding: "utf8" });
  if (analysis.status !== 0) throw new Error(analysis.stderr || "Trace analysis failed.");
  const report = JSON.parse(fs.readFileSync(path.join(output, "complete-report.json"), "utf8"));
  assert(report.correlations.some(item => item.browserOperation.includes("dashboard/bootstrap") && item.backendRequestMs > 0));
  assert.equal(report.missingParents, 0);
  assert.equal(report.invalidOrPartialLines, 0);
  assert.equal(errors.length, 0, "Browser initialization emitted unexpected errors.");
  const raw = fs.readdirSync(output).filter(file => file.endsWith(".jsonl")).map(file => fs.readFileSync(path.join(output, file), "utf8")).join("");
  for (const secret of [password, controlToken, "audit-super", "Audit Supervisor", "Employee 1", fixture]) assert(!raw.includes(secret), "Synthetic identity/credential/path leaked into trace.");
  console.log(JSON.stringify({ output, traceFiles: report.inputFileCount, events: report.eventCount, correlations: report.correlations.length, incompleteSpans: report.incompleteSpans, maximumWorkers: Math.max(...report.parallelism.map(item => item.maximumConcurrency)), state }));
}
main().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close();
  if (server && server.exitCode === null) server.kill();
  if (stdout !== undefined) fs.closeSync(stdout); if (stderr !== undefined) fs.closeSync(stderr);
  // Exact owned fixture directories only, never a supplied share/workspace root.
  if (fs.existsSync(fixture)) fs.rmSync(fixture, { recursive: true, force: true });
  fs.rmSync(runtime, { recursive: true, force: true });
});
