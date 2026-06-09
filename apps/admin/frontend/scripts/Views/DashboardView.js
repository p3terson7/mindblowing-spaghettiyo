const dashboardState = {
  employees: [],
  entriesByEmployee: {},
  history: [],
  historyLoaded: false,
  bootstrap: null,
  projects: [],
};
let dashboardEmployeeSearchTimer = null;

function buildEmployeeOptions(employees) {
  return `<option value="">${escapeHtml(t("shared.selectEmployee"))}</option>${employees.map(emp => `<option value="${escapeHtml(emp.code)}">${escapeHtml(emp.name)}</option>`).join("")}`;
}

function getDashboardEmployeeSearchLabel(employee) {
  if (!employee) {
    return "";
  }

  const name = String(employee.name || employee.code || "").trim();
  const code = String(employee.code || "").trim();
  return code ? `${name} | ${code}` : name;
}

function buildDashboardEmployeeSearchOptions(employees) {
  return (Array.isArray(employees) ? employees : [])
    .map(employee => `<option value="${escapeHtml(getDashboardEmployeeSearchLabel(employee))}"></option>`)
    .join("");
}

function populateDashboardEmployeeControls(employees) {
  const employeeSelect = document.getElementById("employeeSelect");
  const employeeSearchList = document.getElementById("dashboardEmployeeSearchList");
  if (employeeSelect) {
    employeeSelect.innerHTML = buildEmployeeOptions(employees);
  }
  if (employeeSearchList) {
    employeeSearchList.innerHTML = buildDashboardEmployeeSearchOptions(employees);
  }
}

function getDashboardEmployeeByCodeValue(employeeCode) {
  const normalizedCode = String(employeeCode || "").trim();
  if (!normalizedCode) {
    return null;
  }

  return dashboardState.employees.find(employee => String(employee.code || "").trim() === normalizedCode) || null;
}

function getDashboardEmployeeSearchText(employee) {
  return [
    employee && employee.name,
    employee && employee.code,
    employee && employee.role,
    getDashboardEmployeeSearchLabel(employee),
  ].map(value => String(value || "").trim().toLowerCase()).filter(Boolean).join(" ");
}

function resolveDashboardEmployeeSearchValue(value) {
  const normalizedValue = String(value || "").trim().toLowerCase();
  if (!normalizedValue) {
    return null;
  }

  const exactMatch = dashboardState.employees.find(employee => {
    const code = String(employee.code || "").trim().toLowerCase();
    const name = String(employee.name || "").trim().toLowerCase();
    const label = getDashboardEmployeeSearchLabel(employee).toLowerCase();
    return normalizedValue === code || normalizedValue === name || normalizedValue === label;
  });
  if (exactMatch) {
    return exactMatch;
  }

  const tokens = normalizedValue.split(/\s+/).filter(Boolean);
  if (tokens.length === 0) {
    return null;
  }

  const matches = dashboardState.employees.filter(employee => {
    const text = getDashboardEmployeeSearchText(employee);
    return tokens.every(token => text.includes(token));
  });

  return matches.length === 1 ? matches[0] : null;
}

function syncDashboardEmployeeSearchInput(employeeCode) {
  const searchInput = document.getElementById("dashboardEmployeeSearchInput");
  if (!searchInput) {
    return;
  }

  const employee = getDashboardEmployeeByCodeValue(employeeCode);
  searchInput.value = employee ? getDashboardEmployeeSearchLabel(employee) : "";
}

function setDashboardSelectedEmployee(employeeCode, options = {}) {
  const normalizedCode = String(employeeCode || "").trim();
  const employeeSelect = document.getElementById("employeeSelect");
  if (employeeSelect) {
    employeeSelect.value = normalizedCode;
  }

  if (normalizedCode) {
    localStorage.setItem("selectedEmployee", normalizedCode);
  } else {
    localStorage.removeItem("selectedEmployee");
  }

  syncDashboardEmployeeSearchInput(normalizedCode);
  if (options.refresh) {
    fetchEmployeeData();
  }
}

function resolveDashboardEmployeeSearchInput(options = {}) {
  const searchInput = document.getElementById("dashboardEmployeeSearchInput");
  const employeeSelect = document.getElementById("employeeSelect");
  if (!searchInput || !employeeSelect) {
    return;
  }

  const rawValue = searchInput.value;
  if (!String(rawValue || "").trim()) {
    if (employeeSelect.value) {
      setDashboardSelectedEmployee("", { refresh: true });
    }
    return;
  }

  const employee = resolveDashboardEmployeeSearchValue(rawValue);
  if (!employee) {
    return;
  }

  const employeeCode = String(employee.code || "").trim();
  if (!employeeCode || employeeSelect.value === employeeCode) {
    if (options.forceSync) {
      syncDashboardEmployeeSearchInput(employeeCode);
    }
    return;
  }

  setDashboardSelectedEmployee(employeeCode, { refresh: true });
}

function scheduleDashboardEmployeeSearchResolve() {
  if (dashboardEmployeeSearchTimer) {
    window.clearTimeout(dashboardEmployeeSearchTimer);
  }

  dashboardEmployeeSearchTimer = window.setTimeout(() => {
    dashboardEmployeeSearchTimer = null;
    resolveDashboardEmployeeSearchInput();
  }, 220);
}

function buildProjectFilterOptions(projects) {
  return buildProjectOptions(projects || [], t("filters.allProjects"), document.getElementById("projectFilter")?.value || "");
}

function isArchivedDashboardProject(project) {
  if (!project) {
    return false;
  }
  const archivedValue = project.archived;
  if (typeof archivedValue === "boolean") {
    return archivedValue;
  }
  if (typeof archivedValue === "number") {
    return archivedValue !== 0;
  }
  const normalizedValue = String(archivedValue || "").trim().toLowerCase();
  return normalizedValue === "true" || normalizedValue === "1" || normalizedValue === "yes";
}

function canModifyDashboardProject(project) {
  return !project || project.canModify !== false;
}

function getDashboardProjectCode(project) {
  return String(project && project.projectCode || "").trim();
}

function sortDashboardProjects(projects) {
  return (Array.isArray(projects) ? projects : [])
    .filter(project => getDashboardProjectCode(project))
    .sort((left, right) => getDashboardProjectCode(left).localeCompare(getDashboardProjectCode(right)));
}

function getDashboardScopedProjects(fallbackProjects = []) {
  const scopedProjects = Array.isArray(dashboardState.projects) ? dashboardState.projects : [];
  return scopedProjects.length > 0 ? scopedProjects : (Array.isArray(fallbackProjects) ? fallbackProjects : []);
}

function getDashboardEntryProjects(fallbackProjects, selectedProjectCode = "") {
  const projects = sortDashboardProjects(getDashboardScopedProjects(fallbackProjects));
  const activeProjects = projects.filter(project => !isArchivedDashboardProject(project));
  const normalizedSelectedProjectCode = String(selectedProjectCode || "").trim();
  if (!normalizedSelectedProjectCode || activeProjects.some(project => getDashboardProjectCode(project) === normalizedSelectedProjectCode)) {
    return activeProjects;
  }

  const selectedProject = projects.find(project => getDashboardProjectCode(project) === normalizedSelectedProjectCode);
  return selectedProject ? activeProjects.concat([selectedProject]) : activeProjects;
}

function getDashboardModifiableEntryProjects(fallbackProjects, selectedProjectCode = "") {
  const projects = getDashboardEntryProjects(fallbackProjects, selectedProjectCode);
  const modifiableProjects = projects.filter(project => canModifyDashboardProject(project));
  const normalizedSelectedProjectCode = String(selectedProjectCode || "").trim();
  if (!normalizedSelectedProjectCode || modifiableProjects.some(project => getDashboardProjectCode(project) === normalizedSelectedProjectCode)) {
    return modifiableProjects;
  }

  const selectedProject = projects.find(project => getDashboardProjectCode(project) === normalizedSelectedProjectCode);
  return selectedProject ? modifiableProjects.concat([selectedProject]) : modifiableProjects;
}

function populateDashboardProjectFilter(projects) {
  const projectFilter = document.getElementById("projectFilter");
  if (!projectFilter) {
    return;
  }

  const previousValue = projectFilter.value || "";
  const projectItems = sortDashboardProjects(projects);
  projectFilter.innerHTML = buildProjectFilterOptions(projectItems);
  if (previousValue && projectItems.some(project => getDashboardProjectCode(project) === previousValue)) {
    projectFilter.value = previousValue;
  }
}

function getDashboardProjectCodeArray(codes) {
  return (Array.isArray(codes) ? codes : [])
    .map(code => String(code || "").trim())
    .filter(Boolean);
}

function getDashboardProjectResponsibility(project) {
  const currentUser = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const employeeCode = String(currentUser && currentUser.employeeCode || "").trim();
  if (!employeeCode) {
    return "";
  }

  if (getDashboardProjectCodeArray(project && project.admins).indexOf(employeeCode) >= 0) {
    return t("dashboard.primaryAdmin");
  }

  if (getDashboardProjectCodeArray(project && project.backupAdmins).indexOf(employeeCode) >= 0) {
    return t("dashboard.backupAdmin");
  }

  return "";
}

function renderDashboardResponsibleProjects() {
  const card = document.getElementById("dashboardProjectScopeCard");
  const container = document.getElementById("dashboardResponsibleProjects");
  const currentUser = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const isAdmin = currentUser && normalizeClientRole(currentUser.role) === "admin";

  if (!card || !container) {
    return;
  }

  card.classList.toggle("d-none", !isAdmin);
  if (!isAdmin) {
    container.innerHTML = "";
    return;
  }

  const responsibleProjects = sortDashboardProjects(dashboardState.projects)
    .map(project => ({
      project,
      responsibility: getDashboardProjectResponsibility(project),
    }))
    .filter(item => item.responsibility);

  if (responsibleProjects.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noResponsibleProjects"));
    return;
  }

  container.innerHTML = responsibleProjects.map(item => {
    const project = item.project;
    const projectCode = getDashboardProjectCode(project);
    const projectName = String(project.projectName || projectCode);
    const sector = String(project.sector || "").trim();
    return `
      <div class="project-scope-pill">
        <span class="inline-code-pill">${escapeHtml(projectCode)}</span>
        <span class="project-scope-name">${escapeHtml(projectName)}</span>
        ${sector ? `<span class="meta-pill">${escapeHtml(sector)}</span>` : ""}
        <span class="meta-pill">${escapeHtml(item.responsibility)}</span>
        ${isArchivedDashboardProject(project) ? `<span class="meta-pill">${escapeHtml(t("projects.archived"))}</span>` : ""}
      </div>
    `;
  }).join("");
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

function getDashboardNotePreview(note) {
  const normalized = String(note || "").trim();
  if (!normalized) {
    return "-";
  }
  if (normalized.length <= 90) {
    return normalized;
  }
  return `${normalized.slice(0, 87).trimEnd()}...`;
}

function openDashboardNoteEditor(noteButton) {
  const modalElement = document.getElementById("dashboardNoteModal");
  if (!modalElement || !noteButton) {
    return;
  }

  document.getElementById("dashboardNoteDate").value = noteButton.getAttribute("data-date") || "";
  document.getElementById("dashboardNotePunchIn").value = noteButton.getAttribute("data-punchin") || "";
  document.getElementById("dashboardNoteInput").value = noteButton.getAttribute("data-message") || "";

  const modal = new bootstrap.Modal(modalElement);
  modal.show();
}

async function saveDashboardNoteFromModal() {
  const employeeCode = document.getElementById("employeeSelect").value;
  if (!employeeCode) {
    showToast(t("dashboard.selectEmployeeBeforeNote"), "info");
    return;
  }

  const date = document.getElementById("dashboardNoteDate").value;
  const punchIn = document.getElementById("dashboardNotePunchIn").value;
  const message = document.getElementById("dashboardNoteInput").value;
  const saveButton = document.getElementById("dashboardSaveNoteBtn");
  saveButton.disabled = true;

  try {
    const response = await fetch(apiUrl + "employee/message/" + employeeCode, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ date, punchIn, message }),
    });
    await parseResponse(response);
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.managerMessageSaved"), "success");
    const modalInstance = bootstrap.Modal.getInstance(document.getElementById("dashboardNoteModal"));
    if (modalInstance) {
      modalInstance.hide();
    }
    await refreshDashboardView();
  } catch (error) {
    console.error("Error updating message:", error);
    showToast(t("dashboard.managerMessageError"), "error");
  } finally {
    saveButton.disabled = false;
  }
}

function renderDashboardApprovalQueue(entries) {
  const container = document.getElementById("dashboardApprovalQueue");
  const queueEntries = entries
    .filter(entry => String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry))
    .sort((left, right) => toEntryDateTime(right) - toEntryDateTime(left));

  document.getElementById("dashboardPendingQueueMeta").textContent = queueEntries.length > 0
    ? `${tn("shared.item", queueEntries.length)} ${t("shared.waiting").toLowerCase()}`
    : t("dashboard.pendingQueueMetaEmpty");

  if (queueEntries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noPending"));
    return;
  }

  container.innerHTML = queueEntries.map(entry => {
    const permissionBadge = getEntryPermissionBadgeMarkup(entry);
    const canReview = !isEntryForgottenClockOut(entry) && canApproveEntry(entry);
    return `
    <article class="queue-card">
      <div class="queue-card-header">
        <div>
          <div class="queue-card-title">${escapeHtml(entry.employeeName)}</div>
          <div class="worklog-secondary">${escapeHtml(formatDateLabel(entry.date))} | ${escapeHtml(formatQueueTitle(entry))}</div>
          ${getEntryExactTimeLabel(entry) ? `<div class="panel-note">${escapeHtml(getEntryExactTimeLabel(entry))}</div>` : ""}
        </div>
        <span class="status-badge ${escapeHtml(getStatusTone(entry))}">${escapeHtml(getEntryStatusLabel(entry))}</span>
      </div>
      <div class="queue-card-meta">
        <span class="inline-code-pill">${escapeHtml(entry.projectCode || t("shared.noProject"))}</span>
        ${entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : ""}
        <span class="meta-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.waitingForPunchOut"))}</span>
      </div>
      ${entry.message ? `<div class="review-card-message">${escapeHtml(entry.message)}</div>` : ""}
      <div class="queue-card-actions">
        ${canReview ? `
          <button type="button" class="btn btn-success btn-sm dashboard-approve-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-check"></i> ${escapeHtml(t("action.approve"))}</button>
          <button type="button" class="btn btn-danger btn-sm dashboard-reject-button" data-entryid="${escapeHtml(entry.entryId || "")}" data-employee-code="${escapeHtml(entry.employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"><i class="fa-solid fa-ban"></i> ${escapeHtml(t("action.reject"))}</button>
        ` : ""}
        ${!canReview ? permissionBadge : ""}
        <button type="button" class="btn btn-outline-secondary btn-sm dashboard-jump-button" data-employee-code="${escapeHtml(entry.employeeCode)}" data-project-code="${escapeHtml(entry.projectCode || "")}">${escapeHtml(t("action.openEmployee"))}</button>
      </div>
    </article>
  `;
  }).join("");
}

function renderDashboardActiveSessions(entries) {
  const container = document.getElementById("dashboardActiveList");
  const activeEntries = entries
    .filter(entry => isEntryOpen(entry))
    .sort((left, right) => toEntryDateTime(right) - toEntryDateTime(left));

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
          <button type="button" class="btn btn-outline-secondary btn-sm dashboard-jump-button" data-employee-code="${escapeHtml(entry.employeeCode)}" data-project-code="${escapeHtml(entry.projectCode || "")}">${escapeHtml(t("action.openEmployee"))}</button>
        </div>
      </article>
    `;
  }).join("");
}

function renderDashboardRecentActivity(entries) {
  const container = document.getElementById("dashboardRecentActivity");
  const recentEntries = Array.isArray(entries) ? entries : (dashboardState.history || []);
  const searchInput = document.getElementById("dashboardRecentSearchInput");
  const searchTerm = String(searchInput && searchInput.value || "").trim().toLowerCase();
  const filteredEntries = searchTerm
    ? recentEntries.filter(entry => {
      const combinedText = getHistorySearchText(entry);
      return searchTerm.split(/\s+/).every(token => combinedText.includes(token));
    })
    : recentEntries;

  if (filteredEntries.length === 0) {
    container.innerHTML = createEmptyState(t("dashboard.noRecentHistory"));
    return;
  }

  container.innerHTML = filteredEntries.map(entry => {
    const actionTone = String(entry.action || "").toLowerCase();
    return `
      <article class="activity-card">
        <div class="review-card-header">
          <div>
            <strong>${escapeHtml(getHistoryAuthorName(entry))}</strong>
            <div class="worklog-secondary">${escapeHtml(formatRelativeTime(entry.timestamp))} | ${escapeHtml(formatDateToWords(String(entry.timestamp || "").split(" ")[0] || ""))}</div>
          </div>
          <span class="action-badge ${escapeHtml(actionTone)}">${escapeHtml(translateHistoryAction(entry.action || "event"))}</span>
        </div>
        ${renderHistorySubjectLine(entry)}
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
  dashboardState.projects = sortDashboardProjects(model.projects || []);

  populateDashboardEmployeeControls(dashboardState.employees);
  populateDashboardProjectFilter(dashboardState.projects);
  renderDashboardResponsibleProjects();

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
    setDashboardSelectedEmployee(desiredEmployee);
  }

  renderDashboardOverview(model);
}

async function fetchEmployees() {
  const response = await fetch(apiUrl + "employees");
  const employees = await parseResponse(response);
  dashboardState.employees = Array.isArray(employees) ? employees : [];
  populateDashboardEmployeeControls(dashboardState.employees);

  const savedEmployee = localStorage.getItem("selectedEmployee");
  if (savedEmployee && dashboardState.employees.some(employee => employee.code === savedEmployee)) {
    setDashboardSelectedEmployee(savedEmployee);
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

  container.innerHTML = `
    <div class="dashboard-table-wrap">
      <table class="table dashboard-entry-table">
        <thead>
          <tr>
            <th scope="col">${escapeHtml(t("dashboard.tableDate"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableWindow"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableProject"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableOvertimeCode"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tablePayment"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableReason"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableDuration"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableStatus"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableManagerNote"))}</th>
            <th scope="col">${escapeHtml(t("dashboard.tableActions"))}</th>
          </tr>
        </thead>
        <tbody>
          ${entries.map(entry => {
            const statusTone = getStatusTone(entry);
            const isOpen = isEntryOpen(entry);
            const isPending = String(entry.status || "pending").toLowerCase() === "pending";
            const needsClockOutReview = isEntryForgottenClockOut(entry);
            const canModify = canModifyEntry(entry);
            const canApprove = canApproveEntry(entry);
            const permissionBadge = getEntryPermissionBadgeMarkup(entry);
            const exactTimeLabel = getEntryExactTimeLabel(entry);
            const entryTypeAttribute = ` data-entrytype="${escapeHtml(getEntryType(entry))}"`;
            const diverseReasonAttribute = ` data-diversereason="${escapeHtml(entry.diverseReason || "")}"`;
            const diverseSummaryAttribute = ` data-diversesummary="${escapeHtml(entry.diverseSummary || "")}"`;
            const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
            const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
            const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
            const statusAttribute = ` data-status="${escapeHtml(entry.status || "pending")}"`;
            const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
            const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
            const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
            const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
            const reviewButtons = isPending && !isOpen && !needsClockOutReview && canApprove ? `
              <button class="btn btn-success btn-sm approve-btn" data-employee-code="${escapeHtml(employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.approve"))}">
                <i class="fa-solid fa-check"></i> ${escapeHtml(t("action.approve"))}
              </button>
              <button class="btn btn-danger btn-sm reject-btn" data-employee-code="${escapeHtml(employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.reject"))}">
                <i class="fa-solid fa-ban"></i> ${escapeHtml(t("action.reject"))}
              </button>
            ` : "";

            return `
              <tr class="dashboard-entry-row${statusTone === "pending" ? " is-pending" : ""}${isOpen ? " is-open" : ""}">
                <td class="dashboard-entry-col-date">
                  <div class="dashboard-table-main">${escapeHtml(formatDateToWords(entry.date))}</div>
                </td>
                <td class="dashboard-entry-col-window">
                  <div class="dashboard-table-main">${escapeHtml(formatQueueTitle(entry))}</div>
                  ${exactTimeLabel ? `<div class="dashboard-table-sub">${escapeHtml(exactTimeLabel)}</div>` : ""}
                </td>
                <td class="dashboard-entry-col-project">
                  <span class="inline-code-pill">${escapeHtml(isDiverseEntry(entry) ? t("shared.diverse") : (entry.projectCode || t("shared.noProject")))}</span>
                </td>
                <td class="dashboard-entry-col-overtime-code">
                  ${!isDiverseEntry(entry) && entry.overtimeCode ? `<span class="meta-pill">${escapeHtml(entry.overtimeCode)}</span>` : `<span class="meta-pill">-</span>`}
                </td>
                <td class="dashboard-entry-col-payment">
                  <span class="meta-pill">${escapeHtml(isDiverseEntry(entry) ? "-" : formatPaymentOptionValue(entry.paymentOption || "cash"))}</span>
                </td>
                <td class="dashboard-entry-col-reason">
                  <span class="meta-pill">${escapeHtml(isDiverseEntry(entry) ? (entry.diverseReason || "-") : (entry.reasonCode || "-"))}</span>
                </td>
                <td class="dashboard-entry-col-duration">
                  <span class="inline-code-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.inProgress"))}</span>
                </td>
                <td class="dashboard-entry-col-status">
                  <span class="status-badge ${escapeHtml(statusTone)}">${escapeHtml(getEntryStatusLabel(entry))}</span>
                </td>
                <td class="dashboard-entry-col-note">
                  ${canModify ? `
                    <button type="button" class="dashboard-note-trigger${entry.message ? "" : " is-empty"}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-message="${escapeHtml(entry.message || "")}" title="${escapeHtml(t("shared.managerMessage"))}">
                      ${escapeHtml(getDashboardNotePreview(entry.message))}
                    </button>
                  ` : `<div class="dashboard-note-trigger is-readonly">${escapeHtml(getDashboardNotePreview(entry.message))}</div>`}
                </td>
                <td class="dashboard-entry-col-actions">
                  <div class="dashboard-entry-actions">
                    ${reviewButtons}
                    ${canModify ? `
                      <button class="btn btn-outline-secondary btn-sm update-button" data-employee-code="${escapeHtml(employeeCode)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-overtime="${escapeHtml(entry.overtime || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${entryTypeAttribute}${diverseReasonAttribute}${diverseSummaryAttribute}${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${statusAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("modal.updateEntry"))}">
                        <i class="fa-solid fa-pen"></i> ${escapeHtml(t("action.edit"))}
                      </button>
                      <button class="btn btn-outline-secondary btn-sm delete-button" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
                        <i class="fa-solid fa-trash"></i> ${escapeHtml(t("action.delete"))}
                      </button>
                    ` : ""}
                    ${permissionBadge}
                  </div>
                </td>
              </tr>
            `;
          }).join("")}
        </tbody>
      </table>
    </div>
  `;
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

async function refreshAfterEntryMutation(employeeCode, refreshPeopleEmployeeCode = "") {
  const affectedViews = ["dashboardView", "employeesView", "adminView", "projectsView"];
  const activeViewId = typeof window.getActiveAppViewId === "function" ? window.getActiveAppViewId() : "";

  if (activeViewId === "employeesView" && refreshPeopleEmployeeCode && typeof window.refreshPeopleEmployeeDetail === "function") {
    await window.refreshPeopleEmployeeDetail(refreshPeopleEmployeeCode);
    if (typeof window.requestAppViewRefresh === "function") {
      await window.requestAppViewRefresh(["dashboardView", "adminView", "projectsView"]);
    } else if (typeof window.markAppViewsStale === "function") {
      window.markAppViewsStale(["dashboardView", "adminView", "projectsView"]);
    }
    return;
  }

  if (typeof window.requestAppViewRefresh === "function") {
    await window.requestAppViewRefresh(affectedViews, { forceActive: true });
    return;
  }

  await refreshDashboardView();
}

window.handleSyncStateChange = function (syncState) {
  const category = String(syncState && syncState.category || "").toLowerCase();
  const resource = String(syncState && syncState.resource || "");

  if (category === "seed") {
    dashboardState.employees = [];
    dashboardState.entriesByEmployee = {};
    dashboardState.history = [];
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
    dashboardState.projects = [];
    if (typeof clearScopedProjectLookupCache === "function") {
      clearScopedProjectLookupCache();
    }
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
    dashboardState.projects = [];
    dashboardState.bootstrap = null;
    if (typeof clearScopedProjectLookupCache === "function") {
      clearScopedProjectLookupCache();
    }
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

async function populateEntryLookups(projectSelectId, overtimeCodeSelectId, selectedProjectCode = "", selectedOvertimeCode = "", paymentSelectId = "", reasonSelectId = "", selectedPaymentOption = "", selectedReasonCode = "") {
  const lookups = await fetchOvertimeEntryLookups();
  if (dashboardState.projects.length === 0) {
    try {
      dashboardState.projects = sortDashboardProjects(await fetchScopedProjects());
      populateDashboardProjectFilter(dashboardState.projects);
      renderDashboardResponsibleProjects();
    } catch (error) {
      console.warn("Unable to load scoped projects for entry modal:", error);
    }
  }
  document.getElementById(projectSelectId).innerHTML = buildProjectOptions(getDashboardModifiableEntryProjects(lookups.projects, selectedProjectCode), t("shared.selectProject"), selectedProjectCode);
  document.getElementById(overtimeCodeSelectId).innerHTML = buildOvertimeCodeOptions(lookups.overtimeCodes, t("shared.selectOvertimeCode"), selectedOvertimeCode);
  if (paymentSelectId) {
    document.getElementById(paymentSelectId).innerHTML = buildPaymentOptionOptions(lookups.paymentOptions, t("shared.selectPaymentOption"), selectedPaymentOption);
  }
  if (reasonSelectId) {
    document.getElementById(reasonSelectId).innerHTML = buildReasonCodeOptions(lookups.reasonCodes, t("shared.selectReasonCode"), selectedReasonCode);
  }
}

function setUpdateEntryModalType(entryType) {
  const normalizedEntryType = String(entryType || "overtime").toLowerCase() === "diverse" ? "diverse" : "overtime";
  document.getElementById("updateEntryType").value = normalizedEntryType;
  document.querySelectorAll(".update-overtime-field").forEach(element => {
    element.classList.toggle("d-none", normalizedEntryType === "diverse");
  });
  document.querySelectorAll(".update-diverse-field").forEach(element => {
    element.classList.toggle("d-none", normalizedEntryType !== "diverse");
  });
}

async function openAddEntryModal(employeeCodeOverride = "") {
  const employeeCode = employeeCodeOverride || document.getElementById("employeeSelect").value;
  if (!employeeCode) {
    showToast(t("dashboard.selectEmployeeBeforeAdd"), "info");
    return;
  }

  document.getElementById("addEntryForm").dataset.employeeCode = employeeCode;
  document.getElementById("addEntryForm").dataset.refreshPeopleEmployee = employeeCodeOverride ? employeeCode : "";
  document.getElementById("addEntryDate").value = new Date().toISOString().slice(0, 10);
  ["addPunchInHours", "addPunchInMinutes", "addPunchOutHours", "addPunchOutMinutes"].forEach(id => {
    document.getElementById(id).value = "";
  });
  await populateEntryLookups("addProjectCode", "addOvertimeCode", "", "", "addPaymentOption", "addReasonCode");
  const addModal = new bootstrap.Modal(document.getElementById("addEntryModal"));
  addModal.show();
}

function openUpdateModal(button) {
  document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = "";
  document.getElementById("updateEntryForm").dataset.employeeCode = button.getAttribute("data-employee-code") || "";
  const date = button.getAttribute("data-date");
  const originalPunchIn = button.getAttribute("data-punchin");
  const currentPunchOut = button.getAttribute("data-punchout");
  const exactPunchIn = button.getAttribute("data-exactpunchin") || originalPunchIn;
  const exactPunchOut = button.getAttribute("data-exactpunchout") || currentPunchOut;
  const projectCode = button.getAttribute("data-projectcode") || "";
  const overtimeCode = button.getAttribute("data-overtimecode") || "";
  const paymentOption = button.getAttribute("data-paymentoption") || "cash";
  const reasonCode = button.getAttribute("data-reasoncode") || "";
  const entryStatus = String(button.getAttribute("data-status") || "pending").toLowerCase();
  const entryType = String(button.getAttribute("data-entrytype") || "overtime").toLowerCase() === "diverse" ? "diverse" : "overtime";
  const diverseReason = button.getAttribute("data-diversereason") || "";
  const diverseSummary = button.getAttribute("data-diversesummary") || "";
  const entryId = button.getAttribute("data-entryid") || "";
  const message = button.getAttribute("data-message") || "";

  document.getElementById("updateDate").value = date;
  document.getElementById("originalPunchIn").value = originalPunchIn;
  document.getElementById("originalPunchOut").value = currentPunchOut;
  document.getElementById("updateEntryId").value = entryId;
  document.getElementById("updateManagerMessage").value = message;
  document.getElementById("updateDiverseReason").value = diverseReason;
  document.getElementById("originalDiverseReason").value = diverseReason;
  document.getElementById("updateDiverseSummary").value = diverseSummary;
  document.getElementById("originalDiverseSummary").value = diverseSummary;
  document.getElementById("updateEntryForm").dataset.originalExactPunchIn = exactPunchIn || "";
  document.getElementById("updateEntryForm").dataset.originalExactPunchOut = exactPunchOut || "";
  setUpdateEntryModalType(entryType);

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

  if (entryType === "diverse") {
    document.getElementById("updateProjectCode").value = "";
    document.getElementById("originalProjectCode").value = "";
    document.getElementById("updateOvertimeCode").value = "";
    document.getElementById("originalOvertimeCode").value = "";
    document.getElementById("updatePaymentOption").value = "";
    document.getElementById("originalPaymentOption").value = "";
    document.getElementById("updateReasonCode").value = "";
    document.getElementById("originalReasonCode").value = "";
    document.getElementById("updateEntryStatus").value = ["approved", "rejected", "pending"].includes(entryStatus) ? entryStatus : "pending";
    document.getElementById("originalEntryStatus").value = document.getElementById("updateEntryStatus").value;
    const updateModal = new bootstrap.Modal(document.getElementById("updateEntryModal"));
    updateModal.show();
    return;
  }

  populateEntryLookups("updateProjectCode", "updateOvertimeCode", projectCode, overtimeCode, "updatePaymentOption", "updateReasonCode", paymentOption, reasonCode).then(() => {
    document.getElementById("updateProjectCode").value = projectCode;
    document.getElementById("originalProjectCode").value = projectCode;
    document.getElementById("updateOvertimeCode").value = overtimeCode;
    document.getElementById("originalOvertimeCode").value = overtimeCode;
    document.getElementById("updatePaymentOption").value = paymentOption;
    document.getElementById("originalPaymentOption").value = paymentOption;
    document.getElementById("updateReasonCode").value = reasonCode;
    document.getElementById("originalReasonCode").value = reasonCode;
    document.getElementById("updateEntryStatus").value = ["approved", "rejected", "pending"].includes(entryStatus) ? entryStatus : "pending";
    document.getElementById("originalEntryStatus").value = document.getElementById("updateEntryStatus").value;
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
    await refreshAfterEntryMutation(employeeCode);
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
    await refreshAfterEntryMutation(employeeCode);
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
    await refreshAfterEntryMutation(employeeCode);
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
    await refreshAfterEntryMutation(employeeCode);
  } catch (error) {
    console.error("Dashboard queue approval error:", error);
    showToast(t("dashboard.genericApprovalError"), "error");
  }
}

function focusDashboardEmployee(employeeCode) {
  setDashboardSelectedEmployee(employeeCode);
  if (typeof showView === "function") {
    showView("dashboardView");
  }
  fetchEmployeeData();
}

window.focusDashboardEmployee = focusDashboardEmployee;

async function openEmployeeFileFromDashboard(employeeCode, projectCode = "") {
  const normalizedEmployeeCode = String(employeeCode || "").trim();
  if (!normalizedEmployeeCode) {
    return;
  }

  setDashboardSelectedEmployee(normalizedEmployeeCode);

  if (typeof window.openPeopleProjectFilter === "function") {
    await window.openPeopleProjectFilter(normalizedEmployeeCode, String(projectCode || "").trim());
    return;
  }

  focusDashboardEmployee(normalizedEmployeeCode);
}

window.openEmployeeFileFromDashboard = openEmployeeFileFromDashboard;

document.getElementById("employeeSelect").addEventListener("change", event => {
  localStorage.setItem("selectedEmployee", event.target.value);
  syncDashboardEmployeeSearchInput(event.target.value);
  fetchEmployeeData();
});
document.getElementById("dashboardEmployeeSearchInput").addEventListener("input", scheduleDashboardEmployeeSearchResolve);
document.getElementById("dashboardEmployeeSearchInput").addEventListener("change", () => {
  resolveDashboardEmployeeSearchInput({ forceSync: true });
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
  const addEntryForm = document.getElementById("addEntryForm");
  const employeeCode = addEntryForm.dataset.employeeCode || document.getElementById("employeeSelect").value;
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
  const paymentOption = document.getElementById("addPaymentOption").value;
  const reasonCode = document.getElementById("addReasonCode").value;

  if (!punchInHours || !punchInMinutes || !punchOutHours || !punchOutMinutes) {
    showToast(t("dashboard.fillAllTimeFields"), "error");
    return;
  }

  if (!projectCode) {
    showToast(t("dashboard.selectProject"), "error");
    return;
  }

  if (!paymentOption) {
    showToast(t("dashboard.selectPaymentOption"), "error");
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
        paymentOption,
        reasonCode,
      }),
    });
    const data = await parseResponse(response);
    bootstrap.Modal.getInstance(document.getElementById("addEntryModal")).hide();
    const refreshPeopleEmployee = addEntryForm.dataset.refreshPeopleEmployee || "";
    addEntryForm.dataset.employeeCode = "";
    addEntryForm.dataset.refreshPeopleEmployee = "";
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryAdded"), "success");
    await refreshAfterEntryMutation(employeeCode, refreshPeopleEmployee);
  } catch (error) {
    console.error("Error adding entry:", error);
    showToast(t("dashboard.entryAddError", { message: error.message }), "error");
  }
});

document.getElementById("saveUpdateBtn").addEventListener("click", async () => {
  const employeeCode = document.getElementById("updateEntryForm").dataset.employeeCode || document.getElementById("employeeSelect").value;
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
  const paymentOption = document.getElementById("updatePaymentOption").value;
  const originalPaymentOption = document.getElementById("originalPaymentOption").value;
  const reasonCode = document.getElementById("updateReasonCode").value;
  const originalReasonCode = document.getElementById("originalReasonCode").value;
  const entryType = document.getElementById("updateEntryType").value || "overtime";
  const diverseReason = document.getElementById("updateDiverseReason").value.trim();
  const originalDiverseReason = document.getElementById("originalDiverseReason").value;
  const diverseSummary = document.getElementById("updateDiverseSummary").value.trim();
  const originalDiverseSummary = document.getElementById("originalDiverseSummary").value;
  const entryStatus = document.getElementById("updateEntryStatus").value;
  const originalEntryStatus = document.getElementById("originalEntryStatus").value || "pending";
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

  if (entryType === "diverse" && !diverseReason) {
    showToast(t("self.diverseReasonRequired"), "error");
    return;
  }

  if (entryType === "diverse" && !diverseSummary) {
    showToast(t("self.diverseSummaryRequired"), "error");
    return;
  }

  if (entryType !== "diverse" && (!projectCode || !paymentOption)) {
    showToast(t("dashboard.projectAndCodeRequired"), "error");
    return;
  }

  if (!managerMessage) {
    showToast(t("dashboard.managerMessageRequired"), "error");
    return;
  }

  if (!["approved", "rejected", "pending"].includes(entryStatus)) {
    showToast(t("dashboard.invalidStatus"), "error");
    return;
  }

  const overtimeFieldsUnchanged = projectCode === originalProjectCode && overtimeCode === originalOvertimeCode && paymentOption === originalPaymentOption && reasonCode === originalReasonCode;
  const diverseFieldsUnchanged = diverseReason === originalDiverseReason && diverseSummary === originalDiverseSummary;
  const typeSpecificFieldsUnchanged = entryType === "diverse" ? diverseFieldsUnchanged : overtimeFieldsUnchanged;
  if (newPunchInBackend === originalExactPunchIn && punchOutBackend === originalExactPunchOut && typeSpecificFieldsUnchanged && entryStatus === originalEntryStatus) {
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
      body: JSON.stringify(entryType === "diverse"
        ? { entryId, entryType, date, originalPunchIn, newPunchIn: newPunchInBackend, punchOut: punchOutBackend, diverseReason, diverseSummary, status: entryStatus, message: managerMessage }
        : { entryId, entryType, date, originalPunchIn, newPunchIn: newPunchInBackend, punchOut: punchOutBackend, projectCode, overtimeCode, paymentOption, reasonCode, status: entryStatus, message: managerMessage }),
    });
    const data = await parseResponse(response);
    const refreshPeopleEmployee = document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee || "";
    bootstrap.Modal.getInstance(document.getElementById("updateEntryModal")).hide();
    document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = "";
    document.getElementById("updateEntryForm").dataset.employeeCode = "";
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    showToast(t("dashboard.entryUpdated"), "success");
    await refreshAfterEntryMutation(employeeCode, refreshPeopleEmployee);
  } catch (error) {
    console.error("Error updating entry:", error);
    showToast(t("dashboard.entryUpdateError", { message: error.message }), "error");
  }
});

document.getElementById("punchClockEntries").addEventListener("click", event => {
  const noteButton = event.target.closest(".dashboard-note-trigger");
  if (noteButton && !noteButton.classList.contains("is-readonly")) {
    openDashboardNoteEditor(noteButton);
    return;
  }

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
    openEmployeeFileFromDashboard(jumpButton.getAttribute("data-employee-code"), jumpButton.getAttribute("data-project-code")).catch(error => {
      console.error("Unable to open employee file:", error);
      showToast(t("employees.loadError"), "error");
    });
  }
});

document.getElementById("dashboardActiveList").addEventListener("click", event => {
  const jumpButton = event.target.closest(".dashboard-jump-button");
  if (jumpButton) {
    openEmployeeFileFromDashboard(jumpButton.getAttribute("data-employee-code"), jumpButton.getAttribute("data-project-code")).catch(error => {
      console.error("Unable to open employee file:", error);
      showToast(t("employees.loadError"), "error");
    });
  }
});

document.getElementById("dashboardSaveNoteBtn").addEventListener("click", saveDashboardNoteFromModal);
document.getElementById("dashboardRecentSearchInput").addEventListener("input", () => {
  renderDashboardRecentActivity(dashboardState.history || []);
});
