const employeesViewState = {
  employees: [],
  selectedEmployeeCode: "",
  selectedProjectCode: "",
  entriesByEmployee: {},
  currentMonthByEmployee: {},
  expandedNotes: {},
  entryLookups: null,
  editorProjectAssignments: {
    projects: [],
    selectedProjectCodes: new Set(),
    originalProjectCodes: new Set(),
    search: "",
  },
};

function canManageEmployeeProfiles() {
  return typeof isSuperAdminUser === "function" && isSuperAdminUser();
}

function getEmployeeRole(employee) {
  return normalizeClientRole(employee && employee.role ? employee.role : "employee");
}

function getEmployeeRoleLabel(employee) {
  return t(`employees.role.${getEmployeeRole(employee)}`);
}

function normalizeEmployeeEditorCodeArray(codes) {
  return (Array.isArray(codes) ? codes : [])
    .map(code => String(code || "").trim())
    .filter(Boolean);
}

function normalizeEmployeeEditorCodeSet(codes) {
  return new Set(normalizeEmployeeEditorCodeArray(codes));
}

function getEmployeeEditorProjectAdmins(project) {
  return normalizeEmployeeEditorCodeArray(project && project.admins ? project.admins : []);
}

function getEmployeeEditorProjectBackupAdmins(project) {
  return normalizeEmployeeEditorCodeArray(project && project.backupAdmins ? project.backupAdmins : []);
}

function getEmployeeEditorProjectCodesForEmployee(employeeCode, projects) {
  const normalizedEmployeeCode = String(employeeCode || "").trim();
  if (!normalizedEmployeeCode) {
    return [];
  }

  return (Array.isArray(projects) ? projects : [])
    .filter(project => getEmployeeEditorProjectAdmins(project).indexOf(normalizedEmployeeCode) >= 0)
    .map(project => String(project.projectCode || "").trim())
    .filter(Boolean)
    .sort();
}

function employeeEditorProjectMatchesSearch(project, searchValue) {
  const normalizedSearch = String(searchValue || "").trim().toLowerCase();
  if (!normalizedSearch) {
    return true;
  }

  const projectCode = String(project && project.projectCode ? project.projectCode : "");
  const projectName = String(project && project.projectName ? project.projectName : "");
  const sector = String(project && project.sector ? project.sector : "");
  return `${projectCode} ${projectName} ${sector}`.toLowerCase().includes(normalizedSearch);
}

function areEmployeeEditorSetsEqual(left, right) {
  if (left.size !== right.size) {
    return false;
  }

  for (const value of left) {
    if (!right.has(value)) {
      return false;
    }
  }

  return true;
}

async function ensureEmployeeEditorProjects(forceRefresh = false) {
  if (!forceRefresh && employeesViewState.editorProjectAssignments.projects.length > 0) {
    return employeesViewState.editorProjectAssignments.projects;
  }

  const projects = await fetchScopedProjects(forceRefresh);
  employeesViewState.editorProjectAssignments.projects = Array.isArray(projects) ? projects : [];
  return employeesViewState.editorProjectAssignments.projects;
}

function getEmployeeEditorSelectedProjectCodesForRole(role) {
  if (normalizeClientRole(role) !== "admin") {
    return [];
  }

  return Array.from(employeesViewState.editorProjectAssignments.selectedProjectCodes).filter(Boolean).sort();
}

function employeeEditorProjectAssignmentsChanged(role) {
  const selectedCodes = normalizeEmployeeEditorCodeSet(getEmployeeEditorSelectedProjectCodesForRole(role));
  return !areEmployeeEditorSetsEqual(selectedCodes, employeesViewState.editorProjectAssignments.originalProjectCodes);
}

function renderEmployeeEditorProjectAssignments() {
  const container = document.getElementById("employeeEditorProjectAssignmentsList");
  if (!container) {
    return;
  }

  const projects = employeesViewState.editorProjectAssignments.projects
    .filter(project => employeeEditorProjectMatchesSearch(project, employeesViewState.editorProjectAssignments.search));

  if (projects.length === 0) {
    container.innerHTML = createEmptyState(t("employees.noMatchingProjects"));
    return;
  }

  container.innerHTML = projects.map(project => {
    const projectCode = String(project.projectCode || "").trim();
    const projectName = String(project.projectName || projectCode);
    const sector = String(project.sector || "").trim();
    const inputId = `employeeEditorProject_${projectCode}`.replace(/[^A-Za-z0-9_-]/g, "_");
    const checked = employeesViewState.editorProjectAssignments.selectedProjectCodes.has(projectCode) ? " checked" : "";
    const meta = sector ? `${projectCode} | ${sector}` : projectCode;
    return `
      <label class="assignment-checkitem" for="${escapeHtml(inputId)}">
        <input class="form-check-input employee-editor-project-checkbox" type="checkbox" id="${escapeHtml(inputId)}" value="${escapeHtml(projectCode)}"${checked}>
        <span class="assignment-checkitem-main">
          <span class="assignment-checkitem-title">${escapeHtml(projectName)}</span>
          <span class="assignment-checkitem-meta">${escapeHtml(meta)}</span>
        </span>
      </label>
    `;
  }).join("");
}

function syncEmployeeEditorProjectAssignmentsPanel() {
  const role = document.getElementById("employeeEditorRoleSelect").value || "employee";
  const panel = document.getElementById("employeeEditorProjectAssignmentsPanel");
  if (!panel) {
    return;
  }

  const showAssignments = normalizeClientRole(role) === "admin";
  panel.classList.toggle("d-none", !showAssignments);
  if (showAssignments) {
    renderEmployeeEditorProjectAssignments();
  }
}

async function saveEmployeeEditorProjectAssignments(employeeCode, role) {
  const normalizedEmployeeCode = String(employeeCode || "").trim();
  if (!normalizedEmployeeCode) {
    return false;
  }

  const selectedCodes = new Set(getEmployeeEditorSelectedProjectCodesForRole(role));
  const projects = await ensureEmployeeEditorProjects(false);
  const updates = [];

  projects.forEach(project => {
    const projectCode = String(project.projectCode || "").trim();
    if (!projectCode) {
      return;
    }

    const currentAdmins = getEmployeeEditorProjectAdmins(project);
    const hasEmployee = currentAdmins.indexOf(normalizedEmployeeCode) >= 0;
    const shouldHaveEmployee = selectedCodes.has(projectCode);
    if (hasEmployee === shouldHaveEmployee) {
      return;
    }

    const nextAdmins = shouldHaveEmployee
      ? Array.from(new Set(currentAdmins.concat([normalizedEmployeeCode]))).sort()
      : currentAdmins.filter(code => code !== normalizedEmployeeCode);

    updates.push({
      project,
      nextAdmins,
    });
  });

  for (const update of updates) {
    const projectCode = String(update.project.projectCode || "").trim();
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(projectCode), {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        projectCode,
        projectName: String(update.project.projectName || projectCode),
        sector: String(update.project.sector || ""),
        admins: update.nextAdmins,
        backupAdmins: getEmployeeEditorProjectBackupAdmins(update.project),
      }),
    });
    await parseResponse(response);
  }

  if (updates.length > 0) {
    employeesViewState.editorProjectAssignments.projects = await fetchScopedProjects(true);
    employeesViewState.editorProjectAssignments.originalProjectCodes = normalizeEmployeeEditorCodeSet(
      getEmployeeEditorProjectCodesForEmployee(normalizedEmployeeCode, employeesViewState.editorProjectAssignments.projects)
    );
  }

  return updates.length > 0;
}

function setEmployeeEditorMessage(message, type) {
  const messageBox = document.getElementById("employeeEditorMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function resetEmployeeEditorForm() {
  document.getElementById("employeeEditorMode").value = "create";
  document.getElementById("employeeEditorModalLabel").textContent = t("employees.addEmployee");
  document.getElementById("employeeEditorOriginalNameInput").value = "";
  document.getElementById("employeeEditorCodeInput").value = "";
  document.getElementById("employeeEditorCodeInput").readOnly = false;
  document.getElementById("employeeEditorNameInput").value = "";
  document.getElementById("employeeEditorRoleSelect").value = "employee";
  employeesViewState.editorProjectAssignments.selectedProjectCodes = new Set();
  employeesViewState.editorProjectAssignments.originalProjectCodes = new Set();
  employeesViewState.editorProjectAssignments.search = "";
  document.getElementById("employeeEditorProjectSearchInput").value = "";
  document.getElementById("employeeEditorProjectAssignmentsList").innerHTML = "";
  document.getElementById("employeeEditorProjectAssignmentsPanel").classList.add("d-none");
  document.getElementById("employeeEditorPasswordInput").value = "";
  document.getElementById("employeeEditorPasswordConfirmInput").value = "";
  document.getElementById("employeeEditorMustChangeInput").checked = true;
  document.getElementById("employeeEditorPasswordHint").textContent = t("employees.passwordHintCreate");
  document.getElementById("employeeEditorRemoveButton").classList.add("d-none");
  document.getElementById("employeeEditorRestoreButton").classList.add("d-none");
  setEmployeeEditorMessage("");
}

async function openEmployeeEditorModal(mode, employee) {
  resetEmployeeEditorForm();
  const projects = await ensureEmployeeEditorProjects(true);

  if (mode === "edit" && employee) {
    document.getElementById("employeeEditorMode").value = "edit";
    document.getElementById("employeeEditorModalLabel").textContent = t("employees.editEmployee");
    document.getElementById("employeeEditorOriginalNameInput").value = employee.name || "";
    document.getElementById("employeeEditorCodeInput").value = employee.code || "";
    document.getElementById("employeeEditorCodeInput").readOnly = true;
    document.getElementById("employeeEditorNameInput").value = employee.name || "";
    document.getElementById("employeeEditorRoleSelect").value = getEmployeeRole(employee);
    document.getElementById("employeeEditorPasswordHint").textContent = t("employees.passwordHintEdit");

    if (employee.archived) {
      document.getElementById("employeeEditorRestoreButton").classList.remove("d-none");
    } else {
      document.getElementById("employeeEditorRemoveButton").classList.remove("d-none");
    }
  }

  const employeeCode = document.getElementById("employeeEditorCodeInput").value.trim();
  const assignedProjectCodes = getEmployeeEditorProjectCodesForEmployee(employeeCode, projects);
  employeesViewState.editorProjectAssignments.selectedProjectCodes = normalizeEmployeeEditorCodeSet(assignedProjectCodes);
  employeesViewState.editorProjectAssignments.originalProjectCodes = normalizeEmployeeEditorCodeSet(assignedProjectCodes);
  syncEmployeeEditorProjectAssignmentsPanel();

  const modal = new bootstrap.Modal(document.getElementById("employeeEditorModal"));
  modal.show();
}

async function submitEmployeeEditor() {
  setEmployeeEditorMessage("");

  const mode = document.getElementById("employeeEditorMode").value;
  const employeeCode = document.getElementById("employeeEditorCodeInput").value.trim();
  const employeeName = document.getElementById("employeeEditorNameInput").value.trim();
  const originalName = document.getElementById("employeeEditorOriginalNameInput").value.trim();
  const role = document.getElementById("employeeEditorRoleSelect").value || "employee";
  const originalEmployee = getEmployeeByCode(employeeCode);
  const originalRole = originalEmployee ? getEmployeeRole(originalEmployee) : "employee";
  const projectAssignmentsChanged = employeeEditorProjectAssignmentsChanged(role);
  const newPassword = document.getElementById("employeeEditorPasswordInput").value;
  const confirmPassword = document.getElementById("employeeEditorPasswordConfirmInput").value;
  const mustChangePassword = document.getElementById("employeeEditorMustChangeInput").checked;
  const hasPasswordChange = Boolean(newPassword || confirmPassword);

  if (!employeeCode || !employeeName) {
    setEmployeeEditorMessage(t("employees.codeAndNameRequired"), "danger");
    return;
  }

  if (hasPasswordChange && newPassword !== confirmPassword) {
    setEmployeeEditorMessage(t("employees.passwordsDoNotMatch"), "danger");
    return;
  }

  if (mode === "create") {
    try {
      const response = await fetch(apiUrl + "employees", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          code: employeeCode,
          name: employeeName,
          role,
          initialPassword: newPassword,
          mustChangePassword,
        }),
      });

      const result = await parseResponse(response);
      if (normalizeClientRole(role) === "admin") {
        await saveEmployeeEditorProjectAssignments(employeeCode, role);
      }
      const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
      if (modal) {
        modal.hide();
      }
      resetEmployeeEditorForm();
      const temporaryPassword = result && result.temporaryPassword ? result.temporaryPassword : newPassword;
      if (temporaryPassword) {
        showToast(t("employees.createdWithPassword", { name: employeeName, password: temporaryPassword }), "success");
      } else {
        showToast(t("employees.employeeCreated"), "success");
      }
      await loadEmployeesView();
    } catch (error) {
      console.error("Error creating employee:", error);
      setEmployeeEditorMessage(error.message || t("employees.createError"), "danger");
    }
    return;
  }

  if (employeeName === originalName && role === originalRole && !hasPasswordChange && !projectAssignmentsChanged) {
    setEmployeeEditorMessage(t("dashboard.noChanges"), "info");
    return;
  }

  try {
    if (employeeName !== originalName || role !== originalRole) {
      const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employeeCode), {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: employeeName,
          role,
        }),
      });

      await parseResponse(response);
    }

    if (hasPasswordChange) {
      const passwordResponse = await fetch(apiUrl + "employee/password/" + encodeURIComponent(employeeCode), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          newPassword,
          mustChangePassword,
        }),
      });

      await parseResponse(passwordResponse);
    }

    if (projectAssignmentsChanged) {
      await saveEmployeeEditorProjectAssignments(employeeCode, role);
    }

    const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
    if (modal) {
      modal.hide();
    }
    resetEmployeeEditorForm();
    let successKey = "employees.employeeUpdated";
    if ((employeeName !== originalName || role !== originalRole) && hasPasswordChange) {
      successKey = "employees.employeeUpdatedAndPassword";
    } else if (hasPasswordChange) {
      successKey = "employees.passwordUpdated";
    }
    showToast(t(successKey), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error updating employee:", error);
    setEmployeeEditorMessage(error.message || t("employees.updateError"), "danger");
  }
}

async function removeEmployee(employee) {
  if (!employee || !employee.code) {
    return;
  }

  const confirmed = window.confirm(t("employees.removeConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code), {
      method: "DELETE",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRemoved"), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error removing employee:", error);
    showToast(error.message || t("employees.removeError"), "error");
  }
}

async function restoreEmployee(employee) {
  if (!employee || !employee.code) {
    return;
  }

  const confirmed = window.confirm(t("employees.restoreConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code) + "/restore", {
      method: "POST",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRestored"), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error restoring employee:", error);
    showToast(error.message || t("employees.restoreError"), "error");
  }
}

function getEmployeeInitials(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return "EM";
  }

  return parts.slice(0, 2).map(part => part[0].toUpperCase()).join("");
}

function isArchivedEmployee(employee) {
  if (!employee) {
    return false;
  }

  const archivedValue = employee.archived;
  if (typeof archivedValue === "boolean") {
    return archivedValue;
  }
  if (typeof archivedValue === "number") {
    return archivedValue !== 0;
  }

  const normalizedValue = String(archivedValue || "").trim().toLowerCase();
  return normalizedValue === "true" || normalizedValue === "1" || normalizedValue === "yes";
}

function filterEmployeesByScope(employees, scope) {
  const source = Array.isArray(employees) ? employees : [];
  if (scope === "archived") {
    return source.filter(employee => isArchivedEmployee(employee));
  }
  if (scope === "active") {
    return source.filter(employee => !isArchivedEmployee(employee));
  }
  return source;
}

function getEmployeeProjectCodes(employee) {
  if (!employee) {
    return [];
  }

  return (Array.isArray(employee.projectCodes) ? employee.projectCodes : [])
    .map(projectCode => String(projectCode || "").trim())
    .filter(Boolean);
}

function employeeMatchesProjectFilter(employee, projectCode) {
  const selectedProjectCode = String(projectCode || "").trim();
  if (!selectedProjectCode) {
    return true;
  }

  return getEmployeeProjectCodes(employee).indexOf(selectedProjectCode) >= 0;
}

function getEmployeesProjectFilterValue() {
  const projectSelect = document.getElementById("employeesProjectSelect");
  return projectSelect ? projectSelect.value : "";
}

function populateEmployeesProjectFilter(projects) {
  const projectSelect = document.getElementById("employeesProjectSelect");
  if (!projectSelect) {
    return;
  }

  const currentValue = projectSelect.value || employeesViewState.selectedProjectCode || "";
  const projectItems = Array.isArray(projects) ? projects : [];
  projectSelect.innerHTML = [`<option value="">${escapeHtml(t("filters.allProjects"))}</option>`]
    .concat(projectItems.map(project => {
      const projectCode = String(project.projectCode || "");
      const projectName = String(project.projectName || projectCode);
      const selected = projectCode === currentValue ? " selected" : "";
      return `<option value="${escapeHtml(projectCode)}"${selected}>${escapeHtml(projectCode)} | ${escapeHtml(projectName)}</option>`;
    }))
    .join("");

  if (currentValue && !projectItems.some(project => String(project.projectCode || "") === currentValue)) {
    projectSelect.insertAdjacentHTML("beforeend", `<option value="${escapeHtml(currentValue)}" selected>${escapeHtml(currentValue)}</option>`);
  }

  employeesViewState.selectedProjectCode = projectSelect.value;
}

function getVisibleEmployeeEntries(employeeCode) {
  const entries = Array.isArray(employeesViewState.entriesByEmployee[employeeCode]) ? employeesViewState.entriesByEmployee[employeeCode] : [];
  const projectCode = String(employeesViewState.selectedProjectCode || "").trim();
  if (!projectCode) {
    return entries;
  }

  return entries.filter(entry => String(entry.projectCode || "") === projectCode);
}

async function fetchEmployeeDetailEntries(employeeCode) {
  const response = await fetch(apiUrl + "employee/" + encodeURIComponent(employeeCode));
  if (response.status === 404) {
    return [];
  }
  const payload = await parseResponse(response);
  return Array.isArray(payload) ? payload : (payload ? [payload] : []);
}

function groupEmployeeEntriesByDate(entries) {
  return (entries || []).reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});
}

function toMonthKey(dateValue) {
  const date = dateValue instanceof Date ? dateValue : parseLocalDate(dateValue);
  if (!date) {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  }
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function shiftMonthKey(monthKey, delta) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const baseDate = new Date(Number.isNaN(year) ? new Date().getFullYear() : year, Number.isNaN(month) ? new Date().getMonth() : month - 1, 1);
  baseDate.setMonth(baseDate.getMonth() + delta);
  return toMonthKey(baseDate);
}

function formatCalendarMonthLabel(monthKey) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const date = new Date(Number.isNaN(year) ? new Date().getFullYear() : year, Number.isNaN(month) ? new Date().getMonth() : month - 1, 1);
  return date.toLocaleDateString(getCurrentLocale(), { month: "long", year: "numeric" });
}

function getCalendarWeekdayLabels() {
  const baseSunday = new Date(2026, 0, 4);
  return Array.from({ length: 7 }, (_, index) => {
    const date = new Date(baseSunday);
    date.setDate(baseSunday.getDate() + index);
    return date.toLocaleDateString(getCurrentLocale(), { weekday: "short" });
  });
}

function getDefaultEmployeeMonthKey(employeeCode, entries) {
  if (employeesViewState.currentMonthByEmployee[employeeCode]) {
    return employeesViewState.currentMonthByEmployee[employeeCode];
  }

  if (Array.isArray(entries) && entries.length > 0) {
    const sortedEntries = [...entries].sort((left, right) => new Date(right.date) - new Date(left.date));
    return toMonthKey(sortedEntries[0].date);
  }

  return toMonthKey(new Date());
}

function getEmployeeEntryKey(employeeCode, entry) {
  return `${employeeCode}__${entry.entryId || ""}__${entry.date || ""}__${entry.punchIn || ""}`;
}

function getEmployeeCalendarEntrySeconds(entry) {
  if (isEntryOpen(entry)) {
    const startedAt = toEntryDateTime(entry);
    return Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
  }
  return timeStringToSeconds(entry && entry.overtime);
}

function buildEmployeeInsightMarkup(entries, monthEntries) {
  const allEntries = Array.isArray(entries) ? entries : [];
  const visibleMonthEntries = Array.isArray(monthEntries) ? monthEntries : [];
  const monthTotalSeconds = visibleMonthEntries.reduce((accumulator, entry) => accumulator + getEmployeeCalendarEntrySeconds(entry), 0);
  const pendingCount = allEntries.filter(entry => String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry)).length;
  const liveCount = allEntries.filter(entry => isEntryOpen(entry)).length;
  const latestEntry = getLatestEntry(allEntries);
  const projectTotals = {};

  allEntries.forEach(entry => {
    const projectCode = String(entry.projectCode || "").trim();
    if (!projectCode) {
      return;
    }
    if (!projectTotals[projectCode]) {
      projectTotals[projectCode] = { code: projectCode, seconds: 0, count: 0 };
    }
    projectTotals[projectCode].seconds += getEmployeeCalendarEntrySeconds(entry);
    projectTotals[projectCode].count += 1;
  });

  const topProject = Object.values(projectTotals).sort((left, right) => {
    if (right.seconds !== left.seconds) {
      return right.seconds - left.seconds;
    }
    return right.count - left.count;
  })[0];

  const lastEntryLabel = latestEntry
    ? `${formatDateLabel(latestEntry.date)} | ${getEntryRoundedTimeRange(latestEntry)}`
    : t("employees.noRecentEntry");

  const topProjectValue = topProject
    ? topProject.code
    : t("shared.noProject");

  const topProjectHint = topProject
    ? `${secondsToDurationLabel(topProject.seconds)} | ${tn("shared.entry", topProject.count)}`
    : t("shared.uncoded");

  const insights = [
    {
      label: t("employees.insightMonth"),
      value: secondsToDurationLabel(monthTotalSeconds),
      hint: tn("shared.entry", visibleMonthEntries.length),
    },
    {
      label: t("employees.insightPending"),
      value: String(pendingCount),
      hint: pendingCount === 1 ? t("status.awaitingApproval") : t("dashboard.waitingForAction"),
    },
    {
      label: t("employees.insightLive"),
      value: String(liveCount),
      hint: liveCount > 0 ? t("dashboard.activeQueueMeta") : t("dashboard.activeQueueMetaEmpty"),
    },
    {
      label: t("employees.insightTopProject"),
      value: topProjectValue,
      hint: topProjectHint,
    },
    {
      label: t("employees.insightLastEntry"),
      value: lastEntryLabel,
      hint: latestEntry ? translateStatus(latestEntry.status || "pending") : t("status.noHistory"),
    },
  ];

  return `
    <div class="employee-insight-strip" aria-label="${escapeHtml(t("employees.insights"))}">
      ${insights.map(insight => `
        <div class="employee-insight-item">
          <span class="employee-insight-label">${escapeHtml(insight.label)}</span>
          <strong class="employee-insight-value">${escapeHtml(insight.value)}</strong>
          <span class="employee-insight-hint">${escapeHtml(insight.hint)}</span>
        </div>
      `).join("")}
    </div>
  `;
}

function getEmployeeStatsStatus(entry) {
  if (isEntryOpen(entry)) {
    return "live";
  }
  return String(entry && entry.status || "pending").toLowerCase();
}

function getTopEmployeeStatsBucket(buckets) {
  return Object.values(buckets).sort((left, right) => {
    if (right.seconds !== left.seconds) {
      return right.seconds - left.seconds;
    }
    return right.count - left.count;
  })[0] || null;
}

function buildEmployeeStatsModel(entries) {
  const sourceEntries = Array.isArray(entries) ? entries : [];
  const projectBuckets = {};
  const overtimeCodeBuckets = {};
  const totals = {
    count: sourceEntries.length,
    seconds: 0,
    approvedSeconds: 0,
    pending: 0,
    rejected: 0,
    live: 0,
    notes: 0,
    maxSeconds: 0,
  };

  sourceEntries.forEach(entry => {
    const seconds = getEmployeeCalendarEntrySeconds(entry);
    const status = getEmployeeStatsStatus(entry);
    const rawProjectCode = String(entry.projectCode || "").trim();
    const projectCode = rawProjectCode || "__NO_PROJECT__";
    const overtimeCode = String(entry.overtimeCode || "").trim() || t("shared.uncoded");

    if (!projectBuckets[projectCode]) {
      projectBuckets[projectCode] = {
        projectCode,
        projectName: rawProjectCode || t("shared.noProject"),
        count: 0,
        seconds: 0,
        approvedSeconds: 0,
        pending: 0,
        rejected: 0,
        live: 0,
        notes: 0,
        maxSeconds: 0,
        latestEntry: null,
        overtimeCodes: {},
      };
    }

    const projectBucket = projectBuckets[projectCode];
    projectBucket.count += 1;
    projectBucket.seconds += seconds;
    projectBucket.maxSeconds = Math.max(projectBucket.maxSeconds, seconds);
    projectBucket.latestEntry = !projectBucket.latestEntry || toEntryDateTime(entry) > toEntryDateTime(projectBucket.latestEntry)
      ? entry
      : projectBucket.latestEntry;

    if (!projectBucket.overtimeCodes[overtimeCode]) {
      projectBucket.overtimeCodes[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
    }
    projectBucket.overtimeCodes[overtimeCode].count += 1;
    projectBucket.overtimeCodes[overtimeCode].seconds += seconds;

    if (!overtimeCodeBuckets[overtimeCode]) {
      overtimeCodeBuckets[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
    }
    overtimeCodeBuckets[overtimeCode].count += 1;
    overtimeCodeBuckets[overtimeCode].seconds += seconds;

    totals.seconds += seconds;
    totals.maxSeconds = Math.max(totals.maxSeconds, seconds);
    if (String(entry.message || "").trim()) {
      totals.notes += 1;
      projectBucket.notes += 1;
    }
    if (status === "approved") {
      totals.approvedSeconds += seconds;
      projectBucket.approvedSeconds += seconds;
    } else if (status === "pending") {
      totals.pending += 1;
      projectBucket.pending += 1;
    } else if (status === "rejected") {
      totals.rejected += 1;
      projectBucket.rejected += 1;
    } else if (status === "live") {
      totals.live += 1;
      projectBucket.live += 1;
    }
  });

  return {
    totals,
    projects: Object.values(projectBuckets).sort((left, right) => right.seconds - left.seconds),
    topOvertimeCode: getTopEmployeeStatsBucket(overtimeCodeBuckets),
  };
}

function buildEmployeeDetailedStatsMarkup(entries) {
  const model = buildEmployeeStatsModel(entries);
  const averageSeconds = model.totals.count > 0 ? Math.round(model.totals.seconds / model.totals.count) : 0;
  const topCodeLabel = model.topOvertimeCode
    ? `${model.topOvertimeCode.code} | ${secondsToDurationLabel(model.topOvertimeCode.seconds)}`
    : t("shared.uncoded");

  const summaryCards = [
    { label: t("self.statsTotal"), value: secondsToDurationLabel(model.totals.seconds), hint: t("self.statsFilteredSummary", { count: model.totals.count, duration: secondsToDurationLabel(model.totals.seconds) }) },
    { label: t("self.statsApproved"), value: secondsToDurationLabel(model.totals.approvedSeconds), hint: t("status.approved") },
    { label: t("self.statsAverage"), value: secondsToDurationLabel(averageSeconds), hint: t("self.statsMax") + " " + secondsToDurationLabel(model.totals.maxSeconds) },
    { label: t("self.statsPendingRejected"), value: `${model.totals.pending} / ${model.totals.rejected}`, hint: `${t("self.statsLive")}: ${model.totals.live}` },
    { label: t("self.statsTopCode"), value: topCodeLabel, hint: `${t("self.statsSupervisorNotes")}: ${model.totals.notes}` },
  ];

  const projectMarkup = model.projects.length === 0
    ? createEmptyState(t("self.statsNoEntries"))
    : `
      <div class="self-project-stat-list">
        ${model.projects.map(project => {
          const average = project.count > 0 ? Math.round(project.seconds / project.count) : 0;
          const topProjectCode = getTopEmployeeStatsBucket(project.overtimeCodes);
          const latestLabel = project.latestEntry
            ? `${formatDateLabel(project.latestEntry.date)} | ${getEntryRoundedTimeRange(project.latestEntry)}`
            : t("employees.noRecentEntry");
          return `
            <article class="self-project-stat-card">
              <div class="self-project-stat-main">
                <div>
                  <div class="self-project-stat-title">${escapeHtml(project.projectCode === "__NO_PROJECT__" ? t("shared.noProject") : project.projectCode)}</div>
                  <div class="worklog-secondary">${escapeHtml(project.projectName || project.projectCode)}</div>
                </div>
                <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(project.seconds))}</span>
              </div>
              <div class="self-project-stat-grid">
                <span><strong>${escapeHtml(String(project.count))}</strong> ${escapeHtml(t("self.statsEntries"))}</span>
                <span><strong>${escapeHtml(secondsToDurationLabel(project.approvedSeconds))}</strong> ${escapeHtml(t("self.statsApproved"))}</span>
                <span><strong>${escapeHtml(String(project.pending))}/${escapeHtml(String(project.rejected))}</strong> ${escapeHtml(t("self.statsPendingRejected"))}</span>
                <span><strong>${escapeHtml(secondsToDurationLabel(average))}</strong> ${escapeHtml(t("self.statsAverage"))}</span>
                <span><strong>${escapeHtml(secondsToDurationLabel(project.maxSeconds))}</strong> ${escapeHtml(t("self.statsMax"))}</span>
                <span><strong>${escapeHtml(topProjectCode ? topProjectCode.code : t("shared.uncoded"))}</strong> ${escapeHtml(t("self.statsTopCode"))}</span>
              </div>
              <div class="self-project-stat-footer">
                <span>${escapeHtml(latestLabel)}</span>
                <span>${escapeHtml(t("self.statsSupervisorNotes"))}: ${escapeHtml(String(project.notes))}</span>
              </div>
            </article>
          `;
        }).join("")}
      </div>
    `;

  return `
    <div class="employee-detail-section employee-stats-section">
      <div class="self-stats-summary">
        ${summaryCards.map(card => `
          <article class="self-stat-card">
            <span class="metric-label">${escapeHtml(card.label)}</span>
            <strong class="metric-value mono">${escapeHtml(card.value)}</strong>
            <span class="metric-hint">${escapeHtml(card.hint)}</span>
          </article>
        `).join("")}
      </div>
      <div class="self-project-stats">
        <div class="self-project-stats-header">
          <span class="panel-kicker">${escapeHtml(t("self.statsProjectBreakdown"))}</span>
          <span class="panel-note">${escapeHtml(t("self.statsFilteredSummary", { count: model.totals.count, duration: secondsToDurationLabel(model.totals.seconds) }))}</span>
        </div>
        ${projectMarkup}
      </div>
    </div>
  `;
}

function buildEmployeeMonthBoard(entries, activeMonthKey) {
  const [activeYear] = String(activeMonthKey || "").split("-").map(Number);
  const year = Number.isNaN(activeYear) ? new Date().getFullYear() : activeYear;
  const monthCounts = {};

  (entries || []).forEach(entry => {
    const monthKey = toMonthKey(entry.date);
    if (!monthKey.startsWith(`${year}-`)) {
      return;
    }
    monthCounts[monthKey] = (monthCounts[monthKey] || 0) + 1;
  });

  return Array.from({ length: 12 }, (_, index) => {
    const monthDate = new Date(year, index, 1);
    const monthKey = toMonthKey(monthDate);
    return {
      monthKey,
      label: monthDate.toLocaleDateString(getCurrentLocale(), { month: "short" }),
      count: monthCounts[monthKey] || 0,
      active: monthKey === activeMonthKey,
    };
  });
}

function setDashboardEmployeeContext(employeeCode) {
  const employeeSelect = document.getElementById("employeeSelect");
  if (employeeSelect) {
    employeeSelect.value = employeeCode || "";
  }
  if (employeeCode) {
    localStorage.setItem("selectedEmployee", employeeCode);
  }
}

async function refreshPeopleEmployeeDetail(employeeCode) {
  if (!employeeCode) {
    return;
  }

  employeesViewState.entriesByEmployee[employeeCode] = undefined;
  if (typeof dashboardState !== "undefined") {
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
  }

  const currentSearchValue = document.getElementById("employeesSearchInput").value;
  const currentScope = document.getElementById("employeesScopeSelect").value || "active";
  employeesViewState.selectedEmployeeCode = employeeCode;

  try {
    const response = await fetch(apiUrl + "employees?scope=all");
    const employees = await parseResponse(response);
    employeesViewState.employees = filterEmployeesByScope(employees, currentScope);
    document.getElementById("employeesSearchInput").value = currentSearchValue;
    applyEmployeeSearchFilter();
    await loadEmployeeDetail(employeeCode);
  } catch (error) {
    console.error("Error refreshing people employee detail:", error);
    showToast(t("employees.loadError"), "error");
  }
}

window.refreshPeopleEmployeeDetail = refreshPeopleEmployeeDetail;

function renderEmployeesDirectory(employees) {
  const container = document.getElementById("employeesDirectoryContainer");
  const detailContainer = document.getElementById("employeeDetailContainer");
  const canManageProfiles = canManageEmployeeProfiles();
  const addButton = document.getElementById("addEmployeeButton");
  if (addButton) {
    addButton.classList.toggle("d-none", !canManageProfiles);
  }
  document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", employees.length);

  if (!employees || employees.length === 0) {
    container.innerHTML = createEmptyState(t("employees.none"));
    detailContainer.innerHTML = "";
    employeesViewState.selectedEmployeeCode = "";
    return;
  }

  if (!employees.some(employee => employee.code === employeesViewState.selectedEmployeeCode)) {
    employeesViewState.selectedEmployeeCode = "";
  }

  container.innerHTML = employees.map(employee => `
    <article class="employee-card${employeesViewState.selectedEmployeeCode === employee.code ? " is-active" : ""}" data-employee-code="${escapeHtml(employee.code)}">
      <div class="employee-card-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-card-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">${escapeHtml(isArchivedEmployee(employee) ? t("employees.archived") : getEmployeeRoleLabel(employee))}</div>
          </div>
        </div>
      </div>
      <div class="employee-card-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(getEmployeeRoleLabel(employee))}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: employee.entryCount || 0 }))}</span>
        ${isArchivedEmployee(employee) ? `<span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span>` : ""}
      </div>
      <div class="employee-card-actions${canManageProfiles ? "" : " d-none"}">
        <button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>
      </div>
    </article>
  `).join("");

  renderEmployeeDetail(getEmployeeByCode(employeesViewState.selectedEmployeeCode));
}

function renderEmployeeDetail(employee) {
  const container = document.getElementById("employeeDetailContainer");
  if (!employee) {
    container.innerHTML = "";
    return;
  }

  const entries = getVisibleEmployeeEntries(employee.code);
  const canManageProfiles = canManageEmployeeProfiles();
  const liveEntries = sortEntriesByDateTime(entries.filter(entry => isEntryOpen(entry)), true);
  const activeMonthKey = getDefaultEmployeeMonthKey(employee.code, entries);
  employeesViewState.currentMonthByEmployee[employee.code] = activeMonthKey;

  const monthEntries = entries.filter(entry => toMonthKey(entry.date) === activeMonthKey);
  const monthTotalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getEmployeeCalendarEntrySeconds(entry), 0);
  const employeeInsightsMarkup = buildEmployeeInsightMarkup(entries, monthEntries);
  const employeeDetailedStatsMarkup = buildEmployeeDetailedStatsMarkup(entries);
  const monthBoard = buildEmployeeMonthBoard(entries, activeMonthKey);
  const groupedEntries = groupEmployeeEntriesByDate(monthEntries);
  const [activeYear, activeMonth] = activeMonthKey.split("-").map(Number);
  const firstDayOfMonth = new Date(activeYear, activeMonth - 1, 1);
  const lastDayOfMonth = new Date(activeYear, activeMonth, 0);
  const gridStart = new Date(firstDayOfMonth);
  gridStart.setDate(firstDayOfMonth.getDate() - firstDayOfMonth.getDay());
  const gridEnd = new Date(lastDayOfMonth);
  gridEnd.setDate(lastDayOfMonth.getDate() + (6 - lastDayOfMonth.getDay()));
  const dayCells = [];
  const rollingDate = new Date(gridStart);

  while (rollingDate <= gridEnd) {
    const dateKey = `${rollingDate.getFullYear()}-${String(rollingDate.getMonth() + 1).padStart(2, "0")}-${String(rollingDate.getDate()).padStart(2, "0")}`;
    const dayEntries = groupedEntries[dateKey] || [];
    const isCurrentMonth = rollingDate.getMonth() === (activeMonth - 1);
    const totalDaySeconds = dayEntries.reduce((accumulator, entry) => accumulator + getEmployeeCalendarEntrySeconds(entry), 0);
    const entryPreview = dayEntries.map(entry => {
      const statusTone = getStatusTone(entry);
      const entryKey = getEmployeeEntryKey(employee.code, entry);
      const note = String(entry.message || "").trim();
      const showOverflowToggle = note.length > 120;
      const isExpanded = Boolean(employeesViewState.expandedNotes[entryKey]);
      const noteMarkup = note
        ? `
          <div class="calendar-entry-note${isExpanded ? " is-expanded" : ""}">
            <div class="calendar-entry-note-label">${escapeHtml(t("employees.managerNoteLabel"))}</div>
            <div class="calendar-entry-note-text">${escapeHtml(note)}</div>
            ${showOverflowToggle ? `<button type="button" class="calendar-note-toggle" data-note-key="${escapeHtml(entryKey)}">${escapeHtml(t(isExpanded ? "action.less" : "action.more"))}</button>` : ""}
          </div>
        `
        : "";

      const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
      const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
      const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
      const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
      const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
      const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
      const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
      const reviewButtons = String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry) && !isEntryForgottenClockOut(entry)
        ? `
          <button type="button" class="btn btn-success btn-sm action-btn calendar-entry-action-btn calendar-review-btn people-calendar-approve" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.approve"))}">
            <i class="fa-solid fa-check"></i>
          </button>
          <button type="button" class="btn btn-danger btn-sm action-btn calendar-entry-action-btn calendar-review-btn people-calendar-reject" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.reject"))}">
            <i class="fa-solid fa-ban"></i>
          </button>
        `
        : "";

      return `
        <div class="calendar-entry">
          <div class="calendar-entry-main">
            <span class="calendar-entry-time">${getEntryRoundedTimeRangeMarkup(entry)}</span>
            <span class="status-badge ${escapeHtml(statusTone)}">${escapeHtml(getEntryStatusLabel(entry))}</span>
          </div>
          <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
          ${noteMarkup}
          ${reviewButtons ? `<div class="calendar-entry-actions calendar-entry-actions-review">${reviewButtons}</div>` : ""}
          <div class="calendar-entry-actions calendar-entry-actions-manage">
            <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
              <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
            </button>
            <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
              <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
            </button>
          </div>
        </div>
      `;
    }).join("");

    dayCells.push(`
      <div class="calendar-day${isCurrentMonth ? "" : " is-muted"}${dayEntries.length > 0 ? " has-entries" : ""}">
        <div class="calendar-day-header">
          <span class="calendar-day-number">${rollingDate.getDate()}</span>
          ${dayEntries.length > 0 ? `<span class="calendar-day-total">${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>` : ""}
        </div>
        <div class="calendar-day-body">
          ${entryPreview}
        </div>
      </div>
    `);

    rollingDate.setDate(rollingDate.getDate() + 1);
  }

  const liveEntriesMarkup = liveEntries.length > 0
    ? `
      <div class="calendar-live-strip">
        ${liveEntries.map(entry => {
          const elapsedSeconds = getEmployeeCalendarEntrySeconds(entry);
          const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
          const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
          const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
          const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
          const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
          const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
          const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
          return `
            <article class="calendar-live-card">
              <div class="calendar-entry-main">
                <span class="calendar-entry-time">${escapeHtml(formatDateLabel(entry.date))} | ${buildTimeRangeMarkup(formatTimeString(getEntryExactPunchIn(entry)), t("shared.inProgress"))}</span>
                <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
              </div>
              <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
              <div class="calendar-entry-actions calendar-entry-actions-manage">
                <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
                  <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
                </button>
                <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
                  <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
                </button>
                <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(elapsedSeconds))}</span>
              </div>
            </article>
          `;
        }).join("")}
      </div>
    `
    : "";
  const calendarMarkup = monthEntries.length > 0
    ? `
      <div class="employee-calendar-header">
        <div class="employee-calendar-nav">
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="prev" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-left"></i>
          </button>
          <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="next" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-right"></i>
          </button>
        </div>
        <div class="employee-calendar-actions">
          <div class="employee-calendar-summary">${escapeHtml(t("employees.calendarSummary", { count: monthEntries.length, duration: secondsToDurationLabel(monthTotalSeconds) }))}</div>
          <button type="button" class="btn btn-outline-secondary btn-sm people-export-month-button" data-employee-code="${escapeHtml(employee.code)}" data-export-month="${escapeHtml(activeMonthKey)}">
            <i class="fa-solid fa-arrow-up-right-from-square"></i> ${escapeHtml(t("export.openMonthlyHtml"))}
          </button>
        </div>
      </div>
      <div class="employee-month-board-shell">
        <div class="employee-month-board">
          ${monthBoard.map(month => `
            <button type="button" class="employee-month-chip${month.active ? " is-active" : ""}${month.count > 0 ? " has-entries" : ""}" data-month-key="${escapeHtml(month.monthKey)}" data-employee-code="${escapeHtml(employee.code)}">
              <span class="employee-month-chip-label">${escapeHtml(month.label)}</span>
              <span class="employee-month-chip-count">${escapeHtml(String(month.count))}</span>
            </button>
          `).join("")}
        </div>
      </div>
      ${liveEntriesMarkup}
      <div class="employee-calendar-grid">
        ${getCalendarWeekdayLabels().map(label => `<div class="calendar-weekday">${escapeHtml(label)}</div>`).join("")}
        ${dayCells.join("")}
      </div>
    `
    : `
      <div class="employee-calendar-header">
        <div class="employee-calendar-nav">
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="prev" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-left"></i>
          </button>
          <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="next" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-right"></i>
          </button>
        </div>
        <div class="employee-calendar-actions">
          <button type="button" class="btn btn-outline-secondary btn-sm people-export-month-button" data-employee-code="${escapeHtml(employee.code)}" data-export-month="${escapeHtml(activeMonthKey)}">
            <i class="fa-solid fa-arrow-up-right-from-square"></i> ${escapeHtml(t("export.openMonthlyHtml"))}
          </button>
        </div>
      </div>
      <div class="employee-month-board-shell">
        <div class="employee-month-board">
          ${monthBoard.map(month => `
            <button type="button" class="employee-month-chip${month.active ? " is-active" : ""}${month.count > 0 ? " has-entries" : ""}" data-month-key="${escapeHtml(month.monthKey)}" data-employee-code="${escapeHtml(employee.code)}">
              <span class="employee-month-chip-label">${escapeHtml(month.label)}</span>
              <span class="employee-month-chip-count">${escapeHtml(String(month.count))}</span>
            </button>
          `).join("")}
        </div>
      </div>
      ${liveEntriesMarkup}
      ${createEmptyState(t("employees.noEntriesForMonth"))}
    `;

  container.innerHTML = `
    <section class="panel-shell employee-detail-card">
      <div class="employee-detail-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar employee-avatar-large">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-detail-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">${escapeHtml(isArchivedEmployee(employee) ? t("employees.archived") : getEmployeeRoleLabel(employee))}</div>
          </div>
        </div>
        <div class="employee-detail-actions">
          ${isArchivedEmployee(employee) ? "" : `<button type="button" class="btn btn-primary btn-sm people-add-entry-button" data-employee-code="${escapeHtml(employee.code)}"><i class="fa-solid fa-plus"></i> ${escapeHtml(t("dashboard.addEntry"))}</button>`}
          ${canManageProfiles ? `<button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>` : ""}
        </div>
      </div>
      <div class="employee-detail-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(getEmployeeRoleLabel(employee))}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: entries.length }))}</span>
        ${employeesViewState.selectedProjectCode ? `<span class="meta-pill">${escapeHtml(employeesViewState.selectedProjectCode)}</span>` : ""}
        ${isArchivedEmployee(employee) ? `<span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span>` : `<span class="status-badge approved">${escapeHtml(t("employees.scopeActive"))}</span>`}
      </div>
      ${employeeInsightsMarkup}
      ${employeeDetailedStatsMarkup}
      <div class="employee-detail-section">
        <div class="panel-kicker">${escapeHtml(t("employees.calendar"))}</div>
        <div class="employee-detail-entries">
          ${calendarMarkup}
        </div>
      </div>
    </section>
  `;
}

async function loadEmployeeDetail(employeeCode) {
  const employee = getEmployeeByCode(employeeCode);
  const container = document.getElementById("employeeDetailContainer");
  if (!employee || !container) {
    return;
  }

  if (employeesViewState.entriesByEmployee[employeeCode]) {
    renderEmployeeDetail(employee);
    return;
  }

  setLoadingState("employeeDetailContainer", "detail", 1);

  try {
    const entries = await fetchEmployeeDetailEntries(employeeCode);
    employeesViewState.entriesByEmployee[employeeCode] = Array.isArray(entries) ? entries : [];
    renderEmployeeDetail(employee);
  } catch (error) {
    console.error("Error loading employee detail entries:", error);
    container.innerHTML = createEmptyState(t("dashboard.timelineLoadError"));
  }
}

function applyEmployeeSearchFilter() {
  const searchValue = document.getElementById("employeesSearchInput").value.trim().toLowerCase();
  const projectCode = getEmployeesProjectFilterValue();
  employeesViewState.selectedProjectCode = projectCode;

  const filteredEmployees = employeesViewState.employees.filter(employee => {
    const haystack = `${employee.name} ${employee.code}`.toLowerCase();
    const matchesSearch = !searchValue || haystack.includes(searchValue);
    return matchesSearch && employeeMatchesProjectFilter(employee, projectCode);
  });
  renderEmployeesDirectory(filteredEmployees);
}

function loadEmployeesView() {
  setLoadingState("employeesDirectoryContainer", "grid", 4);
  document.getElementById("employeeDetailContainer").innerHTML = "";
  const scope = document.getElementById("employeesScopeSelect").value || "active";
  return Promise.all([
    fetch(apiUrl + "employees?scope=all").then(parseResponse),
    fetchOvertimeEntryLookups().catch(error => {
      console.warn("Unable to preload entry lookups for employee exports:", error);
      return null;
    }),
    fetchScopedProjects().catch(error => {
      console.warn("Unable to load scoped projects for employees view:", error);
      return [];
    }),
  ])
    .then(([employees, lookups, scopedProjects]) => {
      const projectItems = Array.isArray(scopedProjects) ? scopedProjects : [];
      if (lookups) {
        employeesViewState.entryLookups = {
          ...lookups,
          projects: projectItems,
        };
      }
      populateEmployeesProjectFilter(projectItems);
      employeesViewState.employees = filterEmployeesByScope(employees, scope);
      applyEmployeeSearchFilter();
    })
    .catch(error => {
      console.error("Error loading employees view:", error);
      showToast(t("employees.loadError"), "error");
    });
}

function getEmployeeByCode(employeeCode) {
  return employeesViewState.employees.find(employee => employee.code === employeeCode) || null;
}

async function openPeopleProjectFilter(employeeCode, projectCode) {
  if (typeof showView === "function") {
    showView("employeesView");
  }

  employeesViewState.selectedEmployeeCode = employeeCode || "";
  employeesViewState.selectedProjectCode = projectCode || "";
  const projectSelect = document.getElementById("employeesProjectSelect");
  if (projectSelect) {
    projectSelect.value = projectCode || "";
  }
  const searchInput = document.getElementById("employeesSearchInput");
  if (searchInput) {
    searchInput.value = "";
  }

  await loadEmployeesView();
  if (employeeCode) {
    employeesViewState.selectedEmployeeCode = employeeCode;
    applyEmployeeSearchFilter();
    await loadEmployeeDetail(employeeCode);
  }
}

window.openPeopleProjectFilter = openPeopleProjectFilter;

document.getElementById("employeesDirectoryContainer").addEventListener("click", event => {
  const editButton = event.target.closest(".employee-edit-button");
  if (editButton) {
    const employee = getEmployeeByCode(editButton.getAttribute("data-employee-code"));
    if (employee) {
      openEmployeeEditorModal("edit", employee).catch(error => {
        console.error("Unable to open employee editor:", error);
        showToast(t("employees.loadError"), "error");
      });
    }
    return;
  }
  const employeeCard = event.target.closest(".employee-card");
  if (!employeeCard) {
    return;
  }

  const employeeCode = employeeCard.getAttribute("data-employee-code");
  if (!employeeCode) {
    return;
  }

  employeesViewState.selectedEmployeeCode = employeeCode;
  applyEmployeeSearchFilter();
  loadEmployeeDetail(employeeCode);
});

document.getElementById("employeeDetailContainer").addEventListener("click", async event => {
  const exportButton = event.target.closest(".people-export-month-button");
  if (exportButton) {
    const employeeCode = exportButton.getAttribute("data-employee-code");
    const employee = getEmployeeByCode(employeeCode);
    const entries = getVisibleEmployeeEntries(employeeCode);
    openMonthlyEntriesExportHtml({
      entries,
      monthKey: exportButton.getAttribute("data-export-month") || employeesViewState.currentMonthByEmployee[employeeCode],
      employeeName: employee && employee.name ? employee.name : t("shared.employee"),
      employeeCode,
      lookups: employeesViewState.entryLookups || {},
    });
    return;
  }

  const yearButton = event.target.closest(".employee-calendar-year-button");
  if (yearButton) {
    const employeeCode = yearButton.getAttribute("data-employee-code");
    const direction = yearButton.getAttribute("data-calendar-year-nav");
    if (employeeCode && direction) {
      const currentMonthKey = employeesViewState.currentMonthByEmployee[employeeCode] || toMonthKey(new Date());
      employeesViewState.currentMonthByEmployee[employeeCode] = shiftMonthKey(currentMonthKey, direction === "prev" ? -12 : 12);
      renderEmployeeDetail(getEmployeeByCode(employeeCode));
    }
    return;
  }

  const monthChip = event.target.closest(".employee-month-chip");
  if (monthChip) {
    const employeeCode = monthChip.getAttribute("data-employee-code");
    const monthKey = monthChip.getAttribute("data-month-key");
    if (employeeCode && monthKey) {
      employeesViewState.currentMonthByEmployee[employeeCode] = monthKey;
      renderEmployeeDetail(getEmployeeByCode(employeeCode));
    }
    return;
  }

  const noteToggle = event.target.closest(".calendar-note-toggle");
  if (noteToggle) {
    const noteKey = noteToggle.getAttribute("data-note-key");
    if (noteKey) {
      employeesViewState.expandedNotes[noteKey] = !employeesViewState.expandedNotes[noteKey];
      renderEmployeeDetail(getEmployeeByCode(employeesViewState.selectedEmployeeCode));
    }
    return;
  }

  const approveButton = event.target.closest(".people-calendar-approve");
  if (approveButton) {
    const employeeCode = approveButton.getAttribute("data-employee-code");
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: approveButton.getAttribute("data-entryid") || "",
            date: approveButton.getAttribute("data-date"),
            punchIn: approveButton.getAttribute("data-punchin"),
            status: "approved",
            message: "",
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryUpdated"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error approving entry from calendar:", error);
        showToast(t("dashboard.approvalError", { message: error.message }), "error");
      }
    }
    return;
  }

  const rejectButton = event.target.closest(".people-calendar-reject");
  if (rejectButton) {
    const employeeCode = rejectButton.getAttribute("data-employee-code");
    const managerMessage = window.prompt(t("dashboard.rejectManagerMessagePrompt"), "");
    if (managerMessage === null) {
      return;
    }
    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: rejectButton.getAttribute("data-entryid") || "",
            date: rejectButton.getAttribute("data-date"),
            punchIn: rejectButton.getAttribute("data-punchin"),
            status: "rejected",
            message: managerMessage.trim(),
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryUpdated"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error rejecting entry from calendar:", error);
        showToast(t("dashboard.approvalError", { message: error.message }), "error");
      }
    }
    return;
  }

  const deleteButton = event.target.closest(".people-calendar-delete");
  if (deleteButton) {
    const employeeCode = deleteButton.getAttribute("data-employee-code");
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
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/" + employeeCode, {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: deleteButton.getAttribute("data-entryid") || "",
            date: deleteButton.getAttribute("data-date"),
            punchIn: deleteButton.getAttribute("data-punchin"),
            message: managerMessage.trim(),
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryDeleted"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error deleting entry from calendar:", error);
        showToast(t("dashboard.entryDeleteError", { message: error.message }), "error");
      }
    }
    return;
  }

  const editButton = event.target.closest(".employee-edit-button");
  if (editButton) {
    const employee = getEmployeeByCode(editButton.getAttribute("data-employee-code"));
    if (employee) {
      openEmployeeEditorModal("edit", employee).catch(error => {
        console.error("Unable to open employee editor:", error);
        showToast(t("employees.loadError"), "error");
      });
    }
    return;
  }

  const addEntryButton = event.target.closest(".people-add-entry-button");
  if (addEntryButton) {
    const employeeCode = addEntryButton.getAttribute("data-employee-code");
    if (employeeCode && typeof openAddEntryModal === "function") {
      employeesViewState.selectedEmployeeCode = employeeCode;
      setDashboardEmployeeContext(employeeCode);
      await openAddEntryModal(employeeCode);
    }
    return;
  }

  const entryEditButton = event.target.closest(".people-calendar-edit");
  if (entryEditButton) {
    const employeeCode = entryEditButton.getAttribute("data-employee-code");
    if (employeeCode) {
      setDashboardEmployeeContext(employeeCode);
      if (typeof openUpdateModal === "function") {
        openUpdateModal(entryEditButton);
        document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = employeeCode;
      }
    }
  }
});

document.getElementById("addEmployeeButton").addEventListener("click", () => {
  openEmployeeEditorModal("create").catch(error => {
    console.error("Unable to open employee editor:", error);
    showToast(t("employees.loadError"), "error");
  });
});
document.getElementById("employeeEditorRemoveButton").addEventListener("click", async () => {
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
  if (modal) {
    modal.hide();
  }
  await removeEmployee(employee);
});
document.getElementById("employeeEditorRestoreButton").addEventListener("click", async () => {
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
  if (modal) {
    modal.hide();
  }
  await restoreEmployee(employee);
});
document.getElementById("employeeEditorSaveButton").addEventListener("click", submitEmployeeEditor);
document.getElementById("employeeEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  submitEmployeeEditor();
});
document.getElementById("employeeEditorRoleSelect").addEventListener("change", syncEmployeeEditorProjectAssignmentsPanel);
document.getElementById("employeeEditorProjectSearchInput").addEventListener("input", event => {
  employeesViewState.editorProjectAssignments.search = event.target.value || "";
  renderEmployeeEditorProjectAssignments();
});
document.getElementById("employeeEditorProjectAssignmentsList").addEventListener("change", event => {
  const checkbox = event.target.closest(".employee-editor-project-checkbox");
  if (!checkbox) {
    return;
  }

  const projectCode = String(checkbox.value || "").trim();
  if (!projectCode) {
    return;
  }

  if (checkbox.checked) {
    employeesViewState.editorProjectAssignments.selectedProjectCodes.add(projectCode);
  } else {
    employeesViewState.editorProjectAssignments.selectedProjectCodes.delete(projectCode);
  }
});
document.getElementById("employeesSearchInput").addEventListener("input", applyEmployeeSearchFilter);
document.getElementById("employeesScopeSelect").addEventListener("change", loadEmployeesView);
document.getElementById("employeesProjectSelect").addEventListener("change", () => {
  employeesViewState.selectedProjectCode = getEmployeesProjectFilterValue();
  applyEmployeeSearchFilter();
});
document.getElementById("employeesResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("employeesSearchInput").value = "";
  document.getElementById("employeesScopeSelect").value = "active";
  document.getElementById("employeesProjectSelect").value = "";
  employeesViewState.selectedProjectCode = "";
  loadEmployeesView();
});
document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", 0);
