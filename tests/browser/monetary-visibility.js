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
  { ...entry, entryId: "one", exactPunchIn: "17:01:12", exactPunchOut: "18:01:23", workComment: "Texte original", message: "Ancienne note", messageAuthorName: "Marie Tremblay", messageUpdatedAt: "2026-10-06T20:30:00Z", monetary: { status: "final", currency: "CAD", totalAmountCents: 70000, cashAmountCents: 70000, compensatoryLeaveValueCents: 0 } },
  { ...entry, entryId: "two", date: "2026-10-06", workSchedule: "compressed", paymentOption: "leave", monetary: { status: "final", currency: "CAD", totalAmountCents: 53450, cashAmountCents: 0, compensatoryLeaveValueCents: 53450 } },
  { ...entry, entryId: "three", date: "2026-10-07", workSchedule: "unconfirmed", canModify: false, canApprove: false, monetary: { status: "unavailable", unavailableReason: "employee-classification-missing", totalAmountCents: null } },
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
  else if (url.pathname === "/self/options") data = { projects, overtimeCodes: [{ code: "260" }], paymentOptions: [{ code: "cash" }], reasonCodes: [] };
  else if (url.pathname === "/projects") data = projects;
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
    assert((await page.locator('.employee-card[data-employee-code="000000002"]').textContent()).includes("N/A"));
    await card.locator(".employee-open-button").click();
    await page.waitForSelector("#employeeDetailContainer .self-stat-card-money");
    assert.equal(await page.locator("#employeeDetailContainer .self-stat-card-money").count(), 3);
    assert((await page.locator("#employeeDetailContainer").textContent()).includes(expected));
    const calendar = page.locator("#employeeDetailContainer .employee-calendar-grid");
    const scheduleIcon = calendar.locator('[data-entryid="two"] .work-schedule-icon');
    await scheduleIcon.waitFor();
    assert.equal(await scheduleIcon.getAttribute("title"), "Temps comprimé");
    assert.equal(await scheduleIcon.getAttribute("aria-label"), "Temps comprimé");
    assert.equal(await scheduleIcon.textContent(), "");
    assert.equal(await calendar.locator('[data-entryid="one"] :is(.work-schedule-badge, .work-schedule-icon)').count(), 0);
    assert.match(await calendar.locator('[data-entryid="three"] .work-schedule-badge.unconfirmed').textContent(), /Horaire à confirmer/);
    const assertIconInTopRow = async () => {
      assert(await scheduleIcon.evaluate(icon => {
        const row = icon.parentElement.getBoundingClientRect();
        const time = icon.parentElement.querySelector(".calendar-entry-time").getBoundingClientRect();
        const position = icon.getBoundingClientRect();
        const inset = row.right - position.right;
        return inset >= 3 && inset <= 8 && position.top >= time.top && position.top < time.bottom && position.left >= time.right - 1;
      }), "The calendar icon must leave a small inset and stay on the time row without overlapping.");
    };
    const compressedCard = calendar.locator('.calendar-entry[data-entryid="two"]');
    const inspector = page.locator("#peopleEntryInspector");
    const more = inspector.locator(".people-entry-inspector-more > summary");
    const assertCardIsSummary = async () => {
      assert.equal(await compressedCard.locator("button, .entry-notes-preview").count(), 0);
      assert(await compressedCard.evaluate(card =>
        getComputedStyle(card.querySelector(".calendar-entry-time")).color !== getComputedStyle(card.querySelector(".people-calendar-project")).color),
      "Time must have stronger contrast than the project.");
    };
    await assertIconInTopRow();
    await assertCardIsSummary();
    await compressedCard.evaluate(card => card.scrollIntoView({ block: "center", behavior: "instant" }));
    const initialScroll = await page.evaluate(() => window.scrollY);
    const countBeforeInspector = requests.length;
    await compressedCard.press("Enter");
    await inspector.waitFor();
    assert.equal(await page.evaluate(() => window.scrollY), initialScroll, "Opening a calendar entry must not jump below the calendar.");
    assert.equal(requests.slice(countBeforeInspector).filter(request => request.url !== "/sync/status").length, 0, "Entry details must use the entries already loaded.");
    assert.equal(await compressedCard.getAttribute("aria-expanded"), "true");
    const a = await compressedCard.boundingBox();
    const f = await inspector.boundingBox();
    assert(f.x >= a.x + a.width || f.x + f.width <= a.x || f.y >= a.y + a.height || f.y + f.height <= a.y,
      "At desktop width the detail panel must stay clear of the selected entry.");
    assert(Math.abs(f.y - a.y) < 2, "The panel must align to the selected entry's top edge when it fits.");
    const narrowerSide = await page.evaluate(() => getPeopleEntryInspectorPosition(
      { left: 360, right: 485, top: 210, bottom: 266 }, { width: 352, height: 220 }, 820, 900));
    assert.equal(narrowerSide.placement, "left", "A slightly narrower side panel must take precedence over a lower panel.");
    assert.equal(narrowerSide.sideWidth, 340);
    const assertMenuFits = async () => {
      const menu = inspector.locator(".people-entry-inspector-menu");
      assert(await menu.evaluate(node => {
        const bounds = node.getBoundingClientRect();
        return [...node.querySelectorAll("button")].every(button => {
          const item = button.getBoundingClientRect();
          return item.left >= bounds.left && item.right <= bounds.right &&
            item.top >= bounds.top && item.bottom <= bounds.bottom && button.scrollWidth <= button.clientWidth + 1;
        });
      }), "The edit and delete buttons must stay entirely inside their menu.");
    };
    await more.click();
    await assertMenuFits();
    const editCalendar = inspector.getByRole("button", { name: "Modifier", exact: true });
    const deleteCalendar = inspector.getByRole("button", { name: "Supprimer", exact: true });
    await editCalendar.click();
    const editor = page.locator("#updateEntryModal");
    await editor.waitFor();
    assert.equal(await editor.locator("#updateEntryId").inputValue(), "two");
    await editor.locator('.modal-footer [data-bs-dismiss="modal"]').click();
    await editor.waitFor({ state: "hidden" });
    const deleteDialogs = [];
    const dismissDelete = async dialog => {
      deleteDialogs.push(dialog.type());
      await dialog.dismiss();
    };
    page.on("dialog", dismissDelete);
    await deleteCalendar.click();
    page.off("dialog", dismissDelete);
    assert.deepEqual(deleteDialogs, ["prompt", "confirm"], "Deletion must still request a note and confirmation.");
    await page.keyboard.press("Escape");
    assert(await inspector.isVisible(), "Escape closes the actions menu first.");
    await page.keyboard.press("Escape");
    await inspector.waitFor({ state: "hidden" });
    assert(await compressedCard.evaluate(card => card === document.activeElement));

    const pending = calendar.locator('[data-entryid="pending"]');
    await pending.click();
    await inspector.getByRole("button", { name: "Rejeter" }).click();
    const rejection = page.locator("#entryRejectionModal");
    await rejection.waitFor();
    await rejection.locator(".modal-footer [data-bs-dismiss]").click();
    await rejection.waitFor({ state: "hidden" });
    let approvalWrite;
    await page.route("**/employee/approval/000000001", async route => {
      approvalWrite = route.request().postDataJSON();
      entries.find(row => row.entryId === approvalWrite.entryId).status = "approved";
      await route.fulfill({ json: { message: "Updated" } });
    });
    await inspector.getByRole("button", { name: "Approuver" }).click();
    await inspector.getByText("Approuvé", { exact: true }).waitFor();
    assert.equal(approvalWrite.entryId, "pending");
    assert.equal(await pending.getAttribute("aria-expanded"), "true", "Refreshing an approved entry must preserve selection.");
    await inspector.getByRole("button", { name: "Fermer" }).click();
    await calendar.locator('[data-entryid="three"]').click();
    await inspector.locator(".permission-badge").waitFor();
    assert.equal(await inspector.locator(".people-entry-inspector-footer").count(), 0, "Read-only entries must not expose mutation actions.");
    await inspector.getByRole("button", { name: "Fermer" }).click();
    await page.locator(".project-card-entry-toggle > summary").first().click();
    await page.waitForSelector(".people-project-entry-list .entry-monetary-value");
    assert.equal(await page.locator(".people-project-entry-list .entry-monetary-value").count(), 3);
    const noteRow = page.locator(".people-project-entry-row").filter({ has: page.locator("[data-entryid='one']") });
    const noteIcon = noteRow.getByRole("button", { name: "Lire les notes de l’entrée" });
    assert(await noteRow.evaluate(row => {
      const date = row.querySelector(".people-project-entry-date").getBoundingClientRect();
      const time = row.querySelector(".people-project-entry-time").getBoundingClientRect();
      return row.offsetHeight <= 63 && Math.abs(date.top - time.top) <= 4 && time.left - date.right < 18;
    }), "Personnel date and time must be adjacent, not in widely separated columns.");
    await noteIcon.click();
    await page.locator(".entry-notes-popover").getByText("Texte original").waitFor();
    await page.keyboard.press("Escape");
    let noteWrite;
    await page.route("**/employee/message/000000001", async route => {
      assert.equal(route.request().method(), "PUT");
      noteWrite = route.request().postDataJSON();
      await route.fulfill({ json: { message: "Updated" } });
    });
    await noteRow.locator(".people-calendar-edit").click();
    await editor.waitFor();
    assert(await editor.locator(".modal-dialog").evaluate(node => node.offsetWidth > 900));
    assert.equal(await editor.locator("#updateEmployeeCommentHistory").innerText(), "Texte original");
    assert.match(await editor.locator("#updateSupervisorNoteContext").textContent(), /Marie Tremblay · .*2026/);
    await editor.locator("#updateManagerMessage").fill("Note corrigée");
    await editor.locator("#saveUpdateBtn").click();
    await editor.waitFor({ state: "hidden" });
    assert.deepEqual(noteWrite, { entryId: "one", date: "2026-10-05", punchIn: "17:00:00", message: "Note corrigée" });
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
    await assertIconInTopRow();
    await assertCardIsSummary();
    await compressedCard.click();
    await inspector.waitFor();
    assert.equal(await inspector.getAttribute("data-placement"), "sheet");
    assert(await inspector.evaluate(panel => {
      const bounds = panel.getBoundingClientRect();
      return bounds.width > 0 && bounds.left >= 0 && bounds.right <= document.documentElement.clientWidth && bounds.bottom <= window.innerHeight;
    }), "The small-screen entry panel must fit in the viewport.");
    await more.click();
    await assertMenuFits();
    await inspector.getByRole("button", { name: "Fermer" }).click();
    const inlineEntriesToggle = page.locator(".project-card-entry-toggle").first();
    if (await inlineEntriesToggle.getAttribute("open") === null) await inlineEntriesToggle.locator("summary").click();
    await noteRow.waitFor();
    assert(await noteRow.evaluate(row => row.scrollWidth <= row.clientWidth + 2), "An inline entry overflows at phone width.");
    assert(!await page.locator("#employeeDetailContainer").evaluate(element => element.scrollWidth > element.clientWidth + 1), "Personnel money cards overflow at mobile width.");
    await page.locator("#employeeDetailContainer").screenshot({ path: "/tmp/saphir-money-mobile.png" });
    const folderPath = "C:/SAPHIR/GC179/" + "un-dossier-de-test-".repeat(12);
    let exports = 0;
    await page.route("**/employee/000000001/gc179-open?*", async route => {
      exports++;
      assert.equal(route.request().method(), "POST");
      const monthKey = new URL(route.request().url()).searchParams.get("month");
      await route.fulfill({ status: 200, json: {
        prepared: true, launched: false, monthKey, folderPath, entryCount: 4, pendingCount: 1, partCount: 1, rowCount: 4,
      } });
    });
    await page.evaluate(() => Object.defineProperty(navigator, "clipboard", {
      configurable: true, value: { writeText: () => Promise.reject(new Error("Clipboard denied")) },
    }));
    const detail = page.locator("#employeeDetailContainer");
    const receipt = detail.locator("[data-gc179-receipt]");
    const exportButton = detail.locator(".people-gc179-fdf-button");
    await exportButton.click();
    await receipt.waitFor();
    assert.match(await receipt.textContent(), /GC179 préparé.*Ouverture automatique indisponible/s);
    const pathText = receipt.locator("[data-gc179-receipt-path]");
    assert(await pathText.isHidden());
    assert(!await receipt.evaluate(element => element.scrollWidth > element.clientWidth + 1), "GC179 receipt overflowed with a long path.");
    await receipt.getByRole("button", { name: "Copier le chemin" }).click();
    await receipt.getByText("Chemin sélectionné.", { exact: false }).waitFor();
    assert.equal(await pathText.textContent(), folderPath);
    assert.equal(await page.evaluate(() => window.getSelection().toString()), folderPath, "Blocked clipboard must leave the exact path selected.");
    assert(!await receipt.evaluate(element => element.scrollWidth > element.clientWidth + 1), "The manual-copy fallback must wrap a long path.");
    await page.locator('.employee-card[data-employee-code="000000002"] .employee-open-button').click();
    await detail.locator('.people-gc179-fdf-button[data-employee-code="000000002"]').waitFor();
    assert(await receipt.isHidden(), "An export receipt must not appear for another employee.");
    await card.locator(".employee-open-button").click();
    await receipt.waitFor();
    await page.evaluate(() => resetViewState());
    assert.equal(await detail.locator('[data-gc179-receipt-path]').count(), 0, "Session reset must remove the local path.");
    assert.equal(exports, 1, "Showing, copying and recovering the saved export must not rerun it.");
    assert.deepEqual(errors, []);
    assert(!requests.some(request => request.method !== "GET"), "The monetary preview wrote data.");
    console.log("Personnel and Projects browser passed: anchored calendar details, mobile sheet, approval and edit flows, permissions, monetary visibility and GC179 receipts.");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
