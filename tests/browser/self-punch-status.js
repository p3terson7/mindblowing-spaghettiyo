// Browser regression with a synthetic API. No real employee files or writes.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require("playwright");

const root = path.resolve(__dirname, "../../app/frontend");
const user = { username: "preview", employeeCode: "000000001", displayName: "Preview", role: "employee" };
const open = {
  entryId: "test-1", date: "2026-11-24", punchIn: "17:00:00",
  exactPunchIn: "17:00:00", punchOut: null, overtime: null,
  status: "pending", entryType: "diverse", workSchedule: "compressed",
};
const closed = {
  ...open, punchOut: "17:00:00", exactPunchOut: "17:00:00",
  reviewIssues: [{ code: "invalidPunchTimes" }], hasReviewIssues: true,
};
const forgotten = {
  ...open, entryId: "forgotten-1", date: "2026-11-23",
  workSchedule: "unconfirmed",
  forgottenClockOut: true, needsClockOutReview: true, reviewIssues: [{ code: "clockOutMissing" }],
};
let entries = [];
let failBootstrap = false;
let reads = 0;
let writes = 0;
let compressedProfile = false;
const requests = [];
const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");
  requests.push(pathname);
  let data;
  if (pathname === "/auth/me") data = user;
  else if (pathname === "/sync/status") data = { version: 1, changeId: "local", category: "employee", resource: user.employeeCode };
  else if (pathname === "/self/bootstrap") {
    reads++;
    if (failBootstrap) { res.statusCode = 503; data = { error: "Unavailable" }; }
    else data = {
      entries, projects: [{ projectCode: "P1", projectName: "Migration" }], timeEntryTypes: ["overtime", "diverse"],
      paymentOptions: [{ code: "cash", label: "Cash" }], overtimeCodes: [], reasonCodes: [],
      gc179Profile: { compressedWorkWeek: compressedProfile },
    };
  }
  if (data !== undefined) {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(data));
    return;
  }
  const file = path.resolve(root, `.${pathname === "/" ? "/index.html" : pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.statusCode = 404;
    res.end("Not found");
    return;
  }
  res.setHeader("Content-Type", ({ ".html": "text/html", ".css": "text/css", ".js": "application/javascript" })[path.extname(file)] || "application/octet-stream");
  res.end(fs.readFileSync(file));
});

(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chrome = process.env.SAPHIR_CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chrome) ? { executablePath: chrome } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem("saphirAppApiUrl", origin + "/");
      localStorage.setItem("saphirAppSession", JSON.stringify({ token: "preview", user }));
      localStorage.setItem("activeView", "selfView");
      localStorage.setItem("saphirAppLanguage", "fr");
    }, { origin, user });
    const primary = page.locator("#selfPrimaryPunchButton");
    const hint = page.locator("#selfPunchRequirement");
    const modal = page.locator("#selfConfirmModal");
    const confirm = page.locator("#selfConfirmModalConfirmBtn");
    const comment = page.locator("#selfWorkCommentInput");
    const hero = page.locator("#selfHeroText");
    const statusLine = page.locator("#selfStatusMessage");
    const modalError = page.locator("#selfConfirmModalError");
    const waitForText = async (id, phrase) => page.waitForFunction(
      ({ id, phrase }) => document.getElementById(id).textContent.includes(phrase), { id, phrase }
    );
    await page.goto(origin);
    await waitForText("selfPunchRequirement", "une option de paiement");
    assert(await primary.isDisabled());
    assert.equal(reads, 1);
    assert.deepEqual(requests.filter(url => url.startsWith("/self/")), ["/self/bootstrap"]);
    assert(!requests.some(url => url.startsWith("/history") || url.includes("Chart.js")));
    const schedule = page.getByRole("switch", { name: "Horaire", exact: true });
    const switchIcon = page.locator(".self-work-schedule-thumb .self-work-schedule-calendar");
    const scheduleChanges = [];
    await page.route("**/self/work-schedule", async route => {
      assert.equal(route.request().method(), "PUT");
      compressedProfile = route.request().postDataJSON().compressedWorkWeek;
      scheduleChanges.push(compressedProfile);
      await route.fulfill({ json: { workSchedule: compressedProfile ? "compressed" : "regular", gc179Profile: { compressedWorkWeek: compressedProfile } } });
    });
    await waitForText("selfWorkScheduleState", "Régulier");
    assert(await switchIcon.isHidden());
    await schedule.press("Space");
    await waitForText("selfWorkScheduleState", "Comprimé");
    await switchIcon.waitFor();
    assert(await switchIcon.evaluate(icon => {
      const circle = icon.parentElement.getBoundingClientRect();
      const bounds = icon.getBoundingClientRect();
      return Math.abs(bounds.x + bounds.width / 2 - circle.x - circle.width / 2) <= 0.5
        && Math.abs(bounds.y + bounds.height / 2 - circle.y - circle.height / 2) <= 0.5;
    }), "The calendar should be centered on both axes inside the switch thumb.");
    await page.waitForFunction(() => !document.getElementById("selfCompressedScheduleToggle").disabled);
    assert(await schedule.isChecked());
    await page.locator("#selfProjectCodeSelect").selectOption("P1");
    assert.match(await hint.textContent(), /Choisissez une option de paiement/);
    assert.match(await page.locator("#selfSelectionSummary").textContent(), /Migration/);
    await page.locator("#selfPaymentOptionSelect").selectOption("cash");
    await primary.click();
    await modal.waitFor();
    assert.match(await confirm.textContent(), /Débuter/);
    assert.match(await page.locator("#selfConfirmModalBody").textContent(), /Migration/);
    await modal.locator("[data-bs-dismiss]").last().click();
    await modal.waitFor({ state: "hidden" });
    assert.equal(writes, 0);

    entries = [open, forgotten];
    await page.reload();
    await waitForText("selfHeroText", "Temps divers en cours");
    const liveIcon = page.locator(".calendar-live-card .work-schedule-icon");
    await liveIcon.waitFor();
    assert.equal(await liveIcon.getAttribute("title"), "Temps comprimé");
    assert.equal(await liveIcon.textContent(), "");
    assert.equal(await liveIcon.evaluate(el => getComputedStyle(el).color), await switchIcon.evaluate(el => getComputedStyle(el).color));
    await schedule.press("Space");
    await waitForText("selfWorkScheduleState", "Régulier");
    await page.waitForFunction(() => !document.getElementById("selfCompressedScheduleToggle").disabled);
    assert(await switchIcon.isHidden());
    assert(await liveIcon.isVisible(), "Changing the default must not relabel a compressed entry.");
    assert.deepEqual(scheduleChanges, [true, false]);
    assert(await primary.isDisabled());
    assert.match(await hint.textContent(), /résumé du travail/);
    assert(await page.locator("#selfMissingEndNotice").isVisible(), "An older forgotten clock-out must be visible even with a new active entry.");
    await comment.fill("Travail réalisé.");
    await primary.click();
    await modal.waitFor();
    assert.match(await confirm.textContent(), /Terminer/);

    let commitBeforeFailure = false;
    let acknowledgeNext = false;
    await page.route("**/self/punch", async route => {
      const payload = route.request().postDataJSON();
      assert.equal(payload.diverseSummary, "Travail réalisé.");
      writes++;
      if (acknowledgeNext) {
        entries = [closed, forgotten];
        await route.fulfill({ status: 200, json: { time: "17:00:00" } });
      } else {
        if (commitBeforeFailure) entries = [closed, forgotten];
        await route.abort("failed");
      }
    });
    const initialReads = reads;
    await confirm.click();
    await waitForText("selfConfirmModalConfirmBtn", "Vérifier le pointage");
    assert(await modal.isVisible());
    assert.match(await modalError.textContent(), /Impossible de confirmer/);
    assert.equal(await comment.inputValue(), "Travail réalisé.");
    assert.equal(writes, 1);
    assert.equal(reads, initialReads, "A failed POST must not start an automatic retry or load.");
    failBootstrap = true;
    await confirm.click();
    await waitForText("selfConfirmModalError", "Impossible de vérifier");
    assert(await modal.isVisible());
    assert.equal(writes, 1);
    assert.equal(reads, initialReads + 1);
    failBootstrap = false;
    await modal.locator("[data-bs-dismiss]").last().click();
    await modal.waitFor({ state: "hidden" });
    assert.match(await primary.textContent(), /Vérifier le pointage/, "Cancel must not bypass verification.");
    await primary.click();
    await confirm.click();
    await modal.waitFor({ state: "hidden" });
    assert.equal(writes, 1);
    assert.equal(reads, initialReads + 2);
    assert.equal(await comment.inputValue(), "Travail réalisé.");

    commitBeforeFailure = true;
    await primary.click();
    await confirm.click();
    await waitForText("selfConfirmModalConfirmBtn", "Vérifier le pointage");
    await confirm.click();
    await modal.waitFor({ state: "hidden" });
    assert.equal(writes, 2, "Verifying a saved punch must not write it twice.");
    assert.equal(await comment.inputValue(), "");
    assert.match(await statusLine.textContent(), /Sortie enregistrée/);
    assert.match(await hero.textContent(), /Heures à vérifier/);

    entries = [open];
    await page.reload();
    await waitForText("selfHeroText", "Temps divers en cours");
    await comment.fill("Travail réalisé.");
    acknowledgeNext = true;
    failBootstrap = true;
    await primary.click();
    await confirm.click();
    await waitForText("selfConfirmModalError", "Pointage enregistré, mais");
    assert.equal(writes, 3);
    failBootstrap = false;
    await confirm.click();
    await modal.waitFor({ state: "hidden" });
    assert.equal(writes, 3, "A failed refresh after a confirmed write must not submit a second clock-out.");

    entries = [forgotten];
    await page.reload();
    await waitForText("selfHeroText", "confirmer l’heure de fin");
    assert(await page.locator("#selfMissingEndNotice").isVisible());
    const rejected = { ...closed, entryId: "rejected-old", date: "2026-10-18", status: "rejected", message: "<img src=x> Note du rejet", messageAuthorName: "Superviseure", diverseSummary: "Travail réalisé." };
    entries = [rejected, open, forgotten];
    await page.reload();
    const reason = page.locator("#selfRejectionDetails");
    await waitForText("selfHeroText", "Temps divers en cours");
    await reason.locator("summary").click();
    assert.match(await reason.locator("#selfRejectionAuthor").textContent(), /Superviseure/);
    assert.equal(await reason.locator("#selfRejectionNote").textContent(), "<img src=x> Note du rejet");
    assert.equal(await reason.locator("img").count(), 0);
    const beforeJump = reads;
    await reason.getByRole("button", { name: "Voir l’entrée" }).click();
    assert.equal(await page.locator(".employee-month-chip.is-active").getAttribute("data-self-month-key"), "2026-10");
    assert(await page.locator("[data-self-follow-up-target]").evaluate(node => node === document.activeElement));
    assert.equal(reads, beforeJump, "Opening an older rejected entry must not fetch again.");
    entries = [open, forgotten];
    await page.evaluate(() => refreshSelfView());
    assert(await reason.isHidden(), "A resolved or removed rejection must no longer be shown.");
    const month = await page.evaluate(() => toCalendarMonthKey(new Date()));
    entries = [
      { ...closed, entryId: "with-original-comment", date: month + "-01", status: "approved", overtime: "01:30:00", entryType: "overtime", workSchedule: "regular", workComment: "Texte d’origine." },
      { ...closed, date: month + "-02", status: "pending", overtime: "00:30:00", entryType: "overtime" },
      { ...closed, date: month + "-03", status: "rejected", overtime: "05:00:00", entryType: "overtime" },
      { ...closed, date: month + "-04", status: "approved", overtime: "03:00:00", entryType: "diverse" },
      open, forgotten,
    ];
    await page.reload();
    await waitForText("selfPendingApprovals", "1");
    assert.match(await page.locator("#selfTotalOvertime").textContent(), /02h\s*00/);
    assert.equal(await page.locator(".calendar-entry-main [title='Horaire régulier']").count(), 0);
    assert.equal(await page.locator(".calendar-entry .work-schedule-icon[title='Temps comprimé']").count(), 4);
    const noteTrigger = page.locator('[data-self-comment-entry*="with-original-comment"]');
    const commentPop = page.locator(".entry-notes-popover");
    await noteTrigger.click();
    await commentPop.getByRole("button", { name: "Ajouter un complément" }).click();
    const supplementEditor = page.locator("#selfEntryCommentModal");
    await supplementEditor.waitFor();
    assert.match(await supplementEditor.locator("#selfEntryCommentHistory").textContent(), /Texte d’origine/);
    const supplementInput = supplementEditor.locator("#selfEntryCommentText");
    await supplementInput.fill("Suivi ajouté.");
    const sentSupplements = [];
    await page.route("**/self/entries/comment", async route => {
      const payload = route.request().postDataJSON();
      sentSupplements.push(payload);
      if (sentSupplements.length === 1) return route.abort("failed");
      const additions = [{ id: payload.commentId, text: payload.text, createdAtUtc: "2026-11-24T20:02:00Z" }];
      entries.find(entry => entry.entryId === payload.entryId).employeeCommentAdditions = additions;
      await route.fulfill({ json: { employeeCommentAdditions: additions, warnings: [] } });
    });
    const readsBeforeSupplement = reads;
    await supplementEditor.locator("#saveSelfEntryComment").click();
    await waitForText("selfEntryCommentError", "Impossible d’ajouter");
    assert.equal(await supplementInput.inputValue(), "Suivi ajouté.");
    await supplementEditor.locator("#saveSelfEntryComment").click();
    await supplementEditor.waitFor({ state: "hidden" });
    assert.deepEqual(sentSupplements[1], sentSupplements[0], "Retry must reuse the same submission ID.");
    assert.equal(reads, readsBeforeSupplement, "Adding a comment should not reload the whole view.");
    await noteTrigger.click();
    assert.match(await commentPop.textContent(), /Texte d’origine.*2026.*Suivi ajouté/s);
    await page.keyboard.press("Escape");
    failBootstrap = true;
    await page.reload();
    const loadError = page.locator("#selfLoadError");
    await loadError.waitFor();
    assert.equal(await page.locator("#selfEntriesContainer .loading-shell").count(), 0);
    assert(await primary.isDisabled());
    const beforeRetry = reads;
    failBootstrap = false;
    await loadError.getByRole("button", { name: "Réessayer" }).click();
    await loadError.waitFor({ state: "hidden" });
    await page.waitForSelector("#selfEntriesContainer .employee-calendar-header");
    assert.equal(reads, beforeRetry + 1);
    failBootstrap = true;
    await page.evaluate(() => refreshSelfView());
    assert(await page.locator("#selfEntriesContainer .employee-calendar-header").isVisible(), "A failed refresh should preserve the last good calendar.");
    assert.match(await loadError.textContent(), /dernières données chargées/);

    const exportButton = page.locator(".self-gc179-fdf-button");
    const exportMonth = await exportButton.getAttribute("data-self-gc179-month");
    assert.match(await exportButton.textContent(), /Exporter GC179 · /);
    assert(await page.evaluate(() => document.getElementById("selfTimelinePanel").getBoundingClientRect().top <
      document.querySelector(".self-stats-panel").getBoundingClientRect().top));
    const folderPath = "C:/SAPHIR/GC179 & essai";
    let exportCalls = 0;
    let exportMode = "opened";
    await page.route("**/self/gc179-open?*", async route => {
      exportCalls++;
      assert.equal(route.request().method(), "POST");
      assert.equal(new URL(route.request().url()).searchParams.get("month"), exportMonth);
      if (exportMode === "rejected") {
        await route.fulfill({ status: 400, json: { error: "L’horaire est à confirmer." } });
      } else if (exportMode === "unknown") {
        await route.abort("failed");
      } else {
        const blank = exportMode === "blank";
        await route.fulfill({ status: 200, json: {
          prepared: true, launched: true, monthKey: exportMonth, folderPath,
          entryCount: blank ? 0 : 2, rowCount: blank ? 0 : 3, pendingCount: blank ? 0 : 1, partCount: blank ? 1 : 2,
        } });
      }
    });
    const callsBeforeExport = reads;
    await exportButton.click();
    const receipt = page.locator("#selfEntriesContainer [data-gc179-receipt]");
    await receipt.waitFor();
    assert.match(await receipt.textContent(), /GC179 préparé.*2 entrées incluses.*3 lignes.*2 formulaires/s);
    assert.match(await receipt.textContent(), /1 en attente d’approbation/);
    assert.match(await receipt.textContent(), /Ouverture demandée/);
    assert.doesNotMatch(await receipt.textContent(), /lancé dans Acrobat/i);
    assert.equal(await receipt.locator("input").count(), 0, "The compact receipt must not use an input for the path.");
    assert(!((await receipt.textContent()).includes(folderPath)));
    assert.doesNotMatch(await receipt.textContent(), /Si rien ne s’ouvre|transmis à la paie/);
    await page.evaluate(() => Object.defineProperty(navigator, "clipboard", {
      configurable: true, value: { writeText: value => { window.copiedGc179Path = value; return Promise.resolve(); } },
    }));
    await receipt.getByRole("button", { name: "Copier le chemin" }).click();
    assert.equal(await page.evaluate(() => window.copiedGc179Path), folderPath);
    await page.locator("[data-self-month-key]:not(.is-active)").first().click();
    assert(await receipt.isHidden(), "The receipt must not follow another month.");
    await page.locator(`[data-self-month-key="${exportMonth}"]`).click();
    await receipt.waitFor();
    await receipt.getByRole("button", { name: "Fermer" }).click();
    assert(await receipt.isHidden());

    exportMode = "blank";
    await exportButton.click();
    await receipt.getByText("Formulaire vierge", { exact: false }).waitFor();
    assert(!/en attente/.test(await receipt.textContent()));
    exportMode = "rejected";
    await exportButton.click();
    await receipt.getByText("L’horaire est à confirmer.").waitFor();
    assert.equal(await receipt.locator("input").count(), 0);
    exportMode = "unknown";
    await exportButton.click();
    await receipt.getByText("Impossible de confirmer la préparation", { exact: false }).waitFor();
    assert.equal(exportCalls, 4, "Each export must require only the existing POST, with no automatic retry.");
    assert.equal(reads, callsBeforeExport, "The receipt must not reload the employee calendar.");
    assert(!requests.includes("/history"));
    assert.deepEqual(errors, []);
    console.log("Self browser passed: lazy loading, punch recovery, dated comment additions with safe retries and GC179 receipts.");
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
