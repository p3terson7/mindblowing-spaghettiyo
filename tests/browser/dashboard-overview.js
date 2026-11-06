// Synthetic read-only UI regression: dashboard activity removed, Review history retained.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "../../app/frontend");
const user = { username: "preview", displayName: "Aperçu", role: "superAdmin", employeeCode: null, mustChangePassword: false };
const requests = [];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  requests.push({ method: req.method, path: url.pathname });
  let data;
  if (url.pathname === "/auth/me") data = user;
  else if (url.pathname === "/sync/status") data = { version: 1, changeId: "preview", category: "history" };
  else if (url.pathname === "/dashboard/bootstrap") data = { employees: [], projects: [], totalOvertime: "00:00:00", pendingApprovals: 0, activeEmployees: 0, trackedEmployees: 0, pendingQueue: [], activeSessions: [], recentHistory: [{ message: "Must not render" }], selectedEmployeeEntries: [] };
  else if (url.pathname === "/review/bootstrap") data = { approvals: [], projects: [], employees: [], tab: "pending", page: 1, pageSize: 25, total: 0, totalPages: 1, counts: {}, actionableCount: 0 };
  else if (url.pathname === "/history") data = { items: [{ timestamp: "2026-11-01 10:00:00", action: "Add", message: "Historique conservé" }], page: 1, totalPages: 1, total: 1, counts: { all: 1, add: 1 } };
  if (data !== undefined) { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(data)); return; }
  const file = path.resolve(root, `.${url.pathname === "/" ? "/index.html" : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; res.end("Not found"); return; }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".png": "image/png", ".woff2": "font/woff2" })[path.extname(file)] || "text/plain");
  res.end(fs.readFileSync(file));
});
(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chromePath) ? { executablePath: chromePath } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "preview", user }));
      localStorage.setItem("activeView", "dashboardView");
      localStorage.setItem("saphirAppLanguage", "fr");
    }, { origin, user });
    await page.goto(origin);
    await page.waitForFunction(() => typeof dashboardState !== "undefined" && dashboardState.bootstrap !== null);
    assert.equal(await page.locator("#dashboardRecentActivity, .dashboard-activity-rail").count(), 0);
    assert(!requests.some(request => request.path === "/history"));
    const widths = await page.evaluate(() => [document.querySelector(".dashboard-layout").clientWidth, document.querySelector(".dashboard-main-stack").clientWidth]);
    assert(Math.abs(widths[0] - widths[1]) < 2, "The removed history rail left an empty column.");
    assert(await page.locator("#dashboardApprovalQueue").isVisible());
    assert(await page.locator("#dashboardActiveList").isVisible());
    await page.setViewportSize({ width: 375, height: 900 });
    assert(!await page.locator("#dashboardView").evaluate(element => element.scrollWidth > element.clientWidth + 1));
    await page.locator("#navAdmin").click();
    await page.waitForSelector("#adminView.active");
    await page.locator("#loadHistoryBtn").click();
    await page.waitForFunction(() => document.getElementById("historyWorkspace").textContent.includes("Historique conservé"));
    assert.equal(requests.filter(request => request.path === "/history").length, 1);
    assert.deepEqual(errors, []);
    assert(requests.every(request => request.method === "GET"));
    console.log("Dashboard browser passed: no activity rail or history request, no empty column, responsive queues and Review history still available on demand.");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
