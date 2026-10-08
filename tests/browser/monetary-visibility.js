// Optional visual regression using synthetic data and an isolated browser.
// No login to the deployed app, no writes to repository DATA.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "../../app/frontend");
const user = { username: "money-preview", displayName: "Aperçu", role: "superAdmin", employeeCode: null, mustChangePassword: false };
const money = { currency: "CAD", approvedEntryCount: 3, calculatedEntryCount: 2, unavailableEntryCount: 1, totalAmountCents: 123450, cashAmountCents: 70000, compensatoryLeaveValueCents: 53450, unavailableReasons: { "employee-classification-missing": 1 } };
const missingMoney = { ...money, calculatedEntryCount: 0, unavailableEntryCount: 3, totalAmountCents: 0, cashAmountCents: 0, compensatoryLeaveValueCents: 0, unavailableReasons: { "work-schedule-unconfirmed": 3 } };
const entry = { entryType: "overtime", date: "2026-10-05", punchIn: "17:00:00", punchOut: "18:00:00", overtime: "01:00:00", status: "approved", projectCode: "ALPHA", overtimeCode: "260", workSchedule: "regular", canModify: true, canApprove: true, paymentOption: "cash" };
const entries = [
  { ...entry, entryId: "one", monetary: { status: "final", currency: "CAD", totalAmountCents: 70000, cashAmountCents: 70000, compensatoryLeaveValueCents: 0 } },
  { ...entry, entryId: "two", date: "2026-10-06", paymentOption: "leave", monetary: { status: "final", currency: "CAD", totalAmountCents: 53450, cashAmountCents: 0, compensatoryLeaveValueCents: 53450 } },
  { ...entry, entryId: "three", date: "2026-10-07", monetary: { status: "unavailable", unavailableReason: "employee-classification-missing", totalAmountCents: null } },
  { ...entry, entryId: "pending", status: "pending" },
];
const projects = [
  { projectCode: "ALPHA", projectName: "Modernisation", colorKey: "mint", admins: [], backupAdmins: [], archived: false, totalSeconds: 10800, totalOvertime: "03:00:00", approvedEntryCount: 3, monetary: money },
  { projectCode: "BETA", projectName: "Infrastructure", colorKey: "blue", admins: [], backupAdmins: [], archived: false, totalSeconds: 10800, totalOvertime: "03:00:00", approvedEntryCount: 3, monetary: missingMoney },
];
const employees = [
  { code: "000000001", name: "Camille Tremblay", role: "employee", entryCount: 4, totalOvertimeSeconds: 14400, approvedCount: 3, pendingCount: 1, monetary: money, projectCodes: ["ALPHA"], projectStats: [{ projectCode: "ALPHA", entryCount: 4, totalOvertimeSeconds: 14400, monetary: money }], gc179Profile: { group: "CR", subGroup: "04", level: "01" } },
  { code: "000000002", name: "Alexandre Roy", role: "employee", entryCount: 3, totalOvertimeSeconds: 10800, approvedCount: 3, monetary: missingMoney, projectCodes: ["BETA"], projectStats: [{ projectCode: "BETA", entryCount: 3, totalOvertimeSeconds: 10800, monetary: missingMoney }] },
];
const requests = [];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  requests.push({ method: req.method, url: url.pathname });
  let data;
  if (url.pathname === "/auth/me") data = user;
  else if (url.pathname === "/sync/status") data = { version: 1, changeId: "money-preview", category: "history", resource: "preview" };
  else if (url.pathname === "/employees/bootstrap") data = { employees, projects, lookups: { projects, overtimeCodes: [], paymentOptions: [], reasonCodes: [] } };
  else if (url.pathname.startsWith("/employee/")) data = entries;
  else if (url.pathname === "/projects/bootstrap") data = { summary: projects, trends: {}, selectedProjectCode: null };
  else if (url.pathname.startsWith("/stats/projects/")) data = { ...projects[0], period: { startDate: "2026-10-01", endDate: "2026-10-31" }, contributors: [{ employeeCode: "000000001", employee: "Camille Tremblay", monetary: money, totalSeconds: 10800, approvedEntryCount: 3 }], recentEntries: entries, approvedTrend: [], statusBuckets: { approved: { count: 3, seconds: 10800 }, pending: { count: 1, seconds: 3600 } } };
  if (data !== undefined) { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(data)); return; }
  const file = path.resolve(root, `.${url.pathname === "/" ? "/index.html" : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; res.end("Not found"); return; }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".woff2": "font/woff2" })[path.extname(file)] || "text/plain");
  res.end(fs.readFileSync(file));
});

(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chromePath = process.env.SAPHIR_CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chromePath) ? { executablePath: chromePath } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "test", user }));
      localStorage.setItem("activeView", "employeesView");
      localStorage.setItem("saphirAppLanguage", "fr");
      localStorage.setItem("saphirAppTheme", "dark");
    }, { origin, user });
    await page.goto(origin);
    await page.waitForSelector("#employeesDirectoryContainer .monetary-summary");
    const card = page.locator('.employee-card[data-employee-code="000000001"]');
    const expected = await page.evaluate(() => formatCurrencyCents(123450));
    assert((await card.textContent()).includes(expected));
    assert((await card.textContent()).includes("Partiel"));
    assert((await page.locator('.employee-card[data-employee-code="000000002"]').textContent()).includes("À compléter"));
    await card.locator(".employee-open-button").click();
    await page.waitForSelector("#employeeDetailContainer .self-stat-card-money");
    assert.equal(await page.locator("#employeeDetailContainer .self-stat-card-money").count(), 3);
    assert((await page.locator("#employeeDetailContainer").textContent()).includes(expected));
    await page.locator(".project-card-entry-toggle > summary").first().click();
    await page.waitForSelector(".people-project-entry-list .entry-monetary-value");
    assert.equal(await page.locator(".people-project-entry-list .entry-monetary-value").count(), 3);
    await page.locator("#employeeDetailContainer").screenshot({ path: "/tmp/saphir-money-personnel.png" });
    await page.locator("#navProjects").click();
    await page.waitForSelector("#projectsSummaryContainer .monetary-summary");
    assert(!requests.some(request => request.url === "/stats/budget-periods"), "Showing project amounts loaded the hidden annual comparison.");
    assert((await page.locator("#projectInsightsSummary").textContent()).includes(expected));
    assert((await page.locator('.project-summary-card[data-project-code="ALPHA"]').textContent()).includes(expected));
    await page.locator('.project-open-button[data-project-code="ALPHA"]').click();
    await page.waitForSelector(".project-workspace-metric-money");
    assert((await page.locator(".project-workspace-metric-money").textContent()).includes(expected));
    await page.locator("#projectDetailContainer").screenshot({ path: "/tmp/saphir-money-project.png" });
    await page.evaluate(() => applyAppTheme("light"));
    await page.setViewportSize({ width: 430, height: 900 });
    await page.locator("#navEmployees").click();
    await page.waitForSelector("#employeeDetailContainer .self-stat-card-money");
    assert(!await page.locator("#employeeDetailContainer").evaluate(element => element.scrollWidth > element.clientWidth + 1), "Personnel money cards overflow at mobile width.");
    await page.locator("#employeeDetailContainer").screenshot({ path: "/tmp/saphir-money-mobile.png" });
    assert.deepEqual(errors, []);
    assert(!requests.some(request => request.method !== "GET"), "The monetary preview wrote data.");
    console.log("Money browser smoke passed: Personnel cards/month/details/entry rows, project cards/portfolio/details, missing and partial values, mobile and light/dark.");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
