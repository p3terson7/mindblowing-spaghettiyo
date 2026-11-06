// Isolated visual/navigation regression. Synthetic read-only API; no shared DATA.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "../../app/frontend");
const user = { username: "preview", displayName: "Aperçu", role: "superAdmin", employeeCode: null, mustChangePassword: false };
const summary = Array.from({ length: 30 }, (_, i) => ({
  projectCode: `P${i + 1}`, projectName: `Projet ${i + 1}`, sector: "Opérations", colorKey: ["blue", "coral", "mint", "teal", "amber", "violet", "green"][i % 7], markerKey: ["circle", "square", "triangle", "diamond"][i % 4],
  admins: [], backupAdmins: [], totalSeconds: 7200, totalOvertime: "02:00:00", entryCount: 5,
  approvedEntryCount: 4, departmentShare: { percent: 100 / 30 },
  statusBuckets: { approved: { count: 4, seconds: 7200 }, pending: { count: 1, seconds: 1800 } },
}));
const requests = [];
let releaseInitialBootstrap = null;
let holdInitialBootstrap = true;
const trends = Object.fromEntries([
  [1.25, 6, 8, 4, 7, 9, 5, 8, 10], [2, 3, 4, 6, 5, 7, 6, 4, 3],
  [0, 2, 6, 8, 7, 6, 3, 4, 2], [4, 5, 2, 7, 2, 6, 3, 4, 2],
  [3, 2, 4, 3, 0, 5, 6, 4, 2], [4, 2, 4, 2, 2, 3, 4, 1, 1], [3, 1, 5, 0, 4, 2, 1, 2, 1],
].map((values, index) => [`P${index + 1}`, values.map((hours, month) => ({ month: `2026-${String(month + 1).padStart(2, "0")}`, seconds: hours * 3600, overtime: hours }))]));
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  requests.push({ method: req.method, url });
  let data;
  if (url.pathname === "/auth/me") data = user;
  else if (url.pathname === "/sync/status") data = { version: 1, changeId: "preview", category: "history", resource: "preview" };
  else if (url.pathname === "/projects/bootstrap") {
    const code = url.searchParams.get("projectCode");
    data = { summary, trends, selectedProjectCode: code, selectedProject: code ? detail(code) : null };
  } else if (url.pathname.startsWith("/stats/projects/")) data = detail(url.pathname.split("/").at(-1));
  else if (url.pathname === "/bug-reports") data = { reports: [], counts: {} };
  if (data !== undefined) {
    res.setHeader("Content-Type", "application/json");
    if (url.pathname === "/projects/bootstrap" && holdInitialBootstrap) {
      holdInitialBootstrap = false;
      releaseInitialBootstrap = () => res.end(JSON.stringify(data));
    }
    else if (url.pathname === "/projects/bootstrap") setTimeout(() => res.end(JSON.stringify(data)), 100);
    else res.end(JSON.stringify(data));
    return;
  }
  const file = path.resolve(root, `.${url.pathname === "/" ? "/index.html" : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; res.end("Not found"); return; }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".png": "image/png", ".woff2": "font/woff2" })[path.extname(file)] || "text/plain");
  res.end(fs.readFileSync(file));
});
function detail(code) {
  return { ...summary.find(project => project.projectCode === code), contributors: Array.from({ length: 15 }, (_, i) => ({
    employeeCode: String(i + 1).padStart(9, "0"), employee: `Employé ${i + 1}`, approvedSeconds: 7200,
    approvedEntryCount: 4, pendingCount: 0, pendingSeconds: 0, lastActivityDate: "2026-10-14",
  })), recentEntries: [], approvedTrend: [] };
}
(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chromePath) ? { executablePath: chromePath } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.stack || error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "preview", user }));
      localStorage.setItem("activeView", "projectsView");
      localStorage.setItem("saphirAppLanguage", "fr");
      localStorage.setItem("saphirAppTheme", "dark");
    }, { origin, user });
    await page.goto(origin);
    await page.waitForSelector("#projectChartContainer .chart-placeholder-line");
    assert.equal(await page.locator(".project-insight-stage .chart-placeholder-donut").count(), 2);
    assert.equal(await page.locator("#projectChartContainer .loading-bar-chart, .project-insight-stage .loading-bar-chart").count(), 0, "Charts still use filled blob placeholders.");
    const loadingHeight = await page.locator("#projectChartContainer .chart-stage").evaluate(element => element.clientHeight);
    assert(loadingHeight >= 560, "The main chart needs more vertical space.");
    assert(await page.locator("#projectChartContainer .chart-stage").getAttribute("aria-busy") === "true");
    assert(!await page.locator(".chart-placeholder").evaluateAll(elements => elements.some(element => element.scrollWidth > element.clientWidth + 1 || element.scrollHeight > element.clientHeight + 1)), "A loading indicator overflows its chart.");
    await page.locator("#projectChartContainer").screenshot({ path: "/tmp/saphir-project-chart-loading.png" });
    await page.locator("#projectInsightsPanel").screenshot({ path: "/tmp/saphir-project-donut-loading.png" });
    await page.emulateMedia({ reducedMotion: "reduce" });
    assert.equal(await page.locator(".chart-placeholder-ring-progress").first().evaluate(element => getComputedStyle(element).animationName), "none");
    await page.emulateMedia({ reducedMotion: "no-preference" });
    releaseInitialBootstrap();
    await page.waitForSelector(".project-summary-card");
    const nav = page.locator("#projectPeriodNav");
    const dataRequests = () => requests.filter(request => request.url.pathname === "/projects/bootstrap");
    assert.equal(dataRequests().length, 1);
    assert(await nav.isVisible());
    await page.waitForSelector("#projectMultiLineChart canvas");
    await page.waitForFunction(() => document.querySelector("#projectChartContainer .chart-stage").getAttribute("aria-busy") === "false");
    const readyHeight = await page.locator("#projectChartContainer .chart-stage").evaluate(element => element.clientHeight);
    assert.equal(readyHeight, loadingHeight, "The chart jumps in height after loading.");
    assert.equal(await page.locator('.project-insight-stage[aria-busy="true"]').count(), 0);
    const summaryStyle = await page.locator("#projectAnalyticsBar").evaluate(element => {
      const style = getComputedStyle(element);
      return { background: style.backgroundColor, border: style.borderTopWidth, shadow: style.boxShadow, height: element.getBoundingClientRect().height,
        plainMetrics: Array.from(element.querySelectorAll(".project-insight-stat")).every(metric => getComputedStyle(metric).backgroundColor === "rgba(0, 0, 0, 0)" && getComputedStyle(metric).borderTopWidth === "0px") };
    });
    assert.equal(summaryStyle.background, "rgba(0, 0, 0, 0)");
    assert.equal(summaryStyle.border, "0px");
    assert.equal(summaryStyle.shadow, "none");
    assert(summaryStyle.height < 130 && summaryStyle.plainMetrics, "Project summary remains oversized or boxed in individual cards.");
    assert.equal(await page.locator("#projectInsightsSummary .project-insight-stat").count(), 5);
    assert(await page.locator("#projectAnalyticsExportButton").isVisible());
    assert(await page.locator("#projectDepartmentAnalyticsExportButton").isVisible());
    await page.locator("#projectAnalyticsBar").screenshot({ path: "/tmp/saphir-project-summary-compact.png" });
    await page.locator("#projectChartContainer").screenshot({ path: "/tmp/saphir-project-chart-readable.png" });
    const interactive = await page.evaluate(() => {
      const chart = echarts.getInstanceByDom(document.getElementById("projectMultiLineChart"));
      chart.dispatchAction({ type: "dataZoom", start: 20, end: 100 });
      chart.dispatchAction({ type: "legendUnSelect", name: "P1" });
      const option = chart.getOption();
      const result = { zoom: option.dataZoom[0].start, hidden: option.legend[0].selected.P1 === false, value: option.series[0].data[0] };
      chart.dispatchAction({ type: "legendSelect", name: "P1" });
      return result;
    });
    assert.equal(interactive.zoom, 20);
    assert(interactive.hidden);
    assert.equal(interactive.value, 1.25);
    const compact = await page.evaluate(() => {
      const nav = document.getElementById("projectPeriodNav").getBoundingClientRect();
      const presets = document.getElementById("projectQuickRangeButtons").getBoundingClientRect();
      const custom = document.getElementById("projectCustomFilterPanel").getBoundingClientRect();
      return { width: nav.width, viewWidth: document.getElementById("projectsView").clientWidth, gap: custom.left - presets.right, sameRow: Math.abs(custom.top - presets.top) < 8 };
    });
    assert(compact.width < compact.viewWidth * 0.75, "The period navigation still spans the entire view.");
    assert(compact.sameRow && compact.gap >= 0 && compact.gap <= 16, "Custom dates must sit immediately beside the other filters.");
    assert.equal(await page.locator('#projectQuickRangeButtons [aria-pressed="true"]').getAttribute("data-range"), "1M");
    await page.evaluate(() => window.scrollTo(0, 700));
    await page.waitForTimeout(150);
    async function checkSticky() {
      const bounds = await page.evaluate(() => {
        const nav = document.getElementById("projectPeriodNav").getBoundingClientRect();
        const chrome = document.querySelector(".app-sidebar").getBoundingClientRect();
        return { navTop: nav.top, chromeBottom: chrome.bottom, navWidth: nav.width, overflow: document.documentElement.scrollWidth > innerWidth + 1 };
      });
      assert(Math.abs(bounds.navTop - bounds.chromeBottom - 8) < 2, `Period navigation overlaps or leaves the sticky application nav: ${JSON.stringify(bounds)}`);
      assert(!bounds.overflow, "Period navigation creates horizontal page overflow.");
    }
    await checkSticky();
    await page.screenshot({ path: "/tmp/saphir-project-period-desktop.png" });
    const scrollBeforePeriod = await page.evaluate(() => scrollY);
    await page.locator('#projectQuickRangeButtons [data-range="6M"]').click();
    await page.waitForFunction(() => currentProjectFilter === "6M" && !document.querySelector('#projectQuickRangeButtons [data-range="6M"]').disabled);
    assert.equal(dataRequests().length, 2, "A preset change must make only one bootstrap request.");
    assert(Math.abs(await page.evaluate(() => scrollY) - scrollBeforePeriod) < 2, "Changing the global period moved the page.");
    assert.equal(await page.locator('#projectQuickRangeButtons [aria-pressed="true"]').getAttribute("data-range"), "6M");
    await page.locator('.project-open-button[data-project-code="P1"]').click();
    await page.waitForSelector("#projectWorkspace:not(.d-none) .project-workspace-metrics");
    assert(await nav.isVisible(), "Period filter disappeared inside a project.");
    await nav.locator("summary").click();
    await page.locator("#projectStartDate").fill("2026-09-01");
    await page.locator("#projectEndDate").fill("2026-09-30");
    const beforeCustom = dataRequests().length;
    await page.locator("#projectApplyCustomRangeButton").click();
    await page.waitForFunction(() => currentProjectFilter === "custom" && document.querySelector("#projectWorkspace .project-workspace-metrics"));
    assert.equal(dataRequests().length, beforeCustom + 1, "Custom dates duplicated the request.");
    const latest = dataRequests().at(-1).url.searchParams;
    assert.equal(latest.get("startDate"), "2026-09-01");
    assert.equal(latest.get("endDate"), "2026-09-30");
    assert.equal(latest.get("projectCode"), "P1");
    assert.equal(await page.locator('#projectQuickRangeButtons [aria-pressed="true"]').count(), 0);
    assert((await page.locator("#projectPeriodRangeLabel").textContent()).includes("2026"));
    assert(!(await page.locator("#projectCustomFilterPanel").getAttribute("open")));
    assert(await nav.locator("summary").evaluate(element => element === document.activeElement), "Applying dates must restore keyboard focus to the period selector.");
    await nav.locator("summary").click();
    await page.locator("#projectStartDate").fill("2026-10-20");
    await page.locator("#projectEndDate").fill("2026-10-01");
    const beforeInvalid = dataRequests().length;
    await page.locator("#projectApplyCustomRangeButton").click();
    assert.equal(dataRequests().length, beforeInvalid, "Invalid dates must not start a request.");
    await page.locator("#toastContainer .toast .btn-close").click();
    await page.waitForSelector("#toastContainer .toast.show", { state: "hidden" });
    await page.locator("#projectEndDate").press("Escape");
    assert.equal(await page.locator("#projectCustomFilterPanel").getAttribute("open"), null);
    await page.locator("#projectWorkspaceBackButton").click();
    await page.waitForSelector("#projectPortfolioWorkspace:not(.d-none)");
    assert.equal(await page.evaluate(() => currentProjectFilter), "custom", "Returning to the portfolio lost the selected dates.");
    await page.setViewportSize({ width: 375, height: 900 });
    await page.waitForTimeout(200);
    assert(!await page.locator("#projectAnalyticsBar").evaluate(element => element.scrollWidth > element.clientWidth + 1), "Compact project summary overflows on mobile.");
    const mobileMetrics = await page.locator("#projectInsightsSummary").evaluate(element => ({ columns: getComputedStyle(element).gridTemplateColumns, display: getComputedStyle(element).display, boxes: Array.from(element.children).map(child => ({ x: child.getBoundingClientRect().x, y: child.getBoundingClientRect().y })) }));
    assert(Math.abs(mobileMetrics.boxes[1].y - mobileMetrics.boxes[2].y) < 2 && mobileMetrics.boxes[1].x !== mobileMetrics.boxes[2].x, `Mobile summary must use two compact columns: ${JSON.stringify(mobileMetrics)}`);
    await page.locator("#projectAnalyticsBar").screenshot({ path: "/tmp/saphir-project-summary-mobile.png" });
    assert(await page.locator("#projectChartContainer .chart-stage").evaluate(element => element.clientHeight >= 420), "Mobile chart height is cramped.");
    await page.evaluate(() => window.scrollTo(0, 700));
    await page.waitForTimeout(100);
    await checkSticky();
    await nav.locator("summary").click();
    await checkSticky();
    const popup = await page.locator(".project-period-date-panel").boundingBox();
    assert(popup.x >= 0 && popup.x + popup.width <= 376, "Custom dates panel does not fit on mobile.");
    await page.screenshot({ path: "/tmp/saphir-project-period-mobile.png" });
    await page.locator("#projectClearCustomRangeButton").click();
    await page.waitForFunction(() => currentProjectFilter === "1M");
    await page.evaluate(() => applyAppTheme("light"));
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(350);
    await page.screenshot({ path: "/tmp/saphir-project-period-light.png" });
    await page.locator("#navBugReports").click();
    await page.waitForSelector("#bugReportsView.active");
    assert(!await nav.isVisible(), "Project period navigation remains visible in other views.");
    assert.deepEqual(errors, []);
    assert(!requests.some(request => request.method !== "GET"), "The period test mutated data.");
    assert(!requests.some(request => request.url.pathname === "/stats/budget-periods"), "Changing the global period loaded optional budget comparison.");
    console.log("Projects period browser passed: sticky desktop/mobile, one-request filters, custom dates within a project, validation, keyboard, back navigation, themes and view visibility.");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
