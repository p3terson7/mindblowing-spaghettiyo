const dashboardState = {
  employees: [],
  entriesByEmployee: {},
  history: [],
  historyLoaded: false,
  bootstrap: null,
};

function buildEmployeeOptions(employees) {
  return `<option value="">${escapeHtml(t("shared.selectEmployee"))}</option>${employees.map(emp => `<option value="${escapeHtml(emp.code)}">${escapeHtml(emp.name)}</option>`).join("")}`;
}

function buildProjectFilterOptions(projects) {
  return buildProjectOptions(projects || [], t("filters.allProjects"), document.getElementById("projectFilter")?.value || "");
}

function groupEntriesByDate(entries) {
  return entries.reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});
}

function getEmployeeNameByCode(employeeCode) {
  const match = dashboardState.employees.find(employee => employee.code === employeeCode);
  return match ? match.name : employeeCode;
}

function enrichEntry(employee, entry) {
  return {
    ...entry,
    employeeCode: employee.code,
    employeeName: employee.name,
  };
}

function getFlattenedDashboardEntries() {
  return dashboardState.employees.flatMap(employee => {
    const entries = dashboardState.entriesByEmployee[employee.code] || [];
    return entries.map(entry => enrichEntry(employee, entry));
  });
}

function createEmptyState(message) {
  return `<div class="empty-state">${escapeHtml(message)}</div>`;
}

function setDashboardLoadingState() {
  setLoadingState("dashboardApprovalQueue", "queue", 3);
  setLoadingState("dashboardActiveList", "queue", 3);
  setLoadingState("dashboardRecentActivity", "activity", 4);
  setLoadingState("punchClockEntries", "entries", 3);
}

function buildInspectorMeta(entryCount, startDate, endDate, projectCode) {
  const parts = [tn("shared.entry", entryCount)];
  const dateRangeLabel = buildDateRangeLabel(startDate, endDate);
  if (dateRangeLabel) {
    parts.push(dateRangeLabel);
  }
  if (projectCode) {
    parts.push(projectCode);
  }
  return parts.join(" | ");
}

function formatQueueTitle(entry) {
  return getEntryRoundedTimeRange(entry);
}

function renderDashboardApprovalQueue(entries) {
  const container = document.getElementById("dashboardApprovalQueue");
  const queueEntries = entries
    .filter(entry => String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry))
    .sort((left, right) => toEntryDateTime(right) - toEntryDateTime(left))
    .slice(0, 6);

  document.getElementById("dashboardPendingQueueMeta").textContent = queueEntries.length > 0
    ? `${tn("shared.item", queueEntries.length)} ${t("shared.waiting").toLowerCase()}`
    : t("dashboard.pendingQueueMetaEmpty");

  if (queueEntries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noPending"));
    return;
  }

  container.innerHTML = queueEntries.map(entry => `
    <article class="queue-card">
      <div class="queue-card-header">
        <div>
          <div class="queue-card-title">${escapeHtml(entry.employeeName)}</div>
          <div class="worklog-secondary">${escapeHtml(formatDateLabel(entry.date))} | ${escapeHtml(formatQueueTitle(entry))}</div>
          ${getEntryExactTimeLabel(entry) ? `<div class="panel-note">${escapeHtml(getEntryExactTimeLabel(entry))}</div>` : ""}
        </div>
        <span class="status-badge pending">${escapeHtml(t("status.pending"))}</span>
      </div>
      <div class="queue-card-meta">
        <span class="inline-code-pill">${escapeHtml(entry.projectCode || t("shared.noProject"))}</span>
        ${entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        <span class="meta-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.waitingForPunchOut"))}</span>
      </div>
      ${entry.message ? `<div class="review-card-message">${escapeHtml(entry.message)}</div>` : ""}
      <div class="queue-card-actions">
        <button type="button" class="btn btn-success btn-sm dashboard-approve-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-check"></i> ${escapeHtml(t("action.approve"))}</button>
        <button type="button" class="btn btn-danger btn-sm dashboard-reject-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-ban"></i> ${escapeHtml(t("action.reject"))}</button>
        <button type="button" class="btn btn-outline-secondary btn-sm dashboard-jump-button" data-employee-code="${escapeHtml(entry.employeeCode)}">${escapeHtml(t("action.openEmployee"))}</button>
      </div>
    </article>
  `).join("");
}

function renderDashboardActiveSessions(entries) {
  const container = document.getElementById("dashboardActiveList");
  const activeEntries = entries
    .filter(entry => isEntryOpen(entry))
    .sort((left, right) => toEntryDateTime(right) - toEntryDateTime(left))
    .slice(0, 6);

  document.getElementById("dashboardActiveQueueMeta").textContent = activeEntries.length > 0
    ? tn("shared.session", activeEntries.length)
    : t("dashboard.activeQueueMetaEmpty");

  if (activeEntries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noActive"));
    return;
  }

  container.innerHTML = activeEntries.map(entry => {
    const elapsed = Math.max(0, Math.floor((Date.now() - toEntryDateTime(entry).getTime()) / 1000));
    return `
      <article class="queue-card">
        <div class="queue-card-header">
          <div>
            <div class="queue-card-title">${escapeHtml(entry.employeeName)}</div>
            <div class="worklog-secondary">${escapeHtml(t("dashboard.started", { date: formatDateLabel(entry.date), time: formatTimeString(entry.punchIn) }))}</div>
            ${getEntryExactTimeLabel(entry) ? `<div class="panel-note">${escapeHtml(getEntryExactTimeLabel(entry))}</div>` : ""}
          </div>
          <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
        </div>
        <div class="queue-card-meta">
          <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(elapsed))}</span>
          <span class="meta-pill">${escapeHtml(entry.projectCode || t("shared.noProject"))}</span>
          ${entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        </div>
        <div class="queue-card-actions">
          <button type="button" class="btn btn-outline-secondary btn-sm dashboard-jump-button" data-employee-code="${escapeHtml(entry.employeeCode)}">${escapeHtml(t("action.openEmployee"))}</button>
        </div>
      </article>
    `;
  }).join("");
}

function renderDashboardRecentActivity(entries) {
  const container = document.getElementById("dashboardRecentActivity");
  const recentEntries = Array.isArray(entries) ? entries : (dashboardState.history || []);

  if (recentEntries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noRecentHistory"));
    return;
  }

  container.innerHTML = recentEntries.map(entry => {
    const actionTone = String(entry.action || "").toLowerCase();
    return `
      <article class="activity-card">
        <div class="review-card-header">
          <div>
            <strong>${escapeHtml(entry.employee || t("shared.system"))}</strong>
            <div class="worklog-secondary">${escapeHtml(formatRelativeTime(entry.timestamp))} | ${escapeHtml(formatDateToWords(String(entry.timestamp || "").split(" ")[0] || ""))}</div>
          </div>
          <span class="action-badge ${escapeHtml(actionTone)}">${escapeHtml(translateHistoryAction(entry.action || "event"))}</span>
        </div>
        <div class="timeline-card-message">${renderAuditMessage(entry.message || t("shared.noMessage"))}</div>
      </article>
    `;
  }).join("");
}

function renderDashboardOverview(payload) {
  const model = payload || dashboardState.bootstrap || {};
  const totalSeconds = timeStringToSeconds(model.totalOvertime);
  const pendingCount = Number(model.pendingApprovals || 0);
  const activeCount = Number(model.activeEmployees || 0);
  const trackedCount = Number(model.trackedEmployees || dashboardState.employees.length || 0);

  document.getElementById("totalOvertime").innerText = secondsToDurationLabel(totalSeconds);
  document.getElementById("pendingApprovals").innerText = pendingCount;
  document.getElementById("activeEmployees").innerText = activeCount;
  document.getElementById("trackedEmployeesCount").innerText = trackedCount;
  const summary = document.getElementById("dashboardSummaryText");
  if (summary) {
    summary.textContent = pendingCount > 0
      ? `${tn("shared.approval", pendingCount)} | ${tn("shared.session", activeCount)}`
      : tn("shared.session", activeCount);
  }

  renderDashboardApprovalQueue(model.pendingQueue || []);
  renderDashboardActiveSessions(model.activeSessions || []);
  renderDashboardRecentActivity(model.recentHistory || []);
}

function applyDashboardBootstrap(payload) {
  const model = payload || {};
  dashboardState.bootstrap = model;
  dashboardState.employees = Array.isArray(model.employees) ? model.employees : [];
  dashboardState.history = Array.isArray(model.recentHistory) ? model.recentHistory : [];
  dashboardState.historyLoaded = true;

  const employeeSelect = document.getElementById("employeeSelect");
  employeeSelect.innerHTML = buildEmployeeOptions(dashboardState.employees);
  fetchOvertimeEntryLookups().then(lookups => {
    const projectFilter = document.getElementById("projectFilter");
    if (projectFilter) {
      const previousValue = projectFilter.value || "";
      projectFilter.innerHTML = buildProjectOptions(lookups.projects, t("filters.allProjects"), previousValue);
      projectFilter.value = previousValue;
    }
  }).catch(() => {
    const projectFilter = document.getElementById("projectFilter");
    if (projectFilter) {
      projectFilter.innerHTML = `<option value="">${escapeHtml(t("filters.allProjects"))}</option>`;
    }
  });

  const savedEmployee = localStorage.getItem("selectedEmployee");
  const desiredEmployee = savedEmployee && dashboardState.employees.some(employee => employee.code === savedEmployee)
    ? savedEmployee
    : (model.selectedEmployeeCode && dashboardState.employees.some(employee => employee.code === model.selectedEmployeeCode)
      ? model.selectedEmployeeCode
      : (model.defaultEmployeeCode && dashboardState.employees.some(employee => employee.code === model.defaultEmployeeCode)
        ? model.defaultEmployeeCode
        : ""));

  if (desiredEmployee && Array.isArray(model.selectedEmployeeEntries)) {
    dashboardState.entriesByEmployee[desiredEmployee] = model.selectedEmployeeEntries;
  }

  if (desiredEmployee) {
    employeeSelect.value = desiredEmployee;
    localStorage.setItem("selectedEmployee", desiredEmployee);
  }

  renderDashboardOverview(model);
}

async function fetchEmployees() {
  const response = await fetch(apiUrl + "employees");
  const employees = await parseResponse(response);
  dashboardState.employees = Array.isArray(employees) ? employees : [];
  const employeeSelect = document.getElementById("employeeSelect");
  employeeSelect.innerHTML = buildEmployeeOptions(dashboardState.employees);

  const savedEmployee = localStorage.getItem("selectedEmployee");
  if (savedEmployee && dashboardState.employees.some(employee => employee.code === savedEmployee)) {
    employeeSelect.value = savedEmployee;
  }

  return dashboardState.employees;
}

async function fetchEmployeeEntries(employeeCode) {
  const response = await fetch(apiUrl + "employee/" + employeeCode);
  if (response.status === 404) {
    return [];
  }
  const payload = await parseResponse(response);
  return Array.isArray(payload) ? payload : (payload ? [payload] : []);
}

async function loadDashboardCollections() {
  const employeeSelect = document.getElementById("employeeSelect");
  const savedEmployee = localStorage.getItem("selectedEmployee");
  const requestedEmployeeCode = (employeeSelect && employeeSelect.value) || savedEmployee || "";
  const query = requestedEmployeeCode ? `?employeeCode=${encodeURIComponent(requestedEmployeeCode)}` : "";
  const response = await fetch(apiUrl + "dashboard/bootstrap" + query);
  const payload = await parseResponse(response);
  applyDashboardBootstrap(payload);
}

function renderEmployeeEntries(employeeCode, entries) {
  const container = document.getElementById("punchClockEntries");
  container.innerHTML = "";

  if (!entries || entries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noEntriesFiltered"));
    return;
  }

  const groupedEntries = groupEntriesByDate(entries);
  Object.keys(groupedEntries)
    .sort((left, right) => new Date(right) - new Date(left))
    .forEach(date => {
      const dayEntries = groupedEntries[date];
      const dateGroup = document.createElement("div");
      dateGroup.className = "entry-date-group";
      const totalDaySeconds = dayEntries.reduce((accumulator, entry) => accumulator + timeStringToSeconds(entry.overtime), 0);
      dateGroup.innerHTML = `
        <div class="entry-date-header">
          <strong>${escapeHtml(formatDateToWords(date))}</strong>
          <span>${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>
        </div>
      `;

      dayEntries.forEach(entry => {
        const statusTone = getStatusTone(entry.status);
        const isOpen = isEntryOpen(entry);
        const isPending = String(entry.status || "pending").toLowerCase() === "pending";
        const exactTimeLabel = getEntryExactTimeLabel(entry);
        const card = document.createElement("article");
        card.className = `worklog-card${statusTone === "pending" ? " is-pending" : ""}${isOpen ? " is-open" : ""}`;

        const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
        const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
        const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
        const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
        const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
        const reviewButtons = isPending && !isOpen ? `
          <button class="btn btn-success btn-sm action-btn approve-btn" data-employee-code="${escapeHtml(employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.approve"))}">
            <i class="fa-solid fa-check"></i>
          </button>
          <button class="btn btn-danger btn-sm action-btn reject-btn" data-employee-code="${escapeHtml(employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.reject"))}">
            <i class="fa-solid fa-ban"></i>
          </button>
        ` : "";
        const actionHtml = `
          ${reviewButtons}
          <button class="btn btn-outline-secondary btn-sm action-btn update-button" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-overtime="${escapeHtml(entry.overtime || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${overtimeCodeAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("modal.updateEntry"))}">
            <i class="fa-solid fa-pen"></i>
          </button>
          <button class="btn btn-outline-secondary btn-sm action-btn delete-button" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
            <i class="fa-solid fa-trash"></i>
          </button>
        `;

        card.innerHTML = `
          <div class="worklog-main">
            <div>
            <div class="worklog-title">${escapeHtml(formatQueueTitle(entry))}</div>
            <div class="worklog-secondary">${escapeHtml(getEntryContextLabel(entry))}</div>
            ${exactTimeLabel ? `<div class="panel-note">${escapeHtml(exactTimeLabel)}</div>` : ""}
          </div>
          <div class="meta-row">
              <span class="inline-code-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.inProgress"))}</span>
              <span class="status-badge ${statusTone}">${escapeHtml(translateStatus(entry.status || "pending"))}</span>
          </div>
        </div>
        ${entry.message ? `<div class="worklog-message">${escapeHtml(entry.message)}</div>` : ""}
        <div class="worklog-actions">${actionHtml}</div>
        <div class="worklog-message-editor">
            <input type="text" class="form-control message-input" placeholder="${escapeHtml(t("shared.managerMessage"))}" value="${escapeHtml(entry.message || "")}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}">
            <button class="btn btn-outline-secondary btn-sm save-message-btn" type="button" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}">${escapeHtml(t("action.saveNote"))}</button>
        </div>
      `;
        dateGroup.appendChild(card);
      });

      container.appendChild(dateGroup);
    });
}

async function fetchEmployeeData() {
  const employeeCode = document.getElementById("employeeSelect").value;
  const selectedStartDate = document.getElementById("startDateFilter").value;
  const selectedEndDate = document.getElementById("endDateFilter").value;
  const selectedProjectCode = document.getElementById("projectFilter").value;
  const latestFirst = document.getElementById("latestCheck").checked;
  const container = document.getElementById("punchClockEntries");
  const addButton = document.getElementById("addEntryButton");
  const hint = document.getElementById("dashboardSelectionHint");
  const title = document.getElementById("dashboardInspectorTitle");

  addButton.disabled = !employeeCode;

  if (!employeeCode) {
    if (title) {
      title.textContent = t("dashboard.timeline");
    }
    hint.textContent = "";
    container.innerHTML = createEmptyState(t("dashboard.noEmployeeSelected"));
    return;
  }

  const employeeName = getEmployeeNameByCode(employeeCode);
  title.textContent = employeeName;

  try {
    setLoadingState("punchClockEntries", "entries", 3);
    let entries = dashboardState.entriesByEmployee[employeeCode];
    if (!entries) {
      entries = await fetchEmployeeEntries(employeeCode);
      dashboardState.entriesByEmployee[employeeCode] = entries;
    }

    let filteredEntries = entries.filter(entry => {
      if (!isDateWithinRange(entry.date, selectedStartDate, selectedEndDate)) {
        return false;
      }

      if (selectedProjectCode && String(entry.projectCode || "") !== selectedProjectCode) {
        return false;
      }

      return true;
    });

    filteredEntries = sortEntriesByDateTime(filteredEntries, latestFirst);
    hint.textContent = buildInspectorMeta(filteredEntries.length, selectedStartDate, selectedEndDate, selectedProjectCode);
    renderEmployeeEntries(employeeCode, filteredEntries);
  } catch (error) {
    console.error("Error fetching employee data:", error);
    showToast(t("dashboard.timelineLoadError"), "error");
  }
}

async function refreshDashboardView() {
  try {
    setDashboardLoadingState();
    await loadDashboardCollections();
    await fetchEmployeeData();
  } catch (error) {
    console.error("Error refreshing dashboard:", error);
    showToast(t("dashboard.loadError"), "error");
  }
}

window.refreshDashboardView = refreshDashboardView;

window.handleSyncStateChange = function (syncState) {
  const category = String(syncState && syncState.category || "").toLowerCase();
  const resource = String(syncState && syncState.resource || "");

  if (category === "seed") {
    dashboardState.employees = [];
    dashboardState.entriesByEmployee = {};
    dashboardState.history = [];
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
    if (typeof clearProjectDetailCache === "function") {
      clearProjectDetailCache();
    }
    return;
  }

  if (category === "employee" && resource) {
    dashboardState.entriesByEmployee[resource] = undefined;
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
    return;
  }

  if (category === "project") {
    if (typeof clearProjectDetailCache === "function") {
      clearProjectDetailCache();
    }
    return;
  }

  if (category === "employee-directory") {
    dashboardState.employees = [];
    dashboardState.entriesByEmployee = {};
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
    return;
  }

  if (category === "history") {
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
  }
};

async function populateEntryLookups(projectSelectId, overtimeCodeSelectId, selectedProjectCode = "", selectedOvertimeCode = "") {
  const lookups = await fetchOvertimeEntryLookups();
  document.getElementById(projectSelectId).innerHTML = buildProjectOptions(lookups.projects, t("shared.selectProject"), selectedProjectCode);
  document.getElementById(overtimeCodeSelectId).innerHTML = buildOvertimeCodeOptions(lookups.overtimeCodes, t("shared.selectOvertimeCode"), selectedOvertimeCode);
}

async function openAddEntryModal() {
  const employeeCode = document.getElementById("employeeSelect").value;
  if (!employeeCode) {
    showToast(t("dashboard.selectEmployeeBeforeNote"), "info");
    return;
  }

  document.getElementById("addEntryDate").value = new Date().toISOString().slice(0, 10);
  ["addPunchInHours", "addPunchInMinutes", "addPunchOutHours", "addPunchOutMinutes"].forEach(id => {
    document.getElementById(id).value = "";
  });
  await populateEntryLookups("addProjectCode", "addOvertimeCode");
  const addModal = new bootstrap.Modal(document.getElementById("addEntryModal"));
  addModal.show();
}

function openUpdateModal(button) {
  document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = "";
  const date = button.getAttribute("data-date");
  const originalPunchIn = button.getAttribute("data-punchin");
  const currentPunchOut = button.getAttribute("data-punchout");
  const exactPunchIn = button.getAttribute("data-exactpunchin") || originalPunchIn;
  const exactPunchOut = button.getAttribute("data-exactpunchout") || currentPunchOut;
  const projectCode = button.getAttribute("data-projectcode") || "";
  const overtimeCode = button.getAttribute("data-overtimecode") || "";
  const entryId = button.getAttribute("data-entryid") || "";
  const message = button.getAttribute("data-message") || "";

  document.getElementById("updateDate").value = date;
  document.getElementById("originalPunchIn").value = originalPunchIn;
  document.getElementById("originalPunchOut").value = currentPunchOut;
  document.getElementById("updateEntryId").value = entryId;
  document.getElementById("updateManagerMessage").value = message;
  document.getElementById("updateEntryForm").dataset.originalExactPunchIn = exactPunchIn || "";
  document.getElementById("updateEntryForm").dataset.originalExactPunchOut = exactPunchOut || "";

  if (exactPunchIn) {
    const [hours, minutes] = exactPunchIn.split(":");
    document.getElementById("updatePunchInHours").value = hours;
    document.getElementById("updatePunchInMinutes").value = minutes;
  }

  if (exactPunchOut) {
    const [hours, minutes] = exactPunchOut.split(":");
    document.getElementById("updatePunchOutHours").value = hours;
    document.getElementById("updatePunchOutMinutes").value = minutes;
  } else {
    document.getElementById("updatePunchOutHours").value = "";
    document.getElementById("updatePunchOutMinutes").value = "";
  }

  populateEntryLookups("updateProjectCode", "updateOvertimeCode", projectCode, overtimeCode).then(() => {
    document.getElementById("updateProjectCode").value = projectCode;
    document.getElementById("originalProjectCode").value = projectCode;
    document.getElementById("updateOvertimeCode").value = overtimeCode;
    document.getElementById("originalOvertimeCode").value = overtimeCode;
    const updateModal = new bootstrap.Modal(document.getElementById("updateEntryModal"));
    updateModal.show();
  }).catch(error => {
    console.error("Error fetching entry lookups:", error);
    showToast(t("dashboard.entryOptionsError"), "error");
  });
}

async function deleteEntry(button) {
  const employeeCode = document.getElementById("employeeSelect").value;
  const date = button.getAttribute("data-date");
  const punchIn = button.getAttribute("data-punchin");
  const entryId = button.getAttribute("data-entryid") || "";
  const managerMessage = window.prompt(t("dashboard.deleteManagerMessagePrompt"), "");

  if (!window.confirm(t("dashboard.deleteConfirm"))) {
    return;
  }

  if (managerMessage === null) {
    return;
  }

  if (!String(managerMessage).trim()) {
    showToast(t("dashboard.managerMessageRequired"), "error");
    return;
  }

  try {
    const response = await fetch(apiUrl + `employee/${employeeCode}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entryId, date, punchIn, message: managerMessage.trim() }),
    });
    await parseResponse(response);
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryDeleted"), "success");
    await refreshDashboardView();
  } catch (error) {
    console.error("Error deleting entry:", error);
    showToast(t("dashboard.entryDeleteError", { message: error.message }), "error");
  }
}

async function updateApprovalAction(button, newStatus) {
  const employeeCode = document.getElementById("employeeSelect").value;
  const date = button.getAttribute("data-date");
  const punchIn = button.getAttribute("data-punchin");
  const entryId = button.getAttribute("data-entryid") || "";
  const managerMessage = newStatus === "rejected" ? window.prompt(t("dashboard.rejectManagerMessagePrompt"), "") : "";

  if (newStatus === "rejected") {
    if (managerMessage === null) {
      return;
    }

    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
  }

  try {
    const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entryId, date, punchIn, status: newStatus, message: managerMessage }),
    });
    await parseResponse(response);
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryUpdated"), "success");
    await refreshDashboardView();
  } catch (error) {
    console.error("Approval update error:", error);
    showToast(t("dashboard.approvalError", { message: error.message }), "error");
  }
}

async function updateApprovalActionInApprovals(button, employeeCode, newStatus) {
  const date = button.getAttribute("data-date");
  const punchIn = button.getAttribute("data-punchin");
  const entryId = button.getAttribute("data-entryid") || "";
  const managerMessage = newStatus === "rejected" ? window.prompt(t("dashboard.rejectManagerMessagePrompt"), "") : "";

  if (newStatus === "rejected") {
    if (managerMessage === null) {
      return;
    }

    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
  }
  try {
    const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entryId, date, punchIn, status: newStatus, message: managerMessage }),
    });
    await parseResponse(response);
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryUpdated"), "success");
    await refreshDashboardView();
    if (typeof loadReviewView === "function") {
      await loadReviewView();
    } else {
      await loadApprovalsView();
    }
  } catch (error) {
    console.error("Approval update error in Approvals view:", error);
    showToast(t("dashboard.genericApprovalError"), "error");
  }
}

async function updateApprovalActionInDashboardQueue(button, employeeCode, newStatus) {
  const date = button.getAttribute("data-date");
  const punchIn = button.getAttribute("data-punchin");
  const entryId = button.getAttribute("data-entryid") || "";
  const managerMessage = newStatus === "rejected" ? window.prompt(t("dashboard.rejectManagerMessagePrompt"), "") : "";

  if (newStatus === "rejected") {
    if (managerMessage === null) {
      return;
    }

    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
  }
  try {
    const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entryId, date, punchIn, status: newStatus, message: managerMessage }),
    });
    await parseResponse(response);
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryUpdated"), "success");
    await refreshDashboardView();
  } catch (error) {
    console.error("Dashboard queue approval error:", error);
    showToast(t("dashboard.genericApprovalError"), "error");
  }
}

function focusDashboardEmployee(employeeCode) {
  const employeeSelect = document.getElementById("employeeSelect");
  employeeSelect.value = employeeCode;
  localStorage.setItem("selectedEmployee", employeeCode);
  if (typeof showView === "function") {
    showView("dashboardView");
  }
  fetchEmployeeData();
}

window.focusDashboardEmployee = focusDashboardEmployee;

document.getElementById("employeeSelect").addEventListener("change", event => {
  localStorage.setItem("selectedEmployee", event.target.value);
  fetchEmployeeData();
});

document.getElementById("startDateFilter").addEventListener("input", fetchEmployeeData);
document.getElementById("endDateFilter").addEventListener("input", fetchEmployeeData);
document.getElementById("projectFilter").addEventListener("change", fetchEmployeeData);
document.getElementById("latestCheck").addEventListener("change", fetchEmployeeData);
document.getElementById("dashboardResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("startDateFilter").value = "";
  document.getElementById("endDateFilter").value = "";
  document.getElementById("projectFilter").value = "";
  document.getElementById("latestCheck").checked = true;
  fetchEmployeeData();
});
document.getElementById("addEntryButton").addEventListener("click", openAddEntryModal);

document.getElementById("saveAddEntryBtn").addEventListener("click", async () => {
  const employeeCode = document.getElementById("employeeSelect").value;
  const date = document.getElementById("addEntryDate").value;
  if (!employeeCode || !date) {
    showToast(t("dashboard.selectEmployeeAndDate"), "error");
    return;
  }

  const punchInHours = document.getElementById("addPunchInHours").value.trim();
  const punchInMinutes = document.getElementById("addPunchInMinutes").value.trim();
  const punchOutHours = document.getElementById("addPunchOutHours").value.trim();
  const punchOutMinutes = document.getElementById("addPunchOutMinutes").value.trim();
  const projectCode = document.getElementById("addProjectCode").value;
  const overtimeCode = document.getElementById("addOvertimeCode").value;

  if (!punchInHours || !punchInMinutes || !punchOutHours || !punchOutMinutes) {
    showToast(t("dashboard.fillAllTimeFields"), "error");
    return;
  }

  if (!projectCode) {
    showToast(t("dashboard.selectProject"), "error");
    return;
  }

  if (!overtimeCode) {
    showToast(t("dashboard.selectOvertimeCode"), "error");
    return;
  }

  const twoDigitRegex = /^[0-9]{1,2}$/;
  if (!twoDigitRegex.test(punchInHours) || !twoDigitRegex.test(punchInMinutes) || !twoDigitRegex.test(punchOutHours) || !twoDigitRegex.test(punchOutMinutes)) {
    showToast(t("dashboard.numericTimeValidation"), "error");
    return;
  }

  const punchInTime = `${punchInHours.padStart(2, "0")}:${punchInMinutes.padStart(2, "0")}:00`;
  const punchOutTime = `${punchOutHours.padStart(2, "0")}:${punchOutMinutes.padStart(2, "0")}:00`;
  if (new Date(`${date}T${punchOutTime}`) <= new Date(`${date}T${punchInTime}`)) {
    showToast(t("dashboard.punchOutAfterPunchIn"), "error");
    return;
  }

  try {
    const response = await fetch(apiUrl + "employee/add/" + employeeCode, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        date,
        punchIn: punchInTime,
        punchOut: punchOutTime,
        status: "pending",
        projectCode,
        overtimeCode,
      }),
    });
    const data = await parseResponse(response);
    bootstrap.Modal.getInstance(document.getElementById("addEntryModal")).hide();
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryAdded"), "success");
    await refreshDashboardView();
  } catch (error) {
    console.error("Error adding entry:", error);
    showToast(t("dashboard.entryAddError", { message: error.message }), "error");
  }
});

document.getElementById("saveUpdateBtn").addEventListener("click", async () => {
  const employeeCode = document.getElementById("employeeSelect").value;
  const date = document.getElementById("updateDate").value;
  const originalPunchIn = document.getElementById("originalPunchIn").value;
  const originalPunchOut = document.getElementById("originalPunchOut").value || null;
  const originalExactPunchIn = document.getElementById("updateEntryForm").dataset.originalExactPunchIn || originalPunchIn;
  const originalExactPunchOut = document.getElementById("updateEntryForm").dataset.originalExactPunchOut || originalPunchOut || "";
  const entryId = document.getElementById("updateEntryId").value;
  const punchInHours = document.getElementById("updatePunchInHours").value.trim();
  const punchInMinutes = document.getElementById("updatePunchInMinutes").value.trim();
  const punchOutHours = document.getElementById("updatePunchOutHours").value.trim();
  const punchOutMinutes = document.getElementById("updatePunchOutMinutes").value.trim();
  const projectCode = document.getElementById("updateProjectCode").value;
  const originalProjectCode = document.getElementById("originalProjectCode").value;
  const overtimeCode = document.getElementById("updateOvertimeCode").value;
  const originalOvertimeCode = document.getElementById("originalOvertimeCode").value;
  const managerMessage = document.getElementById("updateManagerMessage").value.trim();

  if (!punchInHours || !punchInMinutes || !punchOutHours || !punchOutMinutes) {
    showToast(t("dashboard.fillAllTimeFields"), "error");
    return;
  }

  const twoDigitRegex = /^[0-9]{1,2}$/;
  if (!twoDigitRegex.test(punchInHours) || !twoDigitRegex.test(punchInMinutes) || !twoDigitRegex.test(punchOutHours) || !twoDigitRegex.test(punchOutMinutes)) {
    showToast(t("dashboard.numericTimeValidation"), "error");
    return;
  }

  const newPunchInBackend = `${punchInHours.padStart(2, "0")}:${punchInMinutes.padStart(2, "0")}:00`;
  const punchOutBackend = `${punchOutHours.padStart(2, "0")}:${punchOutMinutes.padStart(2, "0")}:00`;

  if (!projectCode || !overtimeCode) {
    showToast(t("dashboard.projectAndCodeRequired"), "error");
    return;
  }

  if (!managerMessage) {
    showToast(t("dashboard.managerMessageRequired"), "error");
    return;
  }

  if (newPunchInBackend === originalExactPunchIn && punchOutBackend === originalExactPunchOut && projectCode === originalProjectCode && overtimeCode === originalOvertimeCode) {
    showToast(t("dashboard.noChanges"), "info");
    return;
  }

  if (new Date(`${date}T${punchOutBackend}`) <= new Date(`${date}T${newPunchInBackend}`)) {
    showToast(t("dashboard.punchOutAfterPunchIn"), "error");
    return;
  }

  try {
    const response = await fetch(apiUrl + "employee/" + employeeCode, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ entryId, date, originalPunchIn, newPunchIn: newPunchInBackend, punchOut: punchOutBackend, projectCode, overtimeCode, message: managerMessage }),
    });
    const data = await parseResponse(response);
    const refreshPeopleEmployee = document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee || "";
    bootstrap.Modal.getInstance(document.getElementById("updateEntryModal")).hide();
    document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = "";
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryUpdated"), "success");
    await refreshDashboardView();
    if (refreshPeopleEmployee && typeof window.refreshPeopleEmployeeDetail === "function") {
      await window.refreshPeopleEmployeeDetail(refreshPeopleEmployee);
    }
  } catch (error) {
    console.error("Error updating entry:", error);
    showToast(t("dashboard.entryUpdateError", { message: error.message }), "error");
  }
});

document.getElementById("punchClockEntries").addEventListener("click", event => {
  const updateButton = event.target.closest(".update-button");
  if (updateButton) {
    openUpdateModal(updateButton);
    return;
  }

  const deleteButton = event.target.closest(".delete-button");
  if (deleteButton) {
    deleteEntry(deleteButton);
    return;
  }

  const approveButton = event.target.closest(".approve-btn");
  if (approveButton) {
    updateApprovalAction(approveButton, "approved");
    return;
  }

  const rejectButton = event.target.closest(".reject-btn");
  if (rejectButton) {
    updateApprovalAction(rejectButton, "rejected");
  }
});

document.getElementById("dashboardApprovalQueue").addEventListener("click", event => {
  const approveButton = event.target.closest(".dashboard-approve-button");
  if (approveButton) {
    updateApprovalActionInDashboardQueue(approveButton, approveButton.getAttribute("data-employee-code"), "approved");
    return;
  }

  const rejectButton = event.target.closest(".dashboard-reject-button");
  if (rejectButton) {
    updateApprovalActionInDashboardQueue(rejectButton, rejectButton.getAttribute("data-employee-code"), "rejected");
    return;
  }

  const jumpButton = event.target.closest(".dashboard-jump-button");
  if (jumpButton) {
    focusDashboardEmployee(jumpButton.getAttribute("data-employee-code"));
  }
});

document.getElementById("dashboardActiveList").addEventListener("click", event => {
  const jumpButton = event.target.closest(".dashboard-jump-button");
  if (jumpButton) {
    focusDashboardEmployee(jumpButton.getAttribute("data-employee-code"));
  }
});

document.addEventListener("click", event => {
  const saveButton = event.target.closest(".save-message-btn");
  if (!saveButton) {
    return;
  }

  const input = saveButton.parentElement.querySelector(".message-input");
  const message = input.value;
  const date = saveButton.getAttribute("data-date") || input.getAttribute("data-date");
  const punchIn = saveButton.getAttribute("data-punchin") || input.getAttribute("data-punchin");
  const employeeCode = document.getElementById("employeeSelect").value;
  if (!employeeCode) {
    showToast(t("dashboard.selectEmployeeBeforeNote"), "info");
    return;
  }

  fetch(apiUrl + "employee/message/" + employeeCode, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ date, punchIn, message }),
  })
    .then(parseResponse)
    .then(data => {
      dashboardState.entriesByEmployee[employeeCode] = undefined;
      dashboardState.historyLoaded = false;
      showToast(t("dashboard.managerMessageSaved"), "success");
      refreshDashboardView();
    })
    .catch(error => {
      console.error("Error updating message:", error);
      showToast(t("dashboard.managerMessageError"), "error");
    });
});
