let allApprovalEntries = [];

async function loadApprovalsView() {
  try {
    const employees = await fetch(apiUrl + "employees").then(parseResponse);
    if (!employees || employees.length === 0) {
      allApprovalEntries = [];
      renderApprovalTabsFromFiltered([]);
      return;
    }

    const results = await Promise.all(employees.map(employee => fetchEmployeeApprovalData(employee)));
    allApprovalEntries = results.flat();
    renderApprovalTabsFromFiltered(allApprovalEntries);
  } catch (error) {
    console.error("Error fetching employees for approvals:", error);
    showToast(t("review.loadError"), "error");
  }
}

async function fetchEmployeeApprovalData(employee) {
  try {
    const data = await fetchEmployeeEntries(employee.code);
    return data.map(entry => ({
      ...entry,
      employeeName: employee.name,
      employeeCode: employee.code,
    }));
  } catch (error) {
    console.error(`Error fetching data for employee ${employee.code}:`, error);
    return [];
  }
}

function updateApprovalTabLabels(pendingEntries, rejectedEntries, approvedEntries) {
  document.getElementById("pending-tab").textContent = t("review.pending", { count: pendingEntries.length });
  document.getElementById("rejected-tab").textContent = t("review.rejected", { count: rejectedEntries.length });
  document.getElementById("approved-tab").textContent = t("review.approved", { count: approvedEntries.length });
}

function buildApprovalCard(entry, showActions) {
  return `
    <article class="review-card">
      <div class="review-card-header">
        <div>
          <div class="review-card-title">${escapeHtml(entry.employeeName)}</div>
          <div class="worklog-secondary">${escapeHtml(formatDateToWords(entry.date))} | ${escapeHtml(formatQueueTitle(entry))}</div>
        </div>
        <span class="status-badge ${getStatusTone(entry.status)}">${escapeHtml(translateStatus(entry.status || "pending"))}</span>
      </div>
      <div class="review-card-meta">
        <span class="inline-code-pill">${escapeHtml(entry.projectCode || t("shared.noProject"))}</span>
        ${entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        <span class="meta-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.waitingForPunchOut"))}</span>
        <span class="meta-pill">EMP ${escapeHtml(entry.employeeCode)}</span>
      </div>
      ${entry.message ? `<div class="review-card-message">${escapeHtml(entry.message)}</div>` : `<div class="panel-note">${escapeHtml(t("shared.noManagerNote"))}</div>`}
      <div class="review-card-actions">
        ${showActions ? `
          <button class="btn btn-success btn-sm approvals-approve-button" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-check"></i> ${escapeHtml(t("action.approve"))}</button>
          <button class="btn btn-danger btn-sm approvals-reject-button" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-ban"></i> ${escapeHtml(t("action.reject"))}</button>
        ` : ""}
        <button class="btn btn-outline-secondary btn-sm approvals-jump-button" data-employee-code="${escapeHtml(entry.employeeCode)}">${escapeHtml(t("action.openEmployee"))}</button>
      </div>
    </article>
  `;
}

function renderApprovalsList(containerId, entries, showActions) {
  const container = document.getElementById(containerId);
  if (!entries || entries.length === 0) {
    container.innerHTML = createEmptyState(showActions ? t("review.nonePending") : t("review.noneForState"));
    return;
  }

  container.innerHTML = `<div class="queue-list">${entries.map(entry => buildApprovalCard(entry, showActions)).join("")}</div>`;
}

function renderApprovalTabsFromFiltered(entries) {
  const pendingEntries = entries.filter(entry => String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry));
  const rejectedEntries = entries.filter(entry => String(entry.status || "").toLowerCase() === "rejected");
  const approvedEntries = entries.filter(entry => String(entry.status || "").toLowerCase() === "approved");

  updateApprovalTabLabels(pendingEntries, rejectedEntries, approvedEntries);
  renderApprovalsList("pendingContainer", pendingEntries, true);
  renderApprovalsList("rejectedContainer", rejectedEntries, false);
  renderApprovalsList("approvedContainer", approvedEntries, false);
}

document.getElementById("approvalsSearchInput").addEventListener("input", function () {
  const searchTerm = this.value;
  const filtered = filterEntries(allApprovalEntries, searchTerm);
  renderApprovalTabsFromFiltered(filtered);
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

  const jumpButton = event.target.closest(".approvals-jump-button");
  if (jumpButton && typeof focusDashboardEmployee === "function") {
    focusDashboardEmployee(jumpButton.getAttribute("data-employee-code"));
  }
});

updateApprovalTabLabels([], [], []);
