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

async function refreshApprovalProjectFilter() {
  try {
    approvalScopedProjects = await fetchScopedProjects();
  } catch (error) {
    console.warn("Unable to load scoped projects for approvals:", error);
    approvalScopedProjects = [];
  }

  populateApprovalProjectFilter(approvalScopedProjects, allApprovalEntries);
}

function getFilteredApprovalEntries() {
  const searchTerm = document.getElementById("approvalsSearchInput").value;
  const selectedEmployee = document.getElementById("reviewEmployeeFilter").value;
  const selectedProject = document.getElementById("reviewProjectFilter")?.value || "";
  const startDate = document.getElementById("reviewStartDate").value;
  const endDate = document.getElementById("reviewEndDate").value;

  return filterEntries(allApprovalEntries, searchTerm).filter(entry => {
    if (selectedEmployee && String(entry.employeeCode || "") !== selectedEmployee) {
      return false;
    }

    if (selectedProject && String(entry.projectCode || "") !== selectedProject) {
      return false;
    }

    return isDateWithinRange(entry.date, startDate, endDate);
  });
}

async function loadApprovalsView() {
  try {
    setLoadingState("pendingContainer", "queue", 3);
    setLoadingState("attentionContainer", "queue", 2);
    setLoadingState("rejectedContainer", "queue", 2);
    setLoadingState("approvedContainer", "queue", 2);
    const entries = await fetch(apiUrl + "approvals/entries").then(parseResponse);
    allApprovalEntries = Array.isArray(entries) ? entries : [];
    document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions(allApprovalEntries);
    await refreshApprovalProjectFilter();
    applyApprovalFilters();
    return true;
  } catch (error) {
    console.error("Error fetching employees for approvals:", error);
    showToast(t("review.loadError"), "error");
    return false;
  }
}

async function loadReviewView() {
  try {
    setLoadingState("pendingContainer", "queue", 3);
    setLoadingState("attentionContainer", "queue", 2);
    setLoadingState("rejectedContainer", "queue", 2);
    setLoadingState("approvedContainer", "queue", 2);
    setLoadingState("allHistoryContainer", "activity", 4);
    setLoadingState("addHistoryContainer", "activity", 3);
    setLoadingState("editHistoryContainer", "activity", 3);
    setLoadingState("approveHistoryContainer", "activity", 3);
    setLoadingState("deleteHistoryContainer", "activity", 3);

    const payload = await fetch(apiUrl + "review/bootstrap").then(parseResponse);
    allApprovalEntries = Array.isArray(payload && payload.approvals) ? payload.approvals : [];
    approvalScopedProjects = Array.isArray(payload && payload.projects) ? payload.projects : [];
    document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions(allApprovalEntries);
    populateApprovalProjectFilter(approvalScopedProjects, allApprovalEntries);
    applyApprovalFilters();

    if (typeof renderHistoryTabs === "function") {
      allHistoryEntries = Array.isArray(payload && payload.history) ? payload.history : [];
      if (typeof applyHistoryFilters === "function") {
        applyHistoryFilters();
      } else {
        renderHistoryTabs(allHistoryEntries);
      }
    }
    return true;
  } catch (error) {
    console.error("Error loading review workspace:", error);
    showToast(t("review.loadError"), "error");
    return false;
  }
}

window.loadReviewView = loadReviewView;

function updateApprovalTabLabels(pendingEntries, attentionEntries, rejectedEntries, approvedEntries) {
  document.getElementById("pending-tab").textContent = t("review.pending", { count: pendingEntries.length });
  document.getElementById("attention-tab").textContent = t("review.attentionTab", { count: attentionEntries.length });
  document.getElementById("rejected-tab").textContent = t("review.rejected", { count: rejectedEntries.length });
  document.getElementById("approved-tab").textContent = t("review.approved", { count: approvedEntries.length });
}

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
        <div>
          <div class="review-card-title">${escapeHtml(entry.employeeName)}</div>
          <div class="worklog-secondary">${escapeHtml(formatDateToWords(entry.date))} | ${escapeHtml(formatQueueTitle(entry))}</div>
          ${exactTimeLabel ? `<div class="panel-note">${escapeHtml(exactTimeLabel)}</div>` : ""}
        </div>
        <span class="status-badge ${getStatusTone(entry)}">${escapeHtml(getEntryStatusLabel(entry))}</span>
      </div>
      <div class="review-card-meta">
        ${projectIdentity}
        ${!isDiverseEntry(entry) && entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        ${!isDiverseEntry(entry) ? `<span class="meta-pill">${escapeHtml(formatPaymentOptionValue(entry.paymentOption || "cash"))}</span>` : ""}
        ${isDiverseEntry(entry) && entry.diverseReason ? `<span class="meta-pill">${escapeHtml(entry.diverseReason)}</span>` : ""}
        ${!isDiverseEntry(entry) && entry.reasonCode ? `<span class="meta-pill">${escapeHtml(entry.reasonCode)}</span>` : ""}
        <span class="meta-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.waitingForPunchOut"))}</span>
        <span class="meta-pill">EMP ${escapeHtml(entry.employeeCode)}</span>
      </div>
      ${renderReviewIssues(entry)}
      ${renderEntryWorkComment(entry)}
      ${entry.message ? `
        <div class="review-card-message">
          <div class="entry-work-comment-label">${escapeHtml(getEntrySupervisorNoteLabel(entry))}</div>
          <div>${escapeHtml(entry.message)}</div>
        </div>
      ` : `<div class="panel-note">${escapeHtml(t("shared.noManagerNote"))}</div>`}
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

  container.innerHTML = `<div class="queue-list">${entries.map(entry => buildApprovalCard(entry, showActions)).join("")}</div>`;
}

function renderApprovalTabsFromFiltered(entries) {
  const pendingEntries = entries.filter(entry => String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry));
  const attentionEntries = getReviewAttentionEntries(entries);
  const rejectedEntries = entries.filter(entry => String(entry.status || "").toLowerCase() === "rejected");
  const approvedEntries = entries.filter(entry => String(entry.status || "").toLowerCase() === "approved");

  updateApprovalTabLabels(pendingEntries, attentionEntries, rejectedEntries, approvedEntries);
  renderApprovalsList("pendingContainer", pendingEntries, true);
  renderApprovalsList("attentionContainer", attentionEntries, true, t("review.noneAttention"));
  renderApprovalsList("rejectedContainer", rejectedEntries, false);
  renderApprovalsList("approvedContainer", approvedEntries, false);
  updateApproveFilteredButtonState(entries);
}

function applyApprovalFilters() {
  renderApprovalTabsFromFiltered(getFilteredApprovalEntries());
}

window.rerenderReviewViewForLanguageChange = function () {
  document.getElementById("reviewEmployeeFilter").innerHTML = buildApprovalEmployeeOptions(allApprovalEntries);
  populateApprovalProjectFilter(approvalScopedProjects, allApprovalEntries);
  applyApprovalFilters();
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

function getActionableFilteredPendingEntries(entries = getFilteredApprovalEntries()) {
  return (Array.isArray(entries) ? entries : []).filter(entry => (
    String(entry.status || "pending").toLowerCase() === "pending"
      && !isEntryOpen(entry)
      && !isEntryForgottenClockOut(entry)
      && canApproveEntry(entry)
  ));
}

function updateApproveFilteredButtonState(entries = getFilteredApprovalEntries()) {
  const button = document.getElementById("approveFilteredBtn");
  if (!button) {
    return;
  }

  const isPendingTab = isPendingApprovalTabActive();
  const actionableCount = getActionableFilteredPendingEntries(entries).length;
  button.classList.toggle("d-none", !isPendingTab);
  button.disabled = !isPendingTab || actionableCount === 0;
  button.textContent = `${t("review.approveFiltered")} (${actionableCount})`;
}

async function approveFilteredEntries(button = document.getElementById("approveFilteredBtn")) {
  if (!isPendingApprovalTabActive()) {
    return;
  }

  const filteredPendingEntries = getActionableFilteredPendingEntries();
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
        dashboardState.historyLoaded = false;
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

document.getElementById("approvalsSearchInput").addEventListener("input", applyApprovalFilters);
document.getElementById("reviewEmployeeFilter").addEventListener("change", applyApprovalFilters);
document.getElementById("reviewProjectFilter").addEventListener("change", applyApprovalFilters);
document.getElementById("reviewStartDate").addEventListener("input", applyApprovalFilters);
document.getElementById("reviewEndDate").addEventListener("input", applyApprovalFilters);
document.getElementById("approveFilteredBtn").addEventListener("click", event => {
  approveFilteredEntries(event.currentTarget);
});
document.getElementById("approvalTabs").addEventListener("shown.bs.tab", () => {
  updateApproveFilteredButtonState();
});
document.getElementById("reviewResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("approvalsSearchInput").value = "";
  document.getElementById("reviewEmployeeFilter").value = "";
  document.getElementById("reviewProjectFilter").value = "";
  document.getElementById("reviewStartDate").value = "";
  document.getElementById("reviewEndDate").value = "";
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

updateApprovalTabLabels([], [], [], []);
updateApproveFilteredButtonState([]);
