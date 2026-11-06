let allApprovalEntries = [];
let approvalScopedProjects = [];

function buildApprovalEmployeeOptions(entries) {
  const currentValue = document.getElementById("reviewEmployeeFilter")?.value || "";
  const employeeMap = {};
  (entries || []).forEach(entry => {
    if (entry && entry.employeeCode) {
      employeeMap[String(entry.employeeCode)] = String(entry.employeeName || entry.employeeCode);
    }
  });

  const options = [`<option value="">${escapeHtml(t("filters.allEmployees"))}</option>`]
    .concat(Object.keys(employeeMap).sort((left, right) => employeeMap[left].localeCompare(employeeMap[right])).map(employeeCode => {
      const selected = currentValue === employeeCode ? " selected" : "";
      return `<option value="${escapeHtml(employeeCode)}"${selected}>${escapeHtml(employeeMap[employeeCode])}</option>`;
    }));

  return options.join("");
}

function buildApprovalProjectOptions(projects, entries) {
  const currentValue = document.getElementById("reviewProjectFilter")?.value || "";
  const projectMap = {};

  (Array.isArray(projects) ? projects : []).forEach(project => {
    const projectCode = String(project && project.projectCode || "").trim();
    if (projectCode) {
      projectMap[projectCode] = project;
    }
  });

  (Array.isArray(entries) ? entries : []).forEach(entry => {
    const projectCode = String(entry && entry.projectCode || "").trim();
    if (projectCode && !projectMap[projectCode]) {
      projectMap[projectCode] = { projectCode, projectName: projectCode };
    }
  });

  const options = [`<option value="">${escapeHtml(t("filters.allProjects"))}</option>`]
    .concat(Object.keys(projectMap).sort((left, right) => left.localeCompare(right)).map(projectCode => {
      const selected = currentValue === projectCode ? " selected" : "";
      const project = projectMap[projectCode];
      return `<option value="${escapeHtml(projectCode)}" data-project-color-key="${escapeHtml(getProjectColorKey(project))}" data-project-marker-key="${escapeHtml(getProjectMarkerKey(project))}"${selected}>${escapeHtml(formatProjectCodeAndName(project))}</option>`;
    }));

  return options.join("");
}

function populateApprovalProjectFilter(projects, entries) {
  const projectFilter = document.getElementById("reviewProjectFilter");
  if (!projectFilter) {
    return;
  }

  const previousValue = projectFilter.value || "";
  projectFilter.innerHTML = buildApprovalProjectOptions(projects, entries);
  if (previousValue && Array.from(projectFilter.options).some(option => option.value === previousValue)) {
    projectFilter.value = previousValue;
  }
}

const REVIEW_TABS = Object.freeze({
  pending: { id: "pending-tab", container: "pendingContainer", label: "review.pending" },
  attention: { id: "attention-tab", container: "attentionContainer", label: "review.attentionTab" },
  rejected: { id: "rejected-tab", container: "rejectedContainer", label: "review.rejected" },
  approved: { id: "approved-tab", container: "approvedContainer", label: "review.approved" },
});
const reviewPageState = { page: 1, range: "default", sequence: 0, generation: 0, cache: new Map(), pending: new Map(), loading: false, selecting: false, payload: null, filterTimer: null };
let approvalEmployeeFacets = [];

function getActiveReviewTab() {
  return Object.keys(REVIEW_TABS).find(tab => document.getElementById(REVIEW_TABS[tab].id)?.classList.contains("active")) || "pending";
}

function buildReviewPageQuery(page = reviewPageState.page, selectionOnly = false) {
  const query = new URLSearchParams({
    tab: selectionOnly ? "pending" : getActiveReviewTab(), page: String(page), range: reviewPageState.range,
    search: document.getElementById("approvalsSearchInput").value.trim(),
    employeeCode: document.getElementById("reviewEmployeeFilter").value,
    projectCode: document.getElementById("reviewProjectFilter")?.value || "",
  });
  if (reviewPageState.range === "custom") {
    query.set("startDate", document.getElementById("reviewStartDate").value);
    query.set("endDate", document.getElementById("reviewEndDate").value);
  }
  if (selectionOnly) query.set("selectionOnly", "true");
  return query.toString();
}

function updateApprovalTabLabels(counts = {}) {
  Object.keys(REVIEW_TABS).forEach(tab => {
    document.getElementById(REVIEW_TABS[tab].id).textContent = t(REVIEW_TABS[tab].label, { count: Number(counts[tab]) || 0 });
  });
}

function renderReviewPayload(payload) {
  reviewPageState.payload = payload;
  reviewPageState.page = Number(payload.page) || 1;
  allApprovalEntries = Array.isArray(payload.approvals) ? payload.approvals : [];
  approvalEmployeeFacets = Array.isArray(payload.employees) ? payload.employees : [];
  approvalScopedProjects = Array.isArray(payload.projects) ? payload.projects : [];
  document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions(approvalEmployeeFacets);
  populateApprovalProjectFilter(approvalScopedProjects, []);
  document.getElementById("reviewStartDate").value = payload.startDate || "";
  document.getElementById("reviewEndDate").value = payload.endDate || "";
  updateApprovalTabLabels(payload.counts);
  Object.keys(REVIEW_TABS).forEach(tab => {
    if (tab !== payload.tab) document.getElementById(REVIEW_TABS[tab].container).replaceChildren();
  });
  renderApprovalsList(REVIEW_TABS[payload.tab].container, allApprovalEntries, ["pending", "attention"].includes(payload.tab),
    payload.tab === "attention" ? t("review.noneAttention") : "");
  const total = Number(payload.total) || 0;
  const from = total ? (reviewPageState.page - 1) * 25 + 1 : 0;
  const to = total ? from + allApprovalEntries.length - 1 : 0;
  const previous = '<button type="button" class="btn btn-outline-secondary btn-sm" data-review-page="' + (reviewPageState.page - 1) + '" ' + (reviewPageState.page <= 1 ? "disabled" : "") + ' aria-label="' + escapeHtml(t("review.previousPage")) + '">‹</button>';
  const next = '<button type="button" class="btn btn-outline-secondary btn-sm" data-review-page="' + (reviewPageState.page + 1) + '" ' + (reviewPageState.page >= payload.totalPages ? "disabled" : "") + ' aria-label="' + escapeHtml(t("review.nextPage")) + '">›</button>';
  document.getElementById("reviewPagination").innerHTML = total ? previous + '<span role="status">' + escapeHtml(t("review.pageRange", { from, to, total })) + '</span>' + next : "";
  updateApproveFilteredButtonState();
}

async function fetchReviewPage({ page = 1, force = false } = {}) {
  if (force) { reviewPageState.generation++; reviewPageState.cache.clear(); }
  reviewPageState.page = page;
  const generation = reviewPageState.generation;
  const sequence = ++reviewPageState.sequence;
  const key = buildReviewPageQuery(page);
  const pendingKey = generation + "|" + key;
  if (!force && reviewPageState.cache.has(key)) {
    reviewPageState.loading = false;
    renderReviewPayload(reviewPageState.cache.get(key));
    return true;
  }
  reviewPageState.loading = true;
  updateApproveFilteredButtonState();
  const containerId = REVIEW_TABS[getActiveReviewTab()].container;
  setLoadingState(containerId, "grid", 3);
  document.getElementById("reviewPagination").replaceChildren();
  try {
    let work = reviewPageState.pending.get(pendingKey);
    if (!work) {
      work = fetch(apiUrl + "review/bootstrap?" + key + "&_refresh=" + generation).then(parseResponse);
      reviewPageState.pending.set(pendingKey, work);
    }
    const payload = await work;
    if (generation !== reviewPageState.generation) return false;
    reviewPageState.cache.set(key, payload);
    if (reviewPageState.cache.size > 12) reviewPageState.cache.delete(reviewPageState.cache.keys().next().value);
    if (sequence !== reviewPageState.sequence) return false;
    reviewPageState.loading = false;
    renderReviewPayload(payload);
    return true;
  } catch (error) {
    if (sequence !== reviewPageState.sequence || generation !== reviewPageState.generation) return false;
    reviewPageState.loading = false;
    reviewPageState.payload = null;
    allApprovalEntries = [];
    document.getElementById(containerId).innerHTML = createEmptyState(t("review.loadError"));
    showToast(error.message || t("review.loadError"), "error");
    console.error("Error loading review page:", error);
    return false;
  } finally {
    reviewPageState.pending.delete(pendingKey);
    if (sequence === reviewPageState.sequence) updateApproveFilteredButtonState();
  }
}

function loadReviewView() { return fetchReviewPage({ page: reviewPageState.page, force: true }); }
function loadApprovalsView() { return loadReviewView(); }
window.loadReviewView = loadReviewView;
window.invalidateReviewWorkspace = function () {
  reviewPageState.generation++; reviewPageState.sequence++; reviewPageState.cache.clear();
};
window.resetReviewWorkspace = function () {
  window.invalidateReviewWorkspace();
  clearTimeout(reviewPageState.filterTimer);
  Object.assign(reviewPageState, { page: 1, range: "default", loading: false, selecting: false, payload: null, filterTimer: null });
  reviewPageState.pending.clear();
  allApprovalEntries = []; approvalEmployeeFacets = []; approvalScopedProjects = [];
  Object.keys(REVIEW_TABS).forEach(tab => {
    const active = tab === "pending";
    const button = document.getElementById(REVIEW_TABS[tab].id);
    button.classList.toggle("active", active); button.setAttribute("aria-selected", String(active));
    button.setAttribute("tabindex", active ? "0" : "-1");
    const host = document.getElementById(REVIEW_TABS[tab].container);
    host.classList.toggle("active", active); host.classList.toggle("show", active); host.replaceChildren();
  });
  ["approvalsSearchInput", "reviewEmployeeFilter", "reviewProjectFilter", "reviewStartDate", "reviewEndDate"].forEach(id => { document.getElementById(id).value = ""; });
  document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions([]);
  populateApprovalProjectFilter([], []);
  document.getElementById("reviewPagination").replaceChildren();
  updateApprovalTabLabels();
  updateApproveFilteredButtonState();
};
window.openProjectReviewPage = async function (projectCode) {
  window.resetReviewWorkspace();
  const filter = document.getElementById("reviewProjectFilter");
  if (!Array.from(filter.options).some(option => option.value === projectCode)) {
    filter.add(new Option(projectCode, projectCode));
  }
  filter.value = projectCode;
  const loaded = await fetchReviewPage({ page: 1, force: true });
  return loaded && approvalScopedProjects.some(project => String(project.projectCode) === projectCode);
};

const REVIEW_ISSUE_I18N_KEYS = Object.freeze({
  shortovertime: "review.issue.shortOvertime",
  clockoutmissing: "review.issue.clockOutMissing",
  invalidpunchtimes: "review.issue.invalidPunchTimes",
});

function normalizeReviewIssueCode(issue) {
  const rawCode = typeof issue === "string"
    ? issue
    : (issue && typeof issue === "object" ? (issue.code || issue.issueCode || issue.type || "") : "");
  return String(rawCode || "").trim().toLowerCase();
}

function getReviewIssueCodes(entry) {
  const issues = entry && Array.isArray(entry.reviewIssues) ? entry.reviewIssues : [];
  return Array.from(new Set(issues
    .map(normalizeReviewIssueCode)
    .filter(code => Object.prototype.hasOwnProperty.call(REVIEW_ISSUE_I18N_KEYS, code))));
}

function hasReviewIssues(entry) {
  if (!entry || typeof entry !== "object") {
    return false;
  }

  if (entry.hasReviewIssues === true) {
    return true;
  }

  if (Array.isArray(entry.reviewIssues)) {
    return entry.reviewIssues.length > 0;
  }

  return Boolean(String(entry.reviewIssues || "").trim());
}

function getReviewAttentionEntries(entries) {
  return (Array.isArray(entries) ? entries : []).filter(hasReviewIssues);
}

function renderReviewIssues(entry) {
  if (!hasReviewIssues(entry)) {
    return "";
  }

  const issueCodes = getReviewIssueCodes(entry);
  const issueItems = issueCodes.length > 0
    ? issueCodes.map(code => `<li class="review-card-attention-item">${escapeHtml(t(REVIEW_ISSUE_I18N_KEYS[code]))}</li>`).join("")
    : `<li class="review-card-attention-item">${escapeHtml(t("review.issue.generic"))}</li>`;

  return `
    <section class="review-card-attention" aria-label="${escapeHtml(t("review.attention"))}">
      <div class="review-card-attention-title"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i><span>${escapeHtml(t("review.attention"))}</span></div>
      <ul class="review-card-attention-list">${issueItems}</ul>
    </section>
  `;
}

function renderEntryMonetaryPill(entry) {
  const monetary = entry && entry.monetary;
  if (!monetary) {
    return "";
  }

  if (String(monetary.status || "").toLowerCase() !== "final" || monetary.totalAmountCents == null) {
    return `<span class="meta-pill monetary-pill monetary-pill-unavailable" title="${escapeHtml(getMonetaryUnavailableLabel(monetary.unavailableReason))}"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>${escapeHtml(t("money.unavailable"))}</span>`;
  }

  const amount = formatCurrencyCents(monetary.totalAmountCents, monetary.currency);
  const paymentLabel = String(monetary.paymentOption || "cash").toLowerCase() === "leave"
    ? t("money.compensatoryLeave")
    : t("money.cash");
  return `<span class="meta-pill monetary-pill" title="${escapeHtml(`${paymentLabel} · ${t("money.salaryOnlyEstimate")}`)}"><i class="fa-solid fa-coins" aria-hidden="true"></i>${escapeHtml(`${t("money.estimatedValue")} ${amount}`)}</span>`;
}

function buildApprovalCard(entry, showActions) {
  const exactTimeLabel = getEntryExactTimeLabel(entry);
  const permissionBadge = getEntryPermissionBadgeMarkup(entry);
  const isPending = String(entry && entry.status || "pending").toLowerCase() === "pending";
  const canReview = showActions && isPending && !isEntryForgottenClockOut(entry) && canApproveEntry(entry);
  const canManage = canModifyEntry(entry);
  const projectCode = String(entry && entry.projectCode || "").trim();
  const projectRecord = findProjectByCode(approvalScopedProjects, projectCode) || projectCode;
  const projectIdentity = isDiverseEntry(entry)
    ? `<span class="inline-code-pill">${escapeHtml(t("shared.diverse"))}</span>`
    : (projectCode
      ? renderProjectIdentityPill(projectRecord, projectCode)
      : `<span class="inline-code-pill">${escapeHtml(t("shared.noProject"))}</span>`);
  const entryActionAttributes = [
    `data-employee-code="${escapeHtml(entry.employeeCode || "")}"`,
    `data-entryid="${escapeHtml(entry.entryId || "")}"`,
    `data-date="${escapeHtml(entry.date || "")}"`,
    `data-punchin="${escapeHtml(entry.punchIn || "")}"`,
    `data-punchout="${escapeHtml(entry.punchOut || "")}"`,
    `data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`,
    `data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`,
    `data-projectcode="${escapeHtml(entry.projectCode || "")}"`,
    `data-entrytype="${escapeHtml(getEntryType(entry))}"`,
    `data-workschedule="${escapeHtml(getEntryWorkSchedule(entry))}"`,
    `data-diversereason="${escapeHtml(entry.diverseReason || "")}"`,
    `data-diversesummary="${escapeHtml(entry.diverseSummary || "")}"`,
    `data-workcomment="${escapeHtml(entry.workComment || "")}"`,
    `data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`,
    `data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`,
    `data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`,
    `data-status="${escapeHtml(entry.status || "pending")}"`,
    `data-message="${escapeHtml(entry.message || "")}"`,
  ].join(" ");
  return `
    <article class="review-card">
      <div class="review-card-header">
        <div class="review-card-employee">
          <div class="review-card-title">${escapeHtml(entry.employeeName)}</div>
          <div class="worklog-secondary">EMP ${escapeHtml(entry.employeeCode)}</div>
        </div>
        <span class="status-badge ${getStatusTone(entry)}">${escapeHtml(getEntryStatusLabel(entry))}</span>
      </div>
      <div class="review-card-timing">
        <div>
          <div class="review-card-date">${escapeHtml(formatDateToWords(entry.date))}</div>
          <div class="worklog-secondary duration-value">${escapeHtml(formatQueueTitle(entry))}</div>
          ${exactTimeLabel ? `<div class="panel-note">${escapeHtml(exactTimeLabel)}</div>` : ""}
        </div>
        <strong class="review-card-duration duration-value">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.waitingForPunchOut"))}</strong>
      </div>
      <div class="review-card-project">${projectIdentity}</div>
      <div class="review-card-meta">
        ${!isDiverseEntry(entry) && entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        ${!isDiverseEntry(entry) ? `<span class="meta-pill">${escapeHtml(formatPaymentOptionValue(entry.paymentOption || "cash"))}</span>` : ""}
        ${isDiverseEntry(entry) && entry.diverseReason ? `<span class="meta-pill">${escapeHtml(entry.diverseReason)}</span>` : ""}
        ${!isDiverseEntry(entry) && entry.reasonCode ? `<span class="meta-pill">${escapeHtml(entry.reasonCode)}</span>` : ""}
        ${renderEntryMonetaryPill(entry)}
        ${renderEntryWorkScheduleBadge(entry)}
      </div>
      ${renderReviewIssues(entry)}
      ${renderEntryWorkComment(entry)}
      ${entry.message ? `
        <div class="review-card-message">
          <div class="entry-work-comment-label">${escapeHtml(getEntrySupervisorNoteLabel(entry))}</div>
          <div>${escapeHtml(entry.message)}</div>
        </div>
      ` : ""}
      <div class="review-card-actions">
        ${canReview ? `
          <button class="btn btn-success btn-sm approvals-approve-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-check"></i> ${escapeHtml(t("action.approve"))}</button>
          <button class="btn btn-danger btn-sm approvals-reject-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-ban"></i> ${escapeHtml(t("action.reject"))}</button>
        ` : ""}
        ${canManage ? `
          <button type="button" class="btn btn-outline-secondary btn-sm approvals-edit-button" ${entryActionAttributes}><i class="fa-solid fa-pen"></i> ${escapeHtml(t("action.edit"))}</button>
          <button type="button" class="btn btn-outline-danger btn-sm approvals-delete-button" ${entryActionAttributes}><i class="fa-solid fa-trash"></i> ${escapeHtml(t("action.delete"))}</button>
        ` : ""}
        ${!canManage || (showActions && !canReview) ? permissionBadge : ""}
        <button type="button" class="btn btn-outline-secondary btn-sm approvals-jump-button" ${entryActionAttributes}><i class="fa-solid fa-arrow-up-right-from-square"></i> ${escapeHtml(t("action.openEntry"))}</button>
      </div>
    </article>
  `;
}

function renderApprovalsList(containerId, entries, showActions, emptyMessage = "") {
  const container = document.getElementById(containerId);
  if (!entries || entries.length === 0) {
    container.innerHTML = createEmptyState(emptyMessage || (showActions ? t("review.nonePending") : t("review.noneForState")));
    return;
  }

  container.innerHTML = `<div class="review-card-grid">${entries.map(entry => buildApprovalCard(entry, showActions)).join("")}</div>`;
}

function applyApprovalFilters() {
  return fetchReviewPage({ page: 1 });
}

window.rerenderReviewViewForLanguageChange = function () {
  document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions(approvalEmployeeFacets);
  populateApprovalProjectFilter(approvalScopedProjects, allApprovalEntries);
  if (reviewPageState.payload) renderReviewPayload(reviewPageState.payload);
  if (typeof applyHistoryFilters === "function") {
    applyHistoryFilters();
  }
};

function normalizeBatchApprovalResult(result, requestedCountFallback = 0) {
  const payload = result && typeof result === "object" ? result : {};
  const fallbackCount = Number.isFinite(Number(requestedCountFallback))
    ? Math.max(0, Math.trunc(Number(requestedCountFallback)))
    : 0;
  const requestedCount = Number.isFinite(Number(payload.requestedCount))
    ? Math.max(0, Math.trunc(Number(payload.requestedCount)))
    : fallbackCount;
  const updatedCount = Number.isFinite(Number(payload.updatedCount))
    ? Math.max(0, Math.trunc(Number(payload.updatedCount)))
    : 0;
  const failedCount = Number.isFinite(Number(payload.failedCount))
    ? Math.max(0, Math.trunc(Number(payload.failedCount)))
    : Math.max(0, requestedCount - updatedCount);
  const declaredOutcome = String(payload.outcome || "").trim().toLowerCase();
  const outcome = ["success", "partial", "none"].includes(declaredOutcome)
    ? declaredOutcome
    : (updatedCount === 0 ? "none" : (updatedCount < requestedCount ? "partial" : "success"));

  return {
    requestedCount,
    updatedCount,
    failedCount,
    outcome,
    failures: Array.isArray(payload.failures) ? payload.failures : [],
    message: String(payload.message || "").trim(),
  };
}

function isPendingApprovalTabActive() {
  return document.getElementById("pending-tab")?.classList.contains("active") === true;
}

function updateApproveFilteredButtonState() {
  const button = document.getElementById("approveFilteredBtn");
  if (!button) {
    return;
  }

  const isPendingTab = isPendingApprovalTabActive();
  const actionableCount = Number(reviewPageState.payload?.actionableCount) || 0;
  button.classList.toggle("d-none", !isPendingTab);
  button.disabled = reviewPageState.loading || reviewPageState.selecting || !isPendingTab || actionableCount === 0;
  button.textContent = `${t("review.approveFiltered")} (${actionableCount})`;
}

async function approveFilteredEntries(button = document.getElementById("approveFilteredBtn")) {
  if (!isPendingApprovalTabActive()) {
    return;
  }
  if (reviewPageState.loading || reviewPageState.selecting) return;

  // Only selection keys cross the wire for bulk approval, across all pages.
  const filterKey = buildReviewPageQuery(1);
  let filteredPendingEntries;
  reviewPageState.selecting = true;
  updateApproveFilteredButtonState();
  try {
    const selection = await fetch(apiUrl + "review/bootstrap?" + buildReviewPageQuery(1, true)).then(parseResponse);
    if (!isPendingApprovalTabActive() || buildReviewPageQuery(1) !== filterKey) return;
    filteredPendingEntries = Array.isArray(selection.selection) ? selection.selection : [];
  } catch (error) { showToast(error.message || t("review.batchApproveError"), "error"); return; }
  finally { reviewPageState.selecting = false; updateApproveFilteredButtonState(); }
  if (filteredPendingEntries.length === 0) {
    showToast(t("review.approveFilteredNone"), "info");
    return;
  }

  if (!window.confirm(t("review.approveFilteredConfirm", { count: filteredPendingEntries.length }))) {
    return;
  }

  try {
    await runButtonAction(button, async () => {
      const response = await fetch(apiUrl + "employee/approval/batch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          status: "approved",
          entries: filteredPendingEntries.map(entry => ({
            employeeCode: entry.employeeCode,
            entryId: entry.entryId || "",
            date: entry.date,
            punchIn: entry.punchIn,
          })),
        }),
      });
      const result = await parseResponse(response);
      const batchResult = normalizeBatchApprovalResult(result, filteredPendingEntries.length);
      if (batchResult.outcome === "none" || batchResult.updatedCount === 0) {
        const error = new Error(batchResult.message || t("review.batchApproveError"));
        error.batchFailures = batchResult.failures;
        throw error;
      }

      if (batchResult.outcome === "partial") {
        console.warn("Some selected approvals were not updated.", batchResult.failures);
        showToast(
          batchResult.message || t("review.batchApproveSuccess", { count: batchResult.updatedCount }),
          "warning",
        );
      } else {
        showToast(t("review.batchApproveSuccess", { count: batchResult.updatedCount }), "success");
      }
      if (window.dashboardState) {
        dashboardState.bootstrap = null;
        filteredPendingEntries.forEach(entry => {
          dashboardState.entriesByEmployee[entry.employeeCode] = undefined;
        });
      }
      if (typeof window.requestAppViewRefresh === "function") {
        await window.requestAppViewRefresh(["adminView", "dashboardView", "employeesView", "projectsView"], { forceActive: true });
      } else {
        await loadReviewView();
      }
    }, { key: "approval-batch" });
  } catch (error) {
    console.error("Error during batch approve:", error);
    showToast(error.message || t("review.batchApproveError"), "error");
  }
}

document.getElementById("approvalsSearchInput").addEventListener("input", () => {
  clearTimeout(reviewPageState.filterTimer);
  reviewPageState.filterTimer = setTimeout(() => applyApprovalFilters(), 220);
});
document.getElementById("reviewEmployeeFilter").addEventListener("change", applyApprovalFilters);
document.getElementById("reviewProjectFilter").addEventListener("change", applyApprovalFilters);
function applyReviewDateFilter() { reviewPageState.range = "custom"; return applyApprovalFilters(); }
document.getElementById("reviewStartDate").addEventListener("change", applyReviewDateFilter);
document.getElementById("reviewEndDate").addEventListener("change", applyReviewDateFilter);
document.getElementById("reviewAllDatesBtn").addEventListener("click", () => { reviewPageState.range = "all"; applyApprovalFilters(); });
document.getElementById("reviewPagination").addEventListener("click", event => {
  const button = event.target.closest("[data-review-page]");
  if (button && !button.disabled) fetchReviewPage({ page: Number(button.dataset.reviewPage) });
});
document.getElementById("approveFilteredBtn").addEventListener("click", event => {
  approveFilteredEntries(event.currentTarget);
});
document.getElementById("approvalTabs").addEventListener("shown.bs.tab", () => {
  fetchReviewPage({ page: 1 });
});
document.getElementById("reviewResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("approvalsSearchInput").value = "";
  document.getElementById("reviewEmployeeFilter").value = "";
  document.getElementById("reviewProjectFilter").value = "";
  document.getElementById("reviewStartDate").value = "";
  document.getElementById("reviewEndDate").value = "";
  reviewPageState.range = "default";
  applyApprovalFilters();
});

document.getElementById("approvalsSection").addEventListener("click", event => {
  const approveButton = event.target.closest(".approvals-approve-button");
  if (approveButton) {
    updateApprovalActionInApprovals(approveButton, approveButton.getAttribute("data-employee-code"), "approved");
    return;
  }

  const rejectButton = event.target.closest(".approvals-reject-button");
  if (rejectButton) {
    updateApprovalActionInApprovals(rejectButton, rejectButton.getAttribute("data-employee-code"), "rejected");
    return;
  }

  const editButton = event.target.closest(".approvals-edit-button");
  if (editButton && typeof openUpdateModal === "function") {
    const employeeCode = editButton.getAttribute("data-employee-code");
    if (employeeCode) {
      setDashboardSelectedEmployee(employeeCode);
      openUpdateModal(editButton, employeeCode);
    }
    return;
  }

  const deleteButton = event.target.closest(".approvals-delete-button");
  if (deleteButton && typeof deleteEntry === "function") {
    deleteEntry(deleteButton, deleteButton.getAttribute("data-employee-code"));
    return;
  }

  const jumpButton = event.target.closest(".approvals-jump-button");
  if (jumpButton) {
    const employeeCode = jumpButton.getAttribute("data-employee-code");
    const projectCode = jumpButton.getAttribute("data-projectcode");
    const entryId = jumpButton.getAttribute("data-entryid") || "";
    if (typeof window.openEmployeeEntryInPeopleView !== "function") {
      showToast(t("employees.loadError"), "error");
      return;
    }
    runButtonAction(
      jumpButton,
      () => window.openEmployeeEntryInPeopleView(employeeCode, projectCode, entryId),
      { key: `open-entry:${employeeCode}:${entryId || `${jumpButton.getAttribute("data-date")}:${jumpButton.getAttribute("data-punchin")}`}` },
    ).catch(error => {
      console.error("Unable to open employee entry:", error);
      showToast(t("employees.loadError"), "error");
    });
  }
});

updateApprovalTabLabels();
updateApproveFilteredButtonState();
