// Optional visual smoke test. Uses an isolated browser and a read-only mock
// API; it never signs into the real app or writes repository DATA.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "../../app/frontend");
const user = { username: "beta-preview", displayName: "Bêta ECharts", role: "superAdmin", employeeCode: null, mustChangePassword: false };
const budget = { cycleLabel: "2026", periods: Array.from({ length: 12 }, (_, index) => {
  const projects = ["ALPHA", "BETA", "GAMMA"].map((code, projectIndex) => {
    const amount = (index + 2) * (projectIndex + 1) * 18000;
    return { projectCode: code, projectName: ["Alpha programme", "Beta infrastructure", "Gamma soutien"][projectIndex], totalSeconds: (index + 2) * (projectIndex + 1) * 3600, approvedEntryCount: 4, monetary: { currency: "CAD", totalAmountCents: amount, cashAmountCents: amount * 0.75, compensatoryLeaveValueCents: amount * 0.25, calculatedEntryCount: 4, unavailableEntryCount: 0, approvedEntryCount: 4 } };
  });
  return { id: `P${index + 1}`, configured: true, startDate: `2026-${String(index + 1).padStart(2, "0")}-01`, endDate: `2026-${String(index + 1).padStart(2, "0")}-${new Date(2026, index + 1, 0).getDate()}`, approvedSeconds: projects.reduce((sum, project) => sum + project.totalSeconds, 0), approvedEntryCount: 12, projectsWithOvertimeCount: 3, monetary: { currency: "CAD", totalAmountCents: projects.reduce((sum, project) => sum + project.monetary.totalAmountCents, 0), cashAmountCents: projects.reduce((sum, project) => sum + project.monetary.cashAmountCents, 0), compensatoryLeaveValueCents: projects.reduce((sum, project) => sum + project.monetary.compensatoryLeaveValueCents, 0), calculatedEntryCount: 12, unavailableEntryCount: 0, approvedEntryCount: 12 }, projects };
}) };
const summary = budget.periods[0].projects.map(project => ({ ...project, admins: [], backupAdmins: [], archived: false, totalOvertime: "02:00:00", basis: { id: "approvedClosedOvertime" }, departmentShare: { percent: 33.3 } }));
const requests = [];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  requests.push({ method: req.method, url: url.pathname });
  let data;
  if (url.pathname === "/auth/me") data = user;
  else if (url.pathname === "/sync/status") data = { version: 1, changeId: "beta", category: "history", resource: "preview" };
  else if (url.pathname === "/stats/budget-periods") data = budget;
  else if (url.pathname === "/projects/bootstrap") data = { summary, trends: {}, selectedProjectCode: null };
  else if (url.pathname.startsWith("/stats/projects/")) data = { ...summary[0], projectCode: url.pathname.split("/").at(-1), period: { startDate: url.searchParams.get("startDate"), endDate: url.searchParams.get("endDate") }, contributors: [], recentEntries: [], approvedTrend: [], statusBuckets: { approved: { count: 4, seconds: 7200 }, pending: { count: 0, seconds: 0 } } };
  if (data !== undefined) { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(data)); return; }
  const file = path.resolve(root, `.${url.pathname === "/" ? "/index.html" : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; res.end("Not found"); return; }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".png": "image/png", ".woff2": "font/woff2" })[path.extname(file)] || "text/plain");
  res.end(fs.readFileSync(file));
});

(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chromePath = process.env.BETA_CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chromePath) ? { executablePath: chromePath } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "test", user }));
      localStorage.setItem("activeView", "projectsView");
      localStorage.setItem("saphirAppLanguage", "fr");
      localStorage.setItem("saphirAppTheme", "dark");
    }, { origin, user });
    await page.goto(origin);
    await page.waitForSelector("#projectsView.active");
    await page.waitForFunction(() => typeof refreshProjectsView === "function");
    await page.waitForTimeout(400);
    assert(!requests.some(request => request.url === "/stats/budget-periods"), "The collapsed comparison loaded all twelve periods before the workspace.");
    assert(!requests.some(request => request.url.includes("echarts.min.js")), "ECharts loaded while comparison was closed.");
    await page.locator(".project-budget-comparison-disclosure > summary").click();
    await page.waitForSelector("#budgetBetaAnnualChart canvas");
    assert.equal(requests.filter(request => request.url === "/stats/budget-periods").length, 1);
    await page.locator(".project-budget-comparison-disclosure > summary").click();
    await page.locator(".project-budget-comparison-disclosure > summary").click();
    await page.waitForSelector("#budgetBetaAnnualChart canvas");
    assert.equal(requests.filter(request => request.url === "/stats/budget-periods").length, 1, "Reopening an unchanged comparison refetched all periods.");
    await page.locator("[data-beta-metric]").selectOption("money");
    await page.waitForSelector("#budgetBetaAnnualChart canvas");
    const chartInfo = await page.evaluate(() => {
      const chart = echarts.getInstanceByDom(document.getElementById("budgetBetaAnnualChart"));
      chart.dispatchAction({ type: "dataZoom", start: 15, end: 70 });
      chart.dispatchAction({ type: "legendUnSelect", name: "Argent" });
      const cashHidden = chart.getOption().legend[0].selected.Argent === false;
      chart.dispatchAction({ type: "legendSelect", name: "Argent" });
      return { series: chart.getOption().series.length, zoom: chart.getOption().dataZoom[0].start, cashHidden };
    });
    assert.equal(chartInfo.series, 2);
    assert.equal(chartInfo.zoom, 15);
    assert(chartInfo.cashHidden, "The native legend must toggle series visibility.");
    await page.locator("[data-beta-period]").selectOption("P3");
    assert((await page.locator("#budgetBetaDrilldown h3").textContent()).includes("P3"));
    await page.waitForTimeout(350);
    await page.locator("#projectBudgetBeta").screenshot({ path: "/tmp/saphir-echarts-beta-annual.png" });
    await page.locator('[data-beta-tab="comparison"]').click();
    await page.locator("[data-beta-a]").selectOption("P1");
    await page.locator("[data-beta-b]").selectOption("P12");
    await page.locator("[data-beta-search]").fill("Alpha");
    const comparison = await page.evaluate(() => echarts.getInstanceByDom(document.getElementById("budgetBetaComparisonChart")).getOption().yAxis[0].data);
    assert.deepEqual(comparison, ["ALPHA"]);
    await page.locator("[data-beta-search]").fill("");
    await page.waitForTimeout(350);
    await page.locator("#projectBudgetBeta").screenshot({ path: "/tmp/saphir-echarts-beta-comparison.png" });
    await page.locator("[data-beta-demo]").check();
    assert((await page.locator(".budget-beta-notice").textContent()).includes("Données fictives"));
    await page.locator('[data-budget-view="classic"]').click();
    assert(await page.locator("#projectBudgetClassic").isVisible());
    await page.locator('[data-budget-view="beta"]').click();
    await page.waitForSelector("#budgetBetaComparisonChart canvas");
    await page.evaluate(() => applyAppTheme("light"));
    await page.waitForSelector("#budgetBetaComparisonChart canvas");
    await page.waitForTimeout(300);
    await page.locator("#projectBudgetBeta").screenshot({ path: "/tmp/saphir-echarts-beta-light.png" });
    await page.evaluate(() => applyAppTheme("dark"));
    await page.setViewportSize({ width: 430, height: 900 });
    await page.waitForTimeout(300);
    assert(!await page.locator("#projectBudgetBeta").evaluate(element => element.scrollWidth > element.clientWidth + 1), "Beta container overflowed at mobile width.");
    await page.locator("#projectBudgetBeta").screenshot({ path: "/tmp/saphir-echarts-beta-mobile.png" });
    assert.deepEqual(errors, []);
    assert(!requests.some(request => request.method !== "GET"), "The beta made a data mutation request.");
    console.log("Budget beta browser smoke passed: local lazy loading, money stacks, zoom, legend, drilldown, A/B, search, demo, classic fallback, light/dark themes and mobile layout.");
    console.log("Screenshots: /tmp/saphir-echarts-beta-{annual,comparison,mobile}.png");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
