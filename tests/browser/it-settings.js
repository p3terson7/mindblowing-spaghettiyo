// Isolated synthetic API: all writes stay in memory, never shared DATA.
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "../../app/frontend");
const defaults = JSON.parse(fs.readFileSync(path.resolve(root, "../backend/defaults/compensation-grid.v1.json"), "utf8"));
const user = { username: "preview", displayName: "Test", role: "superAdmin", employeeCode: null, mustChangePassword: false };
const custom = { ...defaults.bands.find(band => band.group === "IT"), annualSalaryCents: 9990000 };
let bands = [...defaults.bands.filter(band => band.group !== "IT"), custom];
let puts = 0;
let entryPayload = null;
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  let data;
  if (url.pathname === "/auth/me") data = user;
  else if (url.pathname === "/sync/status") data = { version: 1, changeId: "preview", category: "history" };
  else if (url.pathname === "/employees/bootstrap") data = { employees: [], projects: [] };
  else if (url.pathname === "/employee/000000001" && req.method === "PUT") {
    let body = ""; for await (const chunk of req) body += chunk;
    entryPayload = JSON.parse(body); data = { message: "Entry saved." };
  }
  else if (url.pathname === "/compensation-grid") {
    if (req.method === "PUT") {
      let body = ""; for await (const chunk of req) body += chunk;
      bands = JSON.parse(body).bands; puts++;
    }
    data = { schemaVersion: 1, currency: "CAD", bands, suggestedBands: defaults.bands.filter(band => band.group === "IT") };
  }
  if (data !== undefined) { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(data)); return; }
  const file = path.resolve(root, `.${url.pathname === "/" ? "/index.html" : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; res.end("Not found"); return; }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".woff2": "font/woff2" })[path.extname(file)] || "application/octet-stream");
  res.end(fs.readFileSync(file));
});
(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "preview", user }));
      localStorage.setItem("activeView", "employeesView");
      localStorage.setItem("saphirAppLanguage", "fr");
    }, { origin, user });
    await page.goto(origin);
    await page.waitForFunction(() => typeof loadCompensationGrid === "function" && getCurrentUser());
    await page.evaluate(async () => {
      await loadCompensationGrid();
      document.getElementById("compensationGridSettingsSection").classList.remove("d-none");
      bootstrap.Modal.getOrCreateInstance(document.getElementById("selfSettingsModal")).show();
    });
    await page.locator("#compensationGridAddIT02Button").click();
    assert.equal(await page.locator("#compensationGridSettingsRows tr[data-compensation-band-id]").count(), 18);
    const values = await page.locator("#compensationGridSettingsRows tr[data-compensation-band-id]").evaluateAll(rows => rows.filter(row => row.querySelector(".compensation-grid-group-input").value === "IT").map(row => row.querySelector(".compensation-grid-salary-input").value));
    assert.equal(values.length, 8);
    assert(values[0].replace(/\D/g, "").startsWith("99900"), "Custom salary was replaced.");
    assert.equal(puts, 0, "Preset added shared writes before Save.");
    await page.locator("#compensationGridAddIT02Button").click();
    assert.equal(await page.locator("#compensationGridSettingsRows tr[data-compensation-band-id]").count(), 18);
    await page.locator("#compensationGridSaveButton").click();
    await page.waitForFunction(() => !document.getElementById("compensationGridSaveButton").disabled);
    assert.equal(puts, 1);
    assert.equal(bands.find(band => band.group === "IT" && band.level === "01").annualSalaryCents, 9990000);
    assert.equal(bands.filter(band => band.group === "IT").length, 8);
    // The holiday answer is editable without changing dates/times, and a
    // false answer must survive reopening instead of becoming "unknown".
    await page.evaluate(() => bootstrap.Modal.getInstance(document.getElementById("selfSettingsModal")).hide());
    if (!await page.evaluate(() => typeof openUpdateModal === "function")) {
      await page.addScriptTag({ url: origin + "/scripts/Views/DashboardView.js" });
    }
    await page.evaluate(async () => {
      populateEntryLookups = async (project, overtime, projectValue, overtimeValue, payment, reason, paymentValue, reasonValue) => {
        for (const [id, value] of [[project, projectValue], [overtime, overtimeValue], [payment, paymentValue], [reason, reasonValue]]) {
          document.getElementById(id).innerHTML = `<option value="${value}">${value}</option>`;
        }
      };
      refreshAfterEntryMutation = async () => {};
      const button = document.createElement("button");
      for (const [name, value] of Object.entries({ "employee-code": "000000001", date: "2026-11-05", punchin: "17:00:00", punchout: "18:00:00", projectcode: "P1", overtimecode: "263", reasoncode: "D", paymentoption: "cash", entrytype: "overtime", workschedule: "compressed", entryid: "it-holiday", status: "approved" })) button.setAttribute("data-" + name, value);
      document.body.append(button);
      window.holidayTestButton = button;
      await openUpdateModal(button);
    });
    await page.locator("#updateITHolidaySchedule").selectOption("false");
    await page.locator("#updateManagerMessage").fill("Horaire du férié confirmé.");
    await page.locator("#saveUpdateBtn").click();
    await page.waitForFunction(() => !document.getElementById("updateEntryModal").classList.contains("show"));
    assert.equal(entryPayload.holidayNotScheduledWorkday, false);
    await page.evaluate(async () => {
      window.holidayTestButton.setAttribute("data-holidaynotscheduled", "false");
      await openUpdateModal(window.holidayTestButton);
    });
    assert.equal(await page.locator("#updateITHolidaySchedule").inputValue(), "false");
    assert.deepEqual(errors, []);
    console.log("IT settings browser passed: eight editable steps, custom values preserved, repeated-add safety, explicit save, holiday-only edit and false answer preserved on reopen.");
  } finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
