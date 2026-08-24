const employeesViewState = {
  allEmployees: [],
  employees: [],
  filteredEmployees: [],
  selectedEmployeeCode: "",
  selectedProjectCode: "",
  autoOpenProjectCode: "",
  focusEntryId: "",
  entriesByEmployee: {},
  currentMonthByEmployee: {},
  entryLookups: null,
  projectSearchTextByCode: {},
  employeeFilterTimerId: null,
  employeeAnalyticsSignature: "",
  gc179Import: {
    fdfContent: "",
    fileName: "",
    preview: null,
    selectedSourceRows: new Set(),
    identityConfirmed: false,
    warningsConfirmed: false,
    lastImportResult: null,
  },
  editorProjectAssignments: {
    projects: [],
    selectedProjectCodes: new Set(),
    originalProjectCodes: new Set(),
    search: "",
  },
};
let pendingEmployeeAnalyticsFrameId = null;
const employeeAnalyticsChartInstances = {};
const employeeAnalyticsPalette = ["#0868d7", "#16865a", "#7558d8", "#008994", "#c27a00", "#c43840", "#c94f8a", "#4f72d8", "#7f6b52", "#0f8f7a"];
window.invalidateEmployeesViewEntryCache = function (resource) {
  const employeeCode = String(resource || "").trim();
  if (!employeeCode || employeeCode === "*") {
    employeesViewState.entriesByEmployee = {};
    employeesViewState.currentMonthByEmployee = {};
  } else {
    employeesViewState.entriesByEmployee[employeeCode] = undefined;
    employeesViewState.currentMonthByEmployee[employeeCode] = undefined;
  }
  employeesViewState.employeeAnalyticsSignature = "";
};

function canManageEmployeeProfiles() {
  return typeof isSuperAdminUser === "function" && isSuperAdminUser();
}

function getCurrentUserEmployeeCode() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  return user && user.employeeCode ? String(user.employeeCode).trim() : "";
}

function isCurrentUserEmployeeCode(employeeCode) {
  const currentEmployeeCode = getCurrentUserEmployeeCode();
  return Boolean(currentEmployeeCode && String(employeeCode || "").trim() === currentEmployeeCode);
}

function getEmployeeRole(employee) {
  return normalizeClientRole(employee && employee.role ? employee.role : "employee");
}

function getEmployeeTimeEntryTypes(employee) {
  const values = Array.isArray(employee && employee.timeEntryTypes) ? employee.timeEntryTypes : ["overtime"];
  const normalized = values
    .map(value => String(value || "").trim().toLowerCase())
    .map(value => value === "diverse" ? "diverse" : value === "overtime" ? "overtime" : "")
    .filter(Boolean);
  return normalized.length > 0 ? Array.from(new Set(normalized)).sort() : ["overtime"];
}

function getEmployeeEditorSelectedTimeEntryTypes() {
  const selected = Array.from(document.querySelectorAll(".employee-time-entry-type-checkbox:checked"))
    .map(input => String(input.value || "").trim().toLowerCase())
    .filter(Boolean);
  return selected.length > 0 ? Array.from(new Set(selected)).sort() : ["overtime"];
}

function setEmployeeEditorTimeEntryTypes(timeEntryTypes) {
  const selected = new Set(Array.isArray(timeEntryTypes) && timeEntryTypes.length > 0 ? timeEntryTypes : ["overtime"]);
  document.querySelectorAll(".employee-time-entry-type-checkbox").forEach(input => {
    input.checked = selected.has(String(input.value || "").trim().toLowerCase());
  });
  if (!document.querySelector(".employee-time-entry-type-checkbox:checked")) {
    document.getElementById("employeeEditorTimeTypeOvertime").checked = true;
  }
}

function employeeEditorTimeEntryTypesChanged(employee) {
  const original = getEmployeeTimeEntryTypes(employee);
  const selected = getEmployeeEditorSelectedTimeEntryTypes();
  return original.join("|") !== selected.join("|");
}

function toGc179UpperText(value) {
  const text = String(value || "").trim();
  return text ? text.toUpperCase() : "";
}

function inferEmployeeGc179NameParts(employeeName) {
  const tokens = String(employeeName || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  if (tokens.length === 0) {
    return {
      surname: "",
      givenName: "",
      initials: "",
    };
  }

  const surname = tokens.length === 1 ? tokens[0] : tokens[tokens.length - 1];
  const givenName = tokens.length === 1 ? "" : tokens.slice(0, -1).join(" ");
  const initialParts = [];
  if (givenName) {
    initialParts.push(givenName.charAt(0).toUpperCase());
  }
  if (surname) {
    initialParts.push(surname.charAt(0).toUpperCase());
  }

  return {
    surname: toGc179UpperText(surname),
    givenName: toGc179UpperText(givenName),
    initials: initialParts.join("."),
  };
}

function normalizeEmployeeGc179Profile(profile, employeeName) {
  const fallback = inferEmployeeGc179NameParts(employeeName);
  const source = profile && typeof profile === "object" ? profile : {};
  const groupPropertyNames = ["group", "Group", "groupe", "Groupe"];
  const subGroupPropertyNames = ["subGroup", "SubGroup", "subgroup", "SousGroupe", "sousGroupe"];
  const hasExplicitGroup = hasAnyOwnProperty(source, groupPropertyNames);
  const hasExplicitSubGroup = hasAnyOwnProperty(source, subGroupPropertyNames);
  const group = getFirstNonEmptyPropertyValue(source, [
    ...groupPropertyNames,
    "position",
    "Position",
    "poste",
    "Poste",
    "classification",
    "Classification",
  ]);
  let subGroup = getFirstNonEmptyPropertyValue(source, subGroupPropertyNames);
  if (!subGroup && !hasExplicitGroup && !hasExplicitSubGroup) {
    subGroup = getFirstNonEmptyPropertyValue(source, ["echelon", "Echelon", "level", "Level"]);
  }
  const level = hasExplicitGroup || hasExplicitSubGroup
    ? getFirstNonEmptyPropertyValue(source, ["level", "Level", "niveau", "Niveau"])
    : "";

  return {
    surname: toGc179UpperText(source.surname || source.Surname || source.lastName || fallback.surname),
    givenName: toGc179UpperText(source.givenName || source.given || source.Given || fallback.givenName),
    initials: toGc179UpperText(source.initials || source.Initials || fallback.initials),
    pri: formatGc179Pri(source.pri || source.PRI || ""),
    group: normalizeGc179Group(group),
    subGroup: normalizeGc179SubGroup(subGroup),
    level: normalizeGc179Level(level),
    compressedWorkWeek: normalizeBooleanValue(getFirstDefinedPropertyValue(source, ["compressedWorkWeek", "isCompressedWorkWeek", "compressed"]), false),
  };
}

function getEmployeeGc179Profile(employee) {
  return normalizeEmployeeGc179Profile(employee && employee.gc179Profile, employee && employee.name);
}

function setEmployeeEditorGc179Profile(profile, employeeName) {
  const normalized = normalizeEmployeeGc179Profile(profile, employeeName);
  document.getElementById("employeeEditorGc179SurnameInput").value = normalized.surname;
  document.getElementById("employeeEditorGc179GivenInput").value = normalized.givenName;
  document.getElementById("employeeEditorGc179InitialsInput").value = normalized.initials;
  document.getElementById("employeeEditorGc179PriInput").value = normalized.pri;
  document.getElementById("employeeEditorGc179GroupInput").value = normalized.group;
  document.getElementById("employeeEditorGc179SubGroupInput").value = normalized.subGroup;
  document.getElementById("employeeEditorGc179LevelInput").value = normalized.level;
  document.getElementById("employeeEditorGc179CompressedWorkWeekInput").checked = Boolean(normalized.compressedWorkWeek);
}

function getEmployeeEditorGc179Profile(employeeName) {
  const profile = {
    surname: document.getElementById("employeeEditorGc179SurnameInput").value,
    givenName: document.getElementById("employeeEditorGc179GivenInput").value,
    initials: document.getElementById("employeeEditorGc179InitialsInput").value,
    pri: document.getElementById("employeeEditorGc179PriInput").value,
    group: document.getElementById("employeeEditorGc179GroupInput").value,
    subGroup: document.getElementById("employeeEditorGc179SubGroupInput").value,
    level: document.getElementById("employeeEditorGc179LevelInput").value,
    compressedWorkWeek: document.getElementById("employeeEditorGc179CompressedWorkWeekInput").checked,
  };
  return normalizeEmployeeGc179Profile(profile, employeeName);
}

function employeeEditorGc179ProfileChanged(employee, employeeName) {
  const original = getEmployeeGc179Profile(employee);
  const selected = getEmployeeEditorGc179Profile(employeeName);
  return ["surname", "givenName", "initials", "pri", "group", "subGroup", "level", "compressedWorkWeek"].some(key => original[key] !== selected[key]);
}

function getEmployeeRoleLabel(employee) {
  return t(`employees.role.${getEmployeeRole(employee)}`);
}

function getEmployeeRoleSortRank(employee) {
  const role = getEmployeeRole(employee);
  if (role === "superAdmin") {
    return 0;
  }
  if (role === "admin") {
    return 1;
  }
  return 2;
}

function compareEmployeesByRoleThenName(left, right) {
  const leftRoleRank = getEmployeeRoleSortRank(left);
  const rightRoleRank = getEmployeeRoleSortRank(right);
  if (leftRoleRank !== rightRoleRank) {
    return leftRoleRank - rightRoleRank;
  }

  const nameComparison = String(left && left.name || "").localeCompare(String(right && right.name || ""), undefined, { sensitivity: "base" });
  if (nameComparison !== 0) {
    return nameComparison;
  }

  return String(left && left.code || "").localeCompare(String(right && right.code || ""));
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
    const projectName = String(project.projectName || "").trim();
    const projectTitle = getProjectDisplayName(project);
    const sector = String(project.sector || "").trim();
    const inputId = `employeeEditorProject_${projectCode}`.replace(/[^A-Za-z0-9_-]/g, "_");
    const checked = employeesViewState.editorProjectAssignments.selectedProjectCodes.has(projectCode) ? " checked" : "";
    const meta = [projectName ? projectCode : "", sector].filter(Boolean).join(" | ");
    return `
      <label class="assignment-checkitem" for="${escapeHtml(inputId)}">
        <input class="form-check-input employee-editor-project-checkbox" type="checkbox" id="${escapeHtml(inputId)}" value="${escapeHtml(projectCode)}"${checked}>
        <span class="assignment-checkitem-main">
          <span class="assignment-checkitem-title">${escapeHtml(projectTitle)}</span>
          ${meta ? `<span class="assignment-checkitem-meta">${escapeHtml(meta)}</span>` : ""}
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
        projectName: String(update.project.projectName || "").trim(),
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
  setEmployeeEditorTimeEntryTypes(["overtime"]);
  setEmployeeEditorGc179Profile(null, "");
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
    setEmployeeEditorTimeEntryTypes(getEmployeeTimeEntryTypes(employee));
    setEmployeeEditorGc179Profile(employee.gc179Profile, employee.name || "");
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
  const timeEntryTypes = getEmployeeEditorSelectedTimeEntryTypes();
  const timeEntryTypesChanged = employeeEditorTimeEntryTypesChanged(originalEmployee);
  const gc179Profile = getEmployeeEditorGc179Profile(employeeName);
  const gc179ProfileChanged = employeeEditorGc179ProfileChanged(originalEmployee, employeeName);
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
          timeEntryTypes,
          gc179Profile,
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

  if (employeeName === originalName && role === originalRole && !timeEntryTypesChanged && !gc179ProfileChanged && !hasPasswordChange && !projectAssignmentsChanged) {
    setEmployeeEditorMessage(t("dashboard.noChanges"), "info");
    return;
  }

  try {
    if (employeeName !== originalName || role !== originalRole || timeEntryTypesChanged || gc179ProfileChanged) {
      const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employeeCode), {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: employeeName,
          role,
          timeEntryTypes,
          gc179Profile,
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
    return false;
  }

  const confirmed = window.confirm(t("employees.removeConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return false;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code), {
      method: "DELETE",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRemoved"), "success");
    await loadEmployeesView();
    return true;
  } catch (error) {
    console.error("Error removing employee:", error);
    showToast(error.message || t("employees.removeError"), "error");
    return false;
  }
}

async function restoreEmployee(employee) {
  if (!employee || !employee.code) {
    return false;
  }

  const confirmed = window.confirm(t("employees.restoreConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return false;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code) + "/restore", {
      method: "POST",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRestored"), "success");
    await loadEmployeesView();
    return true;
  } catch (error) {
    console.error("Error restoring employee:", error);
    showToast(error.message || t("employees.restoreError"), "error");
    return false;
  }
}

function canImportGc179Entries() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const runtimeFlags = window.saphirFeatureFlags && typeof window.saphirFeatureFlags === "object"
    ? window.saphirFeatureFlags
    : null;
  const featureEnabled = user && typeof user.gc179ImportEnabled === "boolean"
    ? user.gc179ImportEnabled
    : Boolean(runtimeFlags && runtimeFlags.gc179Import === true);
  return featureEnabled && typeof getCurrentUserRole === "function" && ["admin", "superAdmin"].includes(getCurrentUserRole());
}

function getGc179ImportEmployees() {
  return (Array.isArray(employeesViewState.allEmployees) ? employeesViewState.allEmployees : [])
    .filter(employee => employee && employee.code && !isArchivedEmployee(employee) && !isCurrentUserEmployeeCode(employee.code))
    .slice()
    .sort(compareEmployeesByRoleThenName);
}

function getGc179ImportProjects() {
  const projects = employeesViewState.entryLookups && Array.isArray(employeesViewState.entryLookups.projects)
    ? employeesViewState.entryLookups.projects
    : [];
  return projects
    .filter(project => project && project.projectCode && project.canModify !== false && !project.archived)
    .slice()
    .sort((left, right) => String(left.projectCode || "").localeCompare(String(right.projectCode || ""), undefined, { sensitivity: "base" }));
}

function setGc179ImportMessage(message, tone = "info") {
  const box = document.getElementById("gc179ImportMessage");
  if (!box) {
    return;
  }
  box.className = `alert alert-${tone}`;
  box.textContent = message || "";
  box.classList.toggle("d-none", !message);
}

function normalizeGc179ImportMessages(values) {
  return (Array.isArray(values) ? values : values == null ? [] : [values])
    .map(value => {
      if (value && typeof value === "object" && value.message) {
        return String(value.message).trim();
      }
      return String(value || "").trim();
    })
    .filter(Boolean);
}

function normalizeGc179IdentityToken(value) {
  const text = String(value || "").trim();
  const digits = text.replace(/\D/g, "");
  return digits.length >= 6 ? digits : text.toUpperCase().replace(/\s+/g, " ");
}

function getGc179EmployeeFromSelect() {
  const select = document.getElementById("gc179ImportEmployeeSelect");
  const employeeCode = select ? String(select.value || "").trim() : "";
  return getGc179ImportEmployees().find(employee => String(employee.code || "").trim() === employeeCode) || null;
}

function getGc179EmployeeCodeFromFileName(fileName) {
  const match = String(fileName || "").match(/(?:^|[^0-9])([0-9]{6,12})(?=[^0-9]|$)/);
  return match ? match[1] : "";
}

function getGc179ImportIdentity(preview) {
  const source = preview && preview.identity && typeof preview.identity === "object" ? preview.identity : {};
  const header = preview && preview.header && typeof preview.header === "object" ? preview.header : {};
  const targetEmployee = getGc179EmployeeFromSelect();
  const targetProfile = targetEmployee && targetEmployee.gc179Profile && typeof targetEmployee.gc179Profile === "object"
    ? targetEmployee.gc179Profile
    : {};
  const sourceEmployeeCode = String(source.sourceEmployeeCode || getGc179EmployeeCodeFromFileName(preview && preview.sourceFile)).trim();
  const sourcePri = String(source.sourcePri || header.pri || "").trim();
  const sourceName = String(source.sourceName || [header.givenName, header.surname].filter(Boolean).join(" ")).trim();
  const targetEmployeeCode = String(source.targetEmployeeCode || targetEmployee && targetEmployee.code || preview && preview.employeeCode || "").trim();
  const targetName = String(source.targetEmployeeName || targetEmployee && targetEmployee.name || "").trim();
  const targetPri = String(source.targetPri || targetProfile.pri || "").trim();
  let status = String(source.status || "").trim().toLowerCase();

  if (!["matched", "unverified", "mismatch"].includes(status)) {
    const sourceTokens = [sourceEmployeeCode, sourcePri].map(normalizeGc179IdentityToken).filter(Boolean);
    const targetTokens = [targetEmployeeCode, targetPri].map(normalizeGc179IdentityToken).filter(Boolean);
    if (sourceTokens.length === 0 || targetTokens.length === 0) {
      status = "unverified";
    } else {
      status = sourceTokens.every(token => targetTokens.includes(token)) ? "matched" : "mismatch";
    }
  }

  const requiresConfirmation = typeof source.requiresConfirmation === "boolean"
    ? source.requiresConfirmation
    : status === "unverified";

  return {
    status,
    sourceEmployeeCode,
    sourcePri,
    sourceName,
    targetEmployeeCode,
    targetPri,
    targetName,
    requiresConfirmation,
    confirmed: Boolean(source.confirmed || employeesViewState.gc179Import.identityConfirmed),
  };
}

function getGc179EntrySourceRow(entry, index) {
  const value = Number(entry && entry.sourceRow);
  return Number.isInteger(value) && value >= 0 ? value : index;
}

function isGc179DuplicateEntry(entry) {
  return Boolean(entry && (entry.isDuplicate === true || ["exact", "conflict"].includes(String(entry.duplicateStatus || "").toLowerCase())));
}

function isGc179EntryImportable(entry) {
  return Boolean(entry)
    && entry.canImport !== false
    && !isGc179DuplicateEntry(entry)
    && normalizeGc179ImportMessages(entry.validationErrors).length === 0;
}

function getGc179PreviewCounts(preview) {
  const entries = Array.isArray(preview && preview.entries) ? preview.entries : [];
  const counts = preview && preview.counts && typeof preview.counts === "object" ? preview.counts : {};
  const warnings = normalizeGc179ImportMessages(preview && preview.warnings);
  const validationErrors = normalizeGc179ImportMessages(preview && preview.validationErrors);
  const duplicateEntries = entries.filter(isGc179DuplicateEntry).length;
  const validEntries = entries.filter(isGc179EntryImportable).length;
  const readCount = (value, fallback) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const skipped = readCount(counts.skipped, warnings.length);
  return {
    parsed: readCount(counts.parsed, entries.length + skipped),
    valid: readCount(counts.valid, validEntries),
    skipped,
    duplicates: readCount(counts.duplicates, duplicateEntries),
    errors: readCount(counts.errors, validationErrors.length),
  };
}

function getGc179BlockingValidationErrors(preview) {
  const selectedRows = employeesViewState.gc179Import.selectedSourceRows || new Set();
  const entries = Array.isArray(preview && preview.entries) ? preview.entries : [];
  return Array.from(new Set([
    ...normalizeGc179ImportMessages(preview && preview.validationErrors),
    ...entries.flatMap((entry, index) => selectedRows.has(getGc179EntrySourceRow(entry, index))
      ? normalizeGc179ImportMessages(entry && entry.validationErrors)
      : []),
  ]));
}

function getGc179SelectedSourceRows() {
  return Array.from(employeesViewState.gc179Import.selectedSourceRows || [])
    .map(Number)
    .filter(value => Number.isInteger(value) && value >= 0)
    .sort((left, right) => left - right);
}

function setGc179ImportFormDisabled(disabled) {
  const form = document.getElementById("gc179ImportForm");
  if (form) {
    form.querySelectorAll("input, select, textarea").forEach(control => {
      control.disabled = Boolean(disabled);
    });
  }
  const previewButton = document.getElementById("gc179ImportPreviewButton");
  if (previewButton) {
    previewButton.disabled = Boolean(disabled);
  }
}

function setGc179ButtonLabel(button, translationKey) {
  if (!button) {
    return;
  }
  button.textContent = t(translationKey);
}

function syncGc179ImportFilePicker(file = null) {
  const picker = document.getElementById("gc179ImportFilePicker");
  const fileName = document.getElementById("gc179ImportFileName");
  if (!picker || !fileName) {
    return;
  }

  const selectedName = String(file && file.name || "").trim();
  const hasFile = selectedName.length > 0;
  picker.classList.toggle("has-file", hasFile);

  if (hasFile) {
    fileName.removeAttribute("data-i18n");
    fileName.textContent = selectedName;
    fileName.title = selectedName;
    return;
  }

  fileName.setAttribute("data-i18n", "employees.gc179NoFileSelected");
  fileName.textContent = t("employees.gc179NoFileSelected");
  fileName.removeAttribute("title");
}

function resetGc179ImportPreview() {
  employeesViewState.gc179Import.preview = null;
  employeesViewState.gc179Import.selectedSourceRows = new Set();
  employeesViewState.gc179Import.identityConfirmed = false;
  employeesViewState.gc179Import.warningsConfirmed = false;
  employeesViewState.gc179Import.lastImportResult = null;
  setGc179ImportFormDisabled(false);
  const commitButton = document.getElementById("gc179ImportCommitButton");
  if (commitButton) {
    commitButton.disabled = true;
    setGc179ButtonLabel(commitButton, "employees.gc179ImportConfirm");
  }
  const previewButton = document.getElementById("gc179ImportPreviewButton");
  if (previewButton) {
    previewButton.disabled = false;
    setGc179ButtonLabel(previewButton, "employees.gc179Preview");
  }
  const undoButton = document.getElementById("gc179ImportUndoButton");
  if (undoButton) {
    undoButton.disabled = false;
    undoButton.classList.add("d-none");
    setGc179ButtonLabel(undoButton, "employees.gc179Undo");
  }
  const container = document.getElementById("gc179ImportPreviewContainer");
  if (container) {
    container.innerHTML = `<span class="panel-note">${escapeHtml(t("employees.gc179PreviewEmpty"))}</span>`;
  }
}

function populateGc179ImportModal(selectedEmployeeCode = "") {
  const employeeSelect = document.getElementById("gc179ImportEmployeeSelect");
  const projectSelect = document.getElementById("gc179ImportProjectSelect");
  if (!employeeSelect || !projectSelect) {
    return;
  }

  const employees = getGc179ImportEmployees();
  const projects = getGc179ImportProjects();
  employeeSelect.innerHTML = `
    <option value="">${escapeHtml(t("employees.gc179TargetEmployee"))}</option>
    ${employees.map(employee => `<option value="${escapeHtml(employee.code)}">${escapeHtml(employee.name)} (${escapeHtml(employee.code)})</option>`).join("")}
  `;
  projectSelect.innerHTML = `
    <option value="">${escapeHtml(t("shared.selectProject"))}</option>
    ${projects.map(project => {
      const code = String(project.projectCode || "");
      const name = String(project.projectName || "");
      const label = name ? `${code} | ${name}` : code;
      return `<option value="${escapeHtml(code)}">${escapeHtml(label)}</option>`;
    }).join("")}
  `;

  if (selectedEmployeeCode && employees.some(employee => employee.code === selectedEmployeeCode)) {
    employeeSelect.value = selectedEmployeeCode;
  } else if (employeesViewState.selectedEmployeeCode && employees.some(employee => employee.code === employeesViewState.selectedEmployeeCode)) {
    employeeSelect.value = employeesViewState.selectedEmployeeCode;
  }

  if (employeesViewState.selectedProjectCode && projects.some(project => String(project.projectCode || "") === employeesViewState.selectedProjectCode)) {
    projectSelect.value = employeesViewState.selectedProjectCode;
  }

  if (projects.length === 0) {
    setGc179ImportMessage(t("employees.gc179NoModifiableProjects"), "warning");
  }
}

function openGc179ImportModal(selectedEmployeeCode = "") {
  if (!canImportGc179Entries()) {
    return;
  }

  const form = document.getElementById("gc179ImportForm");
  if (form) {
    form.reset();
  }
  syncGc179ImportFilePicker();
  employeesViewState.gc179Import = {
    fdfContent: "",
    fileName: "",
    preview: null,
    selectedSourceRows: new Set(),
    identityConfirmed: false,
    warningsConfirmed: false,
    lastImportResult: null,
  };
  setGc179ImportMessage("");
  populateGc179ImportModal(selectedEmployeeCode);
  resetGc179ImportPreview();
  const modal = new bootstrap.Modal(document.getElementById("gc179ImportModal"));
  modal.show();
}

function readGc179ImportFile() {
  const input = document.getElementById("gc179ImportFileInput");
  const file = input && input.files && input.files[0] ? input.files[0] : null;
  if (!file) {
    return Promise.reject(new Error(t("employees.gc179FdfRequired")));
  }
  if (!/\.fdf$/i.test(String(file.name || ""))) {
    return Promise.reject(new Error(t("employees.gc179FdfInvalid")));
  }
  if (Number(file.size || 0) > 1024 * 1024) {
    return Promise.reject(new Error(t("employees.gc179FdfTooLarge")));
  }

  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      resolve({
        fileName: file.name || "",
        content: String(reader.result || ""),
      });
    };
    reader.onerror = () => reject(new Error(t("employees.gc179FdfRequired")));
    reader.readAsText(file);
  });
}

async function buildGc179ImportPayload({ requireFile = true, includeSelection = false } = {}) {
  const employeeCode = document.getElementById("gc179ImportEmployeeSelect").value;
  const projectCode = document.getElementById("gc179ImportProjectSelect").value;
  const status = document.getElementById("gc179ImportStatusSelect").value || "pending";
  const managerMessage = document.getElementById("gc179ImportManagerMessage").value || "";

  if (!employeeCode) {
    throw new Error(t("employees.gc179EmployeeRequired"));
  }
  if (!projectCode) {
    throw new Error(t("employees.gc179ProjectRequired"));
  }

  if (requireFile || !employeesViewState.gc179Import.fdfContent) {
    const fileData = await readGc179ImportFile();
    employeesViewState.gc179Import.fdfContent = fileData.content;
    employeesViewState.gc179Import.fileName = fileData.fileName;
  }

  const payload = {
    employeeCode,
    projectCode,
    status,
    managerMessage,
    fileName: employeesViewState.gc179Import.fileName,
    fdfContent: employeesViewState.gc179Import.fdfContent,
    skipDuplicates: true,
    confirmIdentity: Boolean(employeesViewState.gc179Import.identityConfirmed),
  };
  if (includeSelection) {
    payload.selectedSourceRows = getGc179SelectedSourceRows();
  }
  return payload;
}

function formatGc179RateLabel(entry) {
  const components = Array.isArray(entry && entry.gc179RateComponents) ? entry.gc179RateComponents : [];
  if (components.length > 0) {
    return components.map(component => {
      const rate = String(component && component.rate || "").trim();
      const hours = String(component && component.hours || "").trim();
      const rateLabel = /^\d+(?:\.\d+)?$/.test(rate) ? `${rate}×` : rate;
      return [rateLabel, hours ? `${hours} h` : ""].filter(Boolean).join(" ");
    }).filter(Boolean).join(" + ");
  }
  const rate = String(entry && entry.gc179Rate || "").trim();
  return rate === "mixed" ? t("employees.gc179MixedRate") : rate || "-";
}

function getGc179ImportReadiness() {
  const preview = employeesViewState.gc179Import.preview;
  if (!preview || employeesViewState.gc179Import.lastImportResult) {
    return { ready: false, reason: "preview" };
  }

  const identity = getGc179ImportIdentity(preview);
  const validationErrors = getGc179BlockingValidationErrors(preview);
  const counts = getGc179PreviewCounts(preview);
  const selectedCount = getGc179SelectedSourceRows().length;
  if (identity.status === "mismatch") {
    return { ready: false, reason: "identity" };
  }
  if (identity.requiresConfirmation && !employeesViewState.gc179Import.identityConfirmed && !identity.confirmed) {
    return { ready: false, reason: "confirmation" };
  }
  if (validationErrors.length > 0) {
    return { ready: false, reason: "validation" };
  }
  if (counts.skipped > 0 && !employeesViewState.gc179Import.warningsConfirmed) {
    return { ready: false, reason: "warnings" };
  }
  if (selectedCount === 0) {
    return { ready: false, reason: "selection" };
  }

  return { ready: true, reason: "" };
}

function getGc179ReadinessFeedback(readiness = getGc179ImportReadiness()) {
  const feedbackByReason = {
    identity: { key: "employees.gc179IdentityMismatch", tone: "danger" },
    confirmation: { key: "employees.gc179IdentityConfirmationRequired", tone: "warning" },
    validation: { key: "employees.gc179ValidationBlocked", tone: "danger" },
    warnings: { key: "employees.gc179SkippedConfirmationRequired", tone: "warning" },
    selection: { key: "employees.gc179NothingSelected", tone: "warning" },
  };
  return feedbackByReason[readiness && readiness.reason] || null;
}

function updateGc179ImportGuidanceMessage() {
  const readiness = getGc179ImportReadiness();
  if (readiness.ready) {
    setGc179ImportMessage("");
    return;
  }
  const feedback = getGc179ReadinessFeedback(readiness);
  if (feedback) {
    setGc179ImportMessage(t(feedback.key), feedback.tone);
  }
}

function updateGc179ImportCommitAvailability() {
  const selectedRows = getGc179SelectedSourceRows();
  const selectedCount = document.getElementById("gc179ImportSelectedCount");
  if (selectedCount) {
    selectedCount.textContent = t("employees.gc179SelectedCount", { count: selectedRows.length });
  }

  const preview = employeesViewState.gc179Import.preview;
  const entries = Array.isArray(preview && preview.entries) ? preview.entries : [];
  const selectableRows = entries
    .map((entry, index) => ({ entry, sourceRow: getGc179EntrySourceRow(entry, index) }))
    .filter(item => isGc179EntryImportable(item.entry))
    .map(item => item.sourceRow);
  const selectAll = document.getElementById("gc179ImportSelectAll");
  if (selectAll) {
    const selectedSelectableCount = selectableRows.filter(sourceRow => employeesViewState.gc179Import.selectedSourceRows.has(sourceRow)).length;
    selectAll.checked = selectableRows.length > 0 && selectedSelectableCount === selectableRows.length;
    selectAll.indeterminate = selectedSelectableCount > 0 && selectedSelectableCount < selectableRows.length;
  }

  const commitButton = document.getElementById("gc179ImportCommitButton");
  if (commitButton) {
    commitButton.disabled = !getGc179ImportReadiness().ready;
  }
}

function renderGc179ImportPreview(preview, { initializeSelection = true } = {}) {
  const container = document.getElementById("gc179ImportPreviewContainer");
  if (!container) {
    return;
  }

  const entries = Array.isArray(preview && preview.entries) ? preview.entries : [];
  const warnings = normalizeGc179ImportMessages(preview && preview.warnings);
  const validationErrors = normalizeGc179ImportMessages(preview && preview.validationErrors);
  const counts = getGc179PreviewCounts(preview);
  const identity = getGc179ImportIdentity(preview);
  if (initializeSelection) {
    employeesViewState.gc179Import.selectedSourceRows = new Set(
      entries
        .map((entry, index) => ({ entry, sourceRow: getGc179EntrySourceRow(entry, index) }))
        .filter(item => isGc179EntryImportable(item.entry))
        .map(item => item.sourceRow)
    );
    employeesViewState.gc179Import.identityConfirmed = Boolean(preview && preview.identity && preview.identity.confirmed);
    employeesViewState.gc179Import.warningsConfirmed = false;
  }

  const sourceParts = [
    identity.sourceEmployeeCode ? `${t("employees.gc179EmployeeCode")}: ${identity.sourceEmployeeCode}` : "",
    identity.sourcePri ? `${t("employees.gc179Pri")}: ${identity.sourcePri}` : "",
    preview && preview.sourceFile ? `${t("employees.gc179SourceFile")}: ${preview.sourceFile}` : "",
  ].filter(Boolean);
  const targetParts = [
    identity.targetEmployeeCode ? `${t("employees.gc179EmployeeCode")}: ${identity.targetEmployeeCode}` : "",
    identity.targetPri ? `${t("employees.gc179Pri")}: ${identity.targetPri}` : "",
  ].filter(Boolean);
  const identityMessage = t(`employees.gc179Identity${identity.status.charAt(0).toUpperCase()}${identity.status.slice(1)}`);

  const rows = entries.map((entry, index) => {
    const sourceRow = getGc179EntrySourceRow(entry, index);
    const entryErrors = normalizeGc179ImportMessages(entry && entry.validationErrors);
    const duplicate = isGc179DuplicateEntry(entry);
    const importable = isGc179EntryImportable(entry);
    const selected = employeesViewState.gc179Import.selectedSourceRows.has(sourceRow);
    const rowStatusKey = duplicate
      ? "employees.gc179RowDuplicate"
      : entryErrors.length > 0 || entry.canImport === false
        ? "employees.gc179RowInvalid"
        : "employees.gc179RowReady";
    const rateLabel = formatGc179RateLabel(entry);
    return `
    <tr>
      <td>
        <input type="checkbox" class="form-check-input gc179-import-row-select" data-gc179-source-row="${sourceRow}" aria-label="${escapeHtml(t("employees.gc179SelectRow", { row: sourceRow + 1 }))}" ${selected ? "checked" : ""} ${importable ? "" : "disabled"}>
      </td>
      <td class="mono">${sourceRow + 1}</td>
      <td>${escapeHtml(formatDateLabel(entry.date))}</td>
      <td class="mono">${escapeHtml(formatTimeString(entry.punchIn))} ${timeRangeArrowText()} ${escapeHtml(formatTimeString(entry.punchOut))}</td>
      <td><span class="inline-code-pill">${escapeHtml(entry.reasonCode || "-")}</span></td>
      <td><span class="inline-code-pill">${escapeHtml(entry.overtimeCode || "-")}</span></td>
      <td>${escapeHtml(entry.paymentOption || "-")}</td>
      <td class="mono">${escapeHtml(rateLabel)}</td>
      <td class="mono">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(entry.overtime)))}</td>
      <td>
        <span class="gc179-import-row-status ${duplicate ? "duplicate" : importable ? "ready" : "invalid"}">${escapeHtml(t(rowStatusKey))}</span>
        ${entryErrors.length > 0 ? `<div class="gc179-import-row-errors">${entryErrors.map(error => escapeHtml(error)).join("; ")}</div>` : ""}
      </td>
    </tr>
  `;
  }).join("");

  container.innerHTML = `
    <div class="gc179-import-preview-summary">
      <span>${escapeHtml(t("employees.gc179PreviewSummary", { count: entries.length, month: preview.monthKey || "-" }))}</span>
      <span class="inline-code-pill">${escapeHtml(preview.projectCode || "")}</span>
    </div>
    <div class="gc179-import-counts" aria-label="${escapeHtml(t("employees.gc179PreviewCounts"))}">
      <span>${escapeHtml(t("employees.gc179ParsedCount", { count: counts.parsed }))}</span>
      <span>${escapeHtml(t("employees.gc179ValidCount", { count: counts.valid }))}</span>
      <span>${escapeHtml(t("employees.gc179SkippedCount", { count: counts.skipped }))}</span>
      <span>${escapeHtml(t("employees.gc179DuplicateCount", { count: counts.duplicates }))}</span>
      <strong id="gc179ImportSelectedCount">${escapeHtml(t("employees.gc179SelectedCount", { count: getGc179SelectedSourceRows().length }))}</strong>
    </div>
    <div class="gc179-import-identity ${escapeHtml(identity.status)}">
      <div>
        <strong>${escapeHtml(t("employees.gc179SourceIdentity"))}</strong>
        <span>${escapeHtml(identity.sourceName || t("employees.gc179IdentityUnavailable"))}</span>
        ${sourceParts.length > 0 ? `<small>${escapeHtml(sourceParts.join(" · "))}</small>` : ""}
      </div>
      <div>
        <strong>${escapeHtml(t("employees.gc179TargetIdentity"))}</strong>
        <span>${escapeHtml(identity.targetName || t("employees.gc179IdentityUnavailable"))}</span>
        ${targetParts.length > 0 ? `<small>${escapeHtml(targetParts.join(" · "))}</small>` : ""}
      </div>
      <p class="gc179-import-identity-status">${escapeHtml(identityMessage)}</p>
      ${identity.requiresConfirmation && identity.status !== "mismatch" ? `
        <label class="gc179-import-confirmation">
          <input type="checkbox" class="form-check-input" id="gc179ImportIdentityConfirmation" ${employeesViewState.gc179Import.identityConfirmed ? "checked" : ""}>
          <span>${escapeHtml(t("employees.gc179IdentityConfirm", { employee: identity.targetName || identity.targetEmployeeCode }))}</span>
        </label>
      ` : ""}
    </div>
    ${validationErrors.length > 0 ? `
      <div class="gc179-import-errors">
        <strong>${escapeHtml(t("employees.gc179ValidationErrors"))}</strong>
        <ul>${validationErrors.map(error => `<li>${escapeHtml(error)}</li>`).join("")}</ul>
      </div>
    ` : ""}
    ${warnings.length > 0 ? `
      <div class="gc179-import-warnings">
        <strong>${escapeHtml(t("employees.gc179PreviewWarning"))}</strong>
        <ul>${warnings.map(warning => `<li>${escapeHtml(warning)}</li>`).join("")}</ul>
        ${counts.skipped > 0 ? `
          <label class="gc179-import-confirmation">
            <input type="checkbox" class="form-check-input" id="gc179ImportWarningsConfirmation" ${employeesViewState.gc179Import.warningsConfirmed ? "checked" : ""}>
            <span>${escapeHtml(t("employees.gc179SkippedConfirm", { count: counts.skipped }))}</span>
          </label>
        ` : ""}
      </div>
    ` : ""}
    <div class="gc179-import-table-shell">
      <table class="gc179-import-table">
        <thead>
          <tr>
            <th><input type="checkbox" class="form-check-input" id="gc179ImportSelectAll" aria-label="${escapeHtml(t("employees.gc179SelectAll"))}"></th>
            <th>${escapeHtml(t("employees.gc179SourceRow"))}</th>
            <th>${escapeHtml(t("export.day"))}</th>
            <th>${escapeHtml(t("dashboard.tableWindow"))}</th>
            <th>${escapeHtml(t("export.reason"))}</th>
            <th>${escapeHtml(t("export.overtimeCode"))}</th>
            <th>${escapeHtml(t("export.payment"))}</th>
            <th>${escapeHtml(t("employees.gc179Rate"))}</th>
            <th>${escapeHtml(t("export.totalTime"))}</th>
            <th>${escapeHtml(t("employees.scope"))}</th>
          </tr>
        </thead>
        <tbody>${rows || `<tr><td colspan="10">${escapeHtml(t("employees.noEntriesForMonth"))}</td></tr>`}</tbody>
      </table>
    </div>
  `;
  updateGc179ImportCommitAvailability();
}

async function previewGc179Import() {
  const button = document.getElementById("gc179ImportPreviewButton");
  return runButtonAction(button, async () => {
    try {
      const payload = await buildGc179ImportPayload({ requireFile: true });
      const response = await fetch(apiUrl + "employee/gc179-import/preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const preview = await parseResponse(response);
      employeesViewState.gc179Import.preview = preview;
      employeesViewState.gc179Import.lastImportResult = null;
      renderGc179ImportPreview(preview);
      updateGc179ImportGuidanceMessage();
    } catch (error) {
      console.error("Unable to preview GC179 import:", error);
      resetGc179ImportPreview();
      setGc179ImportMessage(error.message || t("employees.gc179ImportError"), "danger");
    }
  }, { key: "gc179-import-action" });
}

async function refreshGc179ImportTarget(employeeCode, monthKey) {
  employeesViewState.entriesByEmployee[employeeCode] = undefined;
  if (monthKey) {
    employeesViewState.currentMonthByEmployee[employeeCode] = monthKey;
  }
  employeesViewState.selectedEmployeeCode = employeeCode;
  markEntryRelatedViewsStaleFromPeople();
  document.getElementById("employeesSearchInput").value = "";
  document.getElementById("employeesScopeSelect").value = "active";
  document.getElementById("employeesProjectSelect").value = "";
  employeesViewState.selectedProjectCode = "";
  employeesViewState.autoOpenProjectCode = "";

  try {
    await loadEmployeesView({ rethrowOnError: true });
    employeesViewState.selectedEmployeeCode = employeeCode;
    applyEmployeeSearchFilter();
  } catch (error) {
    console.error("GC179 data was saved but the People view could not be refreshed:", error);
    setGc179ImportMessage(t("employees.gc179RefreshWarning"), "warning");
    showToast(t("employees.gc179RefreshWarning"), "warning");
  }
}

function renderGc179ImportCompleted(result, payload) {
  const importedCount = Number(result && result.importedCount || 0);
  const duplicateCount = Number(result && result.skippedDuplicateCount || 0);
  const operationWarnings = normalizeGc179ImportMessages(result && result.warnings);
  const container = document.getElementById("gc179ImportPreviewContainer");
  if (container) {
    container.innerHTML = `
      <div class="gc179-import-result success">
        <i class="fa-solid fa-circle-check" aria-hidden="true"></i>
        <div>
          <strong>${escapeHtml(t("employees.gc179ImportComplete"))}</strong>
          <p>${escapeHtml(t("employees.gc179ImportSuccess", { count: importedCount, duplicates: duplicateCount }))}</p>
          <small>${escapeHtml(t("employees.gc179ImportedTarget", {
            employee: result && result.employeeCode || payload.employeeCode,
            month: result && result.monthKey || "-",
          }))}</small>
          ${operationWarnings.length > 0 ? `<ul class="gc179-import-result-warnings">${operationWarnings.map(warning => `<li>${escapeHtml(warning)}</li>`).join("")}</ul>` : ""}
        </div>
      </div>
    `;
  }
  const undoButton = document.getElementById("gc179ImportUndoButton");
  if (undoButton) {
    undoButton.classList.toggle("d-none", !String(result && result.batchId || "").trim());
    undoButton.disabled = false;
    setGc179ButtonLabel(undoButton, "employees.gc179Undo");
  }
  setGc179ImportFormDisabled(true);
  const commitButton = document.getElementById("gc179ImportCommitButton");
  if (commitButton) {
    commitButton.disabled = true;
    setGc179ButtonLabel(commitButton, "employees.gc179ImportConfirm");
  }
  if (operationWarnings.length > 0) {
    setGc179ImportMessage(t("employees.gc179SavedWithWarnings"), "warning");
  }
}

async function commitGc179Import() {
  const readiness = getGc179ImportReadiness();
  if (!readiness.ready) {
    const feedback = getGc179ReadinessFeedback(readiness);
    setGc179ImportMessage(t(feedback ? feedback.key : "employees.gc179NothingSelected"), feedback ? feedback.tone : "warning");
    return;
  }

  const targetEmployee = getGc179EmployeeFromSelect();
  const selectedRows = getGc179SelectedSourceRows();
  const projectCode = document.getElementById("gc179ImportProjectSelect").value;
  const status = document.getElementById("gc179ImportStatusSelect").value || "pending";
  if (!window.confirm(t("employees.gc179CommitPrompt", {
    count: selectedRows.length,
    employee: targetEmployee && targetEmployee.name ? `${targetEmployee.name} (${targetEmployee.code})` : document.getElementById("gc179ImportEmployeeSelect").value,
    project: projectCode,
    status: t(`status.${status}`),
  }))) {
    return;
  }

  const button = document.getElementById("gc179ImportCommitButton");
  return runButtonAction(button, async () => {
    let payload;
    let result;
    try {
      payload = await buildGc179ImportPayload({ requireFile: false, includeSelection: true });
      const response = await fetch(apiUrl + "employee/gc179-import/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      result = await parseResponse(response);
    } catch (error) {
      console.error("Unable to commit GC179 import:", error);
      setGc179ImportMessage(error.message || t("employees.gc179ImportError"), "danger");
      updateGc179ImportCommitAvailability();
      return;
    }

    const employeeCode = String(result && result.employeeCode || payload.employeeCode);
    employeesViewState.gc179Import.lastImportResult = {
      ...result,
      employeeCode,
    };
    setGc179ImportMessage("");
    renderGc179ImportCompleted(result, payload);
    showToast(t("employees.gc179ImportSuccess", {
      count: Number(result && result.importedCount || 0),
      duplicates: Number(result && result.skippedDuplicateCount || 0),
    }), "success");
    await refreshGc179ImportTarget(employeeCode, result && result.monthKey);
  }, {
    key: "gc179-import-action",
    disabledAfter: () => Boolean(employeesViewState.gc179Import.lastImportResult) || !getGc179ImportReadiness().ready,
  });
}

async function undoGc179Import() {
  const lastResult = employeesViewState.gc179Import.lastImportResult;
  const batchId = String(lastResult && lastResult.batchId || "").trim();
  const employeeCode = String(lastResult && lastResult.employeeCode || "").trim();
  if (!batchId || !employeeCode) {
    return;
  }
  if (!window.confirm(t("employees.gc179UndoConfirm"))) {
    return;
  }

  const button = document.getElementById("gc179ImportUndoButton");
  return runButtonAction(button, async () => {
    try {
      const response = await fetch(apiUrl + "employee/gc179-import/undo", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ employeeCode, batchId }),
      });
      const result = await parseResponse(response);
      const undoneCount = Number(result && result.undoneCount || 0);
      const operationWarnings = normalizeGc179ImportMessages(result && result.warnings);
      employeesViewState.gc179Import.lastImportResult = null;
      if (button) {
        button.classList.add("d-none");
      }
      const container = document.getElementById("gc179ImportPreviewContainer");
      if (container) {
        container.innerHTML = `
          <div class="gc179-import-result success">
            <i class="fa-solid fa-rotate-left" aria-hidden="true"></i>
            <div>
              <strong>${escapeHtml(t("employees.gc179UndoComplete"))}</strong>
              <p>${escapeHtml(t("employees.gc179UndoSuccess", { count: undoneCount }))}</p>
              ${operationWarnings.length > 0 ? `<ul class="gc179-import-result-warnings">${operationWarnings.map(warning => `<li>${escapeHtml(warning)}</li>`).join("")}</ul>` : ""}
            </div>
          </div>
        `;
      }
      setGc179ImportMessage(operationWarnings.length > 0 ? t("employees.gc179SavedWithWarnings") : "", operationWarnings.length > 0 ? "warning" : "info");
      showToast(t("employees.gc179UndoSuccess", { count: undoneCount }), "success");
      await refreshGc179ImportTarget(employeeCode, result && result.monthKey || lastResult.monthKey);
    } catch (error) {
      console.error("Unable to undo GC179 import:", error);
      setGc179ImportMessage(error.message || t("employees.gc179UndoError"), "danger");
    }
  }, {
    key: "gc179-import-action",
    disabledAfter: () => Boolean(button && button.classList.contains("d-none")),
  });
}

function handleGc179ImportPreviewChange(event) {
  const target = event.target;
  if (!target) {
    return;
  }
  if (target.id === "gc179ImportIdentityConfirmation") {
    employeesViewState.gc179Import.identityConfirmed = Boolean(target.checked);
    updateGc179ImportCommitAvailability();
    updateGc179ImportGuidanceMessage();
    return;
  }
  if (target.id === "gc179ImportWarningsConfirmation") {
    employeesViewState.gc179Import.warningsConfirmed = Boolean(target.checked);
    updateGc179ImportCommitAvailability();
    updateGc179ImportGuidanceMessage();
    return;
  }

  const preview = employeesViewState.gc179Import.preview;
  const entries = Array.isArray(preview && preview.entries) ? preview.entries : [];
  if (target.id === "gc179ImportSelectAll") {
    entries.forEach((entry, index) => {
      const sourceRow = getGc179EntrySourceRow(entry, index);
      if (isGc179EntryImportable(entry)) {
        if (target.checked) {
          employeesViewState.gc179Import.selectedSourceRows.add(sourceRow);
        } else {
          employeesViewState.gc179Import.selectedSourceRows.delete(sourceRow);
        }
      }
    });
    document.querySelectorAll(".gc179-import-row-select:not(:disabled)").forEach(checkbox => {
      checkbox.checked = Boolean(target.checked);
    });
    updateGc179ImportCommitAvailability();
    updateGc179ImportGuidanceMessage();
    return;
  }

  if (target.classList.contains("gc179-import-row-select")) {
    const sourceRow = Number(target.getAttribute("data-gc179-source-row"));
    if (Number.isInteger(sourceRow) && sourceRow >= 0) {
      if (target.checked) {
        employeesViewState.gc179Import.selectedSourceRows.add(sourceRow);
      } else {
        employeesViewState.gc179Import.selectedSourceRows.delete(sourceRow);
      }
      updateGc179ImportCommitAvailability();
      updateGc179ImportGuidanceMessage();
    }
  }
}

function getEmployeeInitials(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return "EM";
  }

  return parts.slice(0, 2).map(part => part[0].toUpperCase()).join("");
}

const EMPLOYEE_CARD_PROJECT_TOKEN_LIMIT = 4;

function renderEmployeeProjectBubble(project, responsibilityKey) {
  const responsibilityLabel = responsibilityKey === "backup"
    ? t("dashboard.backupAdmin")
    : t("dashboard.primaryAdmin");
  const projectCode = String(project.projectCode || "").trim();
  const projectName = String(project.projectName || "").trim();
  const distinctProjectName = projectName.toLocaleLowerCase() === projectCode.toLocaleLowerCase() ? "" : projectName;
  const titleParts = [responsibilityLabel, projectCode, distinctProjectName, project.sector].filter(Boolean);
  return renderProjectIdentityPill(
    project,
    getProjectDisplayName(project),
    `employee-project-bubble${responsibilityKey === "backup" ? " is-backup" : ""}`,
    titleParts.join(" | ")
  );
}

function renderEmployeeProjectBubbles(projects, responsibilityKey) {
  const visibleProjects = normalizeEmployeeProjectReferenceArray(projects);
  if (visibleProjects.length === 0) {
    return "";
  }

  const maxVisible = 12;
  const shownProjects = visibleProjects.slice(0, maxVisible);
  const hiddenCount = visibleProjects.length - shownProjects.length;
  return shownProjects.map(project => renderEmployeeProjectBubble(project, responsibilityKey)).join("") + (hiddenCount > 0
    ? `<span class="employee-project-bubble is-more" title="${escapeHtml(t("employees.moreProjects", { count: hiddenCount }))}">+${escapeHtml(String(hiddenCount))}</span>`
    : "");
}

function getEmployeeCardProjectAssignments(supervisedProjects, backupProjects, limit) {
  const queues = [
    supervisedProjects.map(project => ({ project, responsibilityKey: "supervised" })),
    backupProjects.map(project => ({ project, responsibilityKey: "backup" })),
  ];
  const assignments = [];
  while (assignments.length < limit && queues.some(queue => queue.length > 0)) {
    queues.forEach(queue => {
      if (assignments.length < limit && queue.length > 0) {
        assignments.push(queue.shift());
      }
    });
  }
  return assignments;
}

function renderEmployeeResponsibilityBubbles(employee, compact) {
  const supervisedProjects = getEmployeeSupervisedProjects(employee);
  const backupProjects = getEmployeeBackupProjects(employee);
  if (supervisedProjects.length === 0 && backupProjects.length === 0) {
    return "";
  }

  if (!compact) {
    return `
      <div class="employee-project-bubble-row">
        ${renderEmployeeProjectBubbles(supervisedProjects, "supervised")}
        ${renderEmployeeProjectBubbles(backupProjects, "backup")}
      </div>
    `;
  }

  const totalAssignmentCount = supervisedProjects.length + backupProjects.length;
  const visibleAssignmentCount = totalAssignmentCount > EMPLOYEE_CARD_PROJECT_TOKEN_LIMIT
    ? EMPLOYEE_CARD_PROJECT_TOKEN_LIMIT - 1
    : totalAssignmentCount;
  const shownAssignments = getEmployeeCardProjectAssignments(supervisedProjects, backupProjects, visibleAssignmentCount);
  const hiddenCount = totalAssignmentCount - shownAssignments.length;
  return `
    <div class="employee-project-bubble-row is-compact">
      ${shownAssignments.map(assignment => renderEmployeeProjectBubble(assignment.project, assignment.responsibilityKey)).join("")}
      ${hiddenCount > 0 ? `<span class="employee-project-bubble is-more" title="${escapeHtml(t("employees.moreProjects", { count: hiddenCount }))}">+${escapeHtml(String(hiddenCount))}</span>` : ""}
    </div>
  `;
}

function renderEmployeeResponsibilitySummary(employee) {
  const supervisedProjects = getEmployeeSupervisedProjects(employee);
  const backupProjects = getEmployeeBackupProjects(employee);
  if (supervisedProjects.length === 0 && backupProjects.length === 0) {
    return "";
  }

  return `
    <div class="employee-responsibility-strip">
      ${supervisedProjects.length > 0 ? `
        <div class="employee-responsibility-group">
          <span class="employee-responsibility-label">${escapeHtml(t("employees.supervisedProjects"))}</span>
          <div class="employee-project-bubble-row">${renderEmployeeProjectBubbles(supervisedProjects, "supervised")}</div>
        </div>
      ` : ""}
      ${backupProjects.length > 0 ? `
        <div class="employee-responsibility-group">
          <span class="employee-responsibility-label">${escapeHtml(t("employees.backupProjects"))}</span>
          <div class="employee-project-bubble-row">${renderEmployeeProjectBubbles(backupProjects, "backup")}</div>
        </div>
      ` : ""}
    </div>
  `;
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

function normalizeEmployeeProjectReferenceArray(projects) {
  return (Array.isArray(projects) ? projects : [])
    .map(project => {
      const projectCode = String(project && project.projectCode ? project.projectCode : "").trim();
      if (!projectCode) {
        return null;
      }

      const projectName = String(project && project.projectName ? project.projectName : projectCode).trim() || projectCode;
      const sector = String(project && project.sector ? project.sector : "").trim();
      return {
        projectCode,
        projectName,
        sector,
        colorKey: getProjectColorKey(project),
        markerKey: getProjectMarkerKey(project),
        responsibility: String(project && project.responsibility ? project.responsibility : "").trim(),
      };
    })
    .filter(Boolean);
}

function getEmployeeSupervisedProjects(employee) {
  return normalizeEmployeeProjectReferenceArray(employee && employee.supervisedProjects ? employee.supervisedProjects : []);
}

function getEmployeeBackupProjects(employee) {
  return normalizeEmployeeProjectReferenceArray(employee && employee.backupProjects ? employee.backupProjects : []);
}

function isAdminDirectoryEmployee(employee) {
  const role = getEmployeeRole(employee);
  return role === "admin" || role === "superAdmin";
}

function getCurrentUserRole() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  return user ? normalizeClientRole(user.role) : "employee";
}

function projectCodeSetFromProjects(projects, predicate) {
  const codes = new Set();
  (Array.isArray(projects) ? projects : []).forEach(project => {
    if (predicate && !predicate(project)) {
      return;
    }

    const projectCode = String(project && project.projectCode ? project.projectCode : "").trim();
    if (projectCode) {
      codes.add(projectCode);
    }
  });

  return codes;
}

function getCurrentUserManagedProjectCodeSet() {
  const currentRole = getCurrentUserRole();
  const currentEmployeeCode = getCurrentUserEmployeeCode();
  const projects = employeesViewState.entryLookups && Array.isArray(employeesViewState.entryLookups.projects)
    ? employeesViewState.entryLookups.projects
    : [];

  if (currentRole === "superAdmin") {
    return projectCodeSetFromProjects(projects);
  }

  if (currentRole !== "admin" || !currentEmployeeCode) {
    return new Set();
  }

  return projectCodeSetFromProjects(projects, project => {
    if (project && project.canModify === true) {
      return true;
    }

    const admins = Array.isArray(project && project.admins)
      ? project.admins.map(code => String(code || "").trim())
      : [];
    const backupAdmins = Array.isArray(project && project.backupAdmins)
      ? project.backupAdmins.map(code => String(code || "").trim())
      : [];
    return admins.indexOf(currentEmployeeCode) >= 0 || backupAdmins.indexOf(currentEmployeeCode) >= 0;
  });
}

function employeeHasEntriesInProjectSet(employee, projectCodeSet) {
  if (!employee || !projectCodeSet || projectCodeSet.size === 0) {
    return false;
  }

  return getEmployeeProjectCodes(employee).some(projectCode => projectCodeSet.has(projectCode));
}

function getEmployeeDirectorySectionDefinitions(employees) {
  const managedProjectCodes = getCurrentUserManagedProjectCodeSet();
  const currentRole = getCurrentUserRole();
  const sections = [
    {
      key: "admins",
      title: t("employees.sectionAdmins"),
      employees: [],
    },
    {
      key: "managed",
      title: currentRole === "superAdmin" ? t("employees.sectionWithEntries") : t("employees.sectionMyProjects"),
      employees: [],
    },
    {
      key: "other",
      title: t("employees.sectionOtherEmployees"),
      employees: [],
    },
  ];

  (Array.isArray(employees) ? employees : []).forEach(employee => {
    if (isAdminDirectoryEmployee(employee)) {
      sections[0].employees.push(employee);
      return;
    }

    if (employeeHasEntriesInProjectSet(employee, managedProjectCodes)) {
      sections[1].employees.push(employee);
      return;
    }

    sections[2].employees.push(employee);
  });

  return sections.filter(section => section.employees.length > 0);
}

function renderEmployeeDirectoryCard(employee) {
  const isCurrentUser = isCurrentUserEmployeeCode(employee.code);
  return `
    <article class="employee-card${employeesViewState.selectedEmployeeCode === employee.code ? " is-active" : ""}${isCurrentUser ? " is-current-user" : ""}" data-employee-code="${escapeHtml(employee.code)}">
      <div class="employee-card-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <button type="button" class="employee-card-title employee-card-title-button employee-open-button${isCurrentUser ? " employee-name-self" : ""}" data-employee-code="${escapeHtml(employee.code)}" aria-controls="employeeDetailContainer" title="${escapeHtml(employee.name)}">
              <span>${escapeHtml(employee.name)}</span>
              ${isCurrentUser ? `<span class="self-card-badge">${escapeHtml(t("employees.currentUser"))}</span>` : ""}
            </button>
            <div class="employee-card-note">${escapeHtml(isArchivedEmployee(employee) ? t("employees.archived") : getEmployeeRoleLabel(employee))}</div>
          </div>
        </div>
      </div>
      ${renderEmployeeResponsibilityBubbles(employee, true)}
      <div class="employee-card-meta">
        <div class="employee-card-info-row">
          <span class="employee-card-info-label">${escapeHtml(t("employees.employeeCode"))}</span>
          <span class="employee-card-info-value mono"><span class="employee-card-info-prefix">${escapeHtml(t("employees.employeeCode"))}</span>${escapeHtml(employee.code)}</span>
        </div>
        <div class="employee-card-info-row">
          <span class="employee-card-info-label">${escapeHtml(t("employees.entriesShort"))}</span>
          <span class="employee-card-info-value">${escapeHtml(t("employees.entryCount", { count: employee.entryCount || 0 }))}</span>
        </div>
        ${isArchivedEmployee(employee) ? `<div class="employee-card-info-row"><span class="employee-card-info-label">${escapeHtml(t("employees.scope"))}</span><span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span></div>` : ""}
      </div>
    </article>
  `;
}

function renderEmployeeDirectorySection(section) {
  return `
    <section class="employee-directory-section" data-employee-section="${escapeHtml(section.key)}">
      <div class="employee-directory-section-title">
        <span>${escapeHtml(section.title)}</span>
        <span class="employee-directory-section-count">${escapeHtml(tn("shared.employee", section.employees.length))}</span>
      </div>
      <div class="employee-directory-section-grid">
        ${section.employees.map(renderEmployeeDirectoryCard).join("")}
      </div>
    </section>
  `;
}

function buildEmployeeProjectSearchText(project) {
  if (!project) {
    return "";
  }

  return [
    project.projectCode,
    project.projectName,
    project.sector,
  ].map(value => String(value || "").trim()).filter(Boolean).join(" ").toLowerCase();
}

function setEmployeesProjectSearchIndex(projects) {
  const index = {};
  (Array.isArray(projects) ? projects : []).forEach(project => {
    const projectCode = String(project && project.projectCode ? project.projectCode : "").trim();
    if (!projectCode) {
      return;
    }

    index[projectCode] = buildEmployeeProjectSearchText(project);
  });

  employeesViewState.projectSearchTextByCode = index;
}

function getEmployeeEntryProjectSearchText(employee) {
  const codes = new Set(getEmployeeProjectCodes(employee));
  (Array.isArray(employee && employee.projectStats) ? employee.projectStats : []).forEach(project => {
    const projectCode = String(project && project.projectCode ? project.projectCode : "").trim();
    if (projectCode) {
      codes.add(projectCode);
    }
  });

  return Array.from(codes).map(projectCode => {
    const projectSearchText = employeesViewState.projectSearchTextByCode[projectCode] || "";
    return `${projectCode} ${projectSearchText}`;
  }).join(" ").toLowerCase();
}

function getEmployeeResponsibilitySearchText(employee) {
  return getEmployeeSupervisedProjects(employee)
    .concat(getEmployeeBackupProjects(employee))
    .map(project => buildEmployeeProjectSearchText(project))
    .join(" ");
}

function tokenizeEmployeeSearch(searchValue) {
  return window.Saphir.textSearch.tokenize(String(searchValue || "").trim().toLowerCase());
}

function textMatchesAllEmployeeSearchTokens(text, tokens) {
  const normalizedText = String(text || "").toLowerCase();
  return window.Saphir.textSearch.matchesAll(normalizedText, tokens);
}

function getEmployeeSearchResult(employee, searchValue) {
  const tokens = tokenizeEmployeeSearch(searchValue);
  if (tokens.length === 0) {
    return {
      matches: true,
      rank: 0,
    };
  }

  const identityText = `${employee && employee.name ? employee.name : ""} ${employee && employee.code ? employee.code : ""} ${getEmployeeRoleLabel(employee)}`.toLowerCase();
  const responsibilityText = getEmployeeResponsibilitySearchText(employee);
  const entryProjectText = getEmployeeEntryProjectSearchText(employee);
  const combinedText = `${identityText} ${responsibilityText} ${entryProjectText}`;

  if (!textMatchesAllEmployeeSearchTokens(combinedText, tokens)) {
    return {
      matches: false,
      rank: 99,
    };
  }

  if (textMatchesAllEmployeeSearchTokens(responsibilityText, tokens)) {
    return {
      matches: true,
      rank: 0,
    };
  }

  if (textMatchesAllEmployeeSearchTokens(entryProjectText, tokens)) {
    return {
      matches: true,
      rank: 1,
    };
  }

  if (textMatchesAllEmployeeSearchTokens(identityText, tokens)) {
    return {
      matches: true,
      rank: 2,
    };
  }

  return {
    matches: true,
    rank: 3,
  };
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
  const projectItems = (Array.isArray(projects) ? projects : [])
    .filter(project => String(project && project.projectCode || "").trim());
  setEmployeesProjectSearchIndex(projectItems);
  const selectedValue = projectItems.some(project => String(project.projectCode || "") === currentValue)
    ? currentValue
    : "";

  projectSelect.innerHTML = [`<option value="">${escapeHtml(t("filters.allProjects"))}</option>`]
    .concat(projectItems.map(project => {
      const projectCode = String(project.projectCode || "");
      const selected = projectCode === selectedValue ? " selected" : "";
      return `<option value="${escapeHtml(projectCode)}" data-project-color-key="${escapeHtml(getProjectColorKey(project))}" data-project-marker-key="${escapeHtml(getProjectMarkerKey(project))}"${selected}>${escapeHtml(formatProjectCodeAndName(project))}</option>`;
    }))
    .join("");

  employeesViewState.selectedProjectCode = projectSelect.value;
}

function getEmployeeAnalyticsStage(canvasId) {
  return document.querySelector(`[data-employee-analytics-stage="${canvasId}"]`);
}

function ensureEmployeeAnalyticsCanvas(canvasId) {
  const stage = getEmployeeAnalyticsStage(canvasId);
  if (!stage) {
    return null;
  }

  let canvas = document.getElementById(canvasId);
  if (!canvas) {
    stage.innerHTML = `<canvas id="${canvasId}"></canvas>`;
    canvas = document.getElementById(canvasId);
  }

  return canvas;
}

function destroyEmployeeAnalyticsChart(canvasId) {
  if (employeeAnalyticsChartInstances[canvasId]) {
    employeeAnalyticsChartInstances[canvasId].destroy();
    delete employeeAnalyticsChartInstances[canvasId];
  }
}

function setEmployeeAnalyticsEmptyState(canvasId, messageKey = "employees.noChartData") {
  destroyEmployeeAnalyticsChart(canvasId);
  const stage = getEmployeeAnalyticsStage(canvasId);
  if (stage) {
    stage.innerHTML = createEmptyState(t(messageKey));
  }
}

function setEmployeeAnalyticsLoadingState() {
  document.querySelectorAll(".employee-analytics-stage").forEach(stage => {
    stage.innerHTML = createLoadingState("employeeBarChart", 1);
  });
}

function getEmployeeAnalyticsTheme() {
  const rootStyles = getComputedStyle(document.documentElement);
  return {
    textSecondary: rootStyles.getPropertyValue("--text-secondary").trim() || "#5e646f",
    textMuted: rootStyles.getPropertyValue("--text-muted").trim() || "#7a828f",
    grid: rootStyles.getPropertyValue("--chart-grid").trim()
      || (document.documentElement.getAttribute("data-theme") === "dark"
        ? "rgba(255, 255, 255, 0.1)"
        : "rgba(29, 29, 31, 0.08)"),
    panel: rootStyles.getPropertyValue("--panel-bg").trim() || "#ffffff",
    tooltip: rootStyles.getPropertyValue("--tooltip-bg").trim() || "rgba(29, 29, 31, 0.94)",
    tooltipText: rootStyles.getPropertyValue("--tooltip-text").trim() || "#ffffff",
  };
}

function getEmployeeAnalyticsColors(count) {
  const rootStyles = getComputedStyle(document.documentElement);
  return Array.from({ length: count }, (_, index) => {
    const paletteIndex = index % employeeAnalyticsPalette.length;
    return rootStyles.getPropertyValue(`--chart-${paletteIndex + 1}`).trim() || employeeAnalyticsPalette[paletteIndex];
  });
}

function getEmployeeProjectAnalyticsStats(employee, projectCode) {
  const selectedProjectCode = String(projectCode || "").trim();
  if (!selectedProjectCode) {
    return null;
  }

  const projectStats = Array.isArray(employee && employee.projectStats) ? employee.projectStats : [];
  return projectStats.find(project => String(project.projectCode || "") === selectedProjectCode) || null;
}

function getEmployeeAnalyticsStats(employee) {
  const projectStats = getEmployeeProjectAnalyticsStats(employee, getEmployeesProjectFilterValue());
  if (projectStats) {
    return {
      totalOvertimeSeconds: Number(projectStats.totalOvertimeSeconds || 0),
      entryCount: Number(projectStats.entryCount || 0),
      approvedCount: Number(projectStats.approvedCount || 0),
      pendingCount: Number(projectStats.pendingCount || 0),
      rejectedCount: Number(projectStats.rejectedCount || 0),
      liveCount: Number(projectStats.liveCount || 0),
    };
  }

  return {
    totalOvertimeSeconds: Number(employee && employee.totalOvertimeSeconds || 0),
    entryCount: Number(employee && employee.entryCount || 0),
    approvedCount: Number(employee && employee.approvedCount || 0),
    pendingCount: Number(employee && employee.pendingCount || 0),
    rejectedCount: Number(employee && employee.rejectedCount || 0),
    liveCount: Number(employee && employee.liveCount || 0),
  };
}

function compactEmployeeMetricItems(items, maxItems = 8) {
  const sortedItems = (Array.isArray(items) ? items : [])
    .filter(item => Number(item.value || 0) > 0)
    .sort((left, right) => Number(right.value || 0) - Number(left.value || 0));

  if (sortedItems.length <= maxItems) {
    return sortedItems;
  }

  const visibleItems = sortedItems.slice(0, maxItems - 1);
  const otherValue = sortedItems.slice(maxItems - 1).reduce((sum, item) => sum + Number(item.value || 0), 0);
  visibleItems.push({ label: t("projects.other"), value: otherValue });
  return visibleItems;
}

function getEmployeeChartContextValue(context) {
  if (!context) {
    return 0;
  }

  if (typeof context.raw === "number") {
    return context.raw;
  }

  if (context.parsed && typeof context.parsed.x === "number") {
    return context.parsed.x;
  }

  if (typeof context.parsed === "number") {
    return context.parsed;
  }

  const value = Number(context.raw || 0);
  return Number.isFinite(value) ? value : 0;
}

function renderEmployeeOvertimeShareChart(employees) {
  const items = compactEmployeeMetricItems((employees || []).map(employee => {
    const stats = getEmployeeAnalyticsStats(employee);
    return {
      label: String(employee && employee.name || employee && employee.code || ""),
      value: stats.totalOvertimeSeconds,
    };
  }));

  if (items.length === 0 || typeof Chart !== "function") {
    setEmployeeAnalyticsEmptyState("employeeOvertimeShareChart", typeof Chart === "function" ? "employees.noChartData" : "projects.chartLibraryFailed");
    return;
  }

  const canvas = ensureEmployeeAnalyticsCanvas("employeeOvertimeShareChart");
  if (!canvas) {
    return;
  }

  const theme = getEmployeeAnalyticsTheme();
  destroyEmployeeAnalyticsChart("employeeOvertimeShareChart");
  employeeAnalyticsChartInstances.employeeOvertimeShareChart = new Chart(canvas.getContext("2d"), {
    type: "bar",
    data: {
      labels: items.map(item => item.label),
      datasets: [{
        label: t("employees.overtimeShare"),
        data: items.map(item => item.value),
        backgroundColor: getEmployeeAnalyticsColors(items.length),
        borderWidth: 0,
        borderRadius: 4,
        barThickness: 18,
      }],
    },
    options: {
      indexAxis: "y",
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      resizeDelay: 150,
      plugins: {
        legend: {
          display: false,
        },
        tooltip: {
          backgroundColor: theme.tooltip,
          titleColor: theme.tooltipText,
          bodyColor: theme.tooltipText,
          callbacks: {
            label: context => {
              const value = getEmployeeChartContextValue(context);
              const total = (context.dataset.data || []).reduce((sum, item) => {
                const itemValue = Number(item || 0);
                return sum + (Number.isFinite(itemValue) ? itemValue : 0);
              }, 0);
              const percent = total > 0 ? Math.round((value / total) * 100) : 0;
              return `${context.label}: ${secondsToDurationLabel(value)} (${percent}%)`;
            },
          },
        },
      },
      scales: {
        x: {
          beginAtZero: true,
          ticks: {
            color: theme.textSecondary,
            callback: value => secondsToDurationLabel(Number(value || 0)),
          },
          grid: {
            color: theme.grid,
          },
        },
        y: {
          ticks: {
            autoSkip: false,
            color: theme.textSecondary,
            font: {
              size: 11,
            },
          },
          grid: {
            display: false,
          },
        },
      },
    },
  });
}

function buildEmployeeAnalyticsSignature(employees) {
  const theme = document.documentElement.getAttribute("data-theme") || "light";
  const projectCode = getEmployeesProjectFilterValue();
  return [
    theme,
    projectCode,
    (Array.isArray(employees) ? employees : []).map(employee => {
      const stats = getEmployeeAnalyticsStats(employee);
      return [
        employee && employee.code,
        stats.totalOvertimeSeconds,
        stats.entryCount,
      ].join(":");
    }).join("|"),
  ].join("::");
}

function renderEmployeeAnalytics(employees, options = {}) {
  const sourceEmployees = Array.isArray(employees) ? employees : employeesViewState.filteredEmployees;
  const signature = buildEmployeeAnalyticsSignature(sourceEmployees);
  if (!options.force && signature === employeesViewState.employeeAnalyticsSignature) {
    return;
  }

  employeesViewState.employeeAnalyticsSignature = signature;
  if (pendingEmployeeAnalyticsFrameId) {
    window.cancelAnimationFrame(pendingEmployeeAnalyticsFrameId);
    pendingEmployeeAnalyticsFrameId = null;
  }

  pendingEmployeeAnalyticsFrameId = window.requestAnimationFrame(() => {
    renderEmployeeOvertimeShareChart(sourceEmployees);
    pendingEmployeeAnalyticsFrameId = null;
  });
}

function getVisibleEmployeeEntries(employeeCode) {
  const entries = Array.isArray(employeesViewState.entriesByEmployee[employeeCode]) ? employeesViewState.entriesByEmployee[employeeCode] : [];
  const projectCode = String(employeesViewState.selectedProjectCode || "").trim();
  if (!projectCode) {
    return entries;
  }

  return entries.filter(entry => String(entry.projectCode || "") === projectCode);
}

function getPeopleProjectEntryContext(entry) {
  if (isDiverseEntry(entry)) {
    return getEntryContextLabel(entry);
  }

  const parts = [];

  if (entry && entry.overtimeCode) {
    parts.push(String(entry.overtimeCode));
  }

  if (entry && entry.paymentOption) {
    parts.push(formatPaymentOptionValue(entry.paymentOption));
  }

  if (entry && entry.reasonCode) {
    parts.push(String(entry.reasonCode));
  }

  return parts.length > 0 ? parts.join(" | ") : t("shared.uncoded");
}

function renderPeopleProjectEntryRows(entries, employeeCode) {
  const normalizedEmployeeCode = String(employeeCode || employeesViewState.selectedEmployeeCode || "").trim();
  const sortedEntries = sortEntriesByDateTime(entries, true);
  const rowsMarkup = sortedEntries.length > 0
    ? sortedEntries.map(entry => {
      const exactTimeLabel = getEntryExactTimeLabel(entry);
      const duration = secondsToDurationLabel(getEntryDurationSeconds(entry));
      const isOpen = isEntryOpen(entry);
      const isPending = String(entry.status || "pending").toLowerCase() === "pending";
      const canModify = canModifyEntry(entry);
      const canApprove = canApproveEntry(entry);
      const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
      const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
      const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
      const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
      const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
      const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
      const entryTypeAttribute = ` data-entrytype="${escapeHtml(getEntryType(entry))}"`;
      const diverseReasonAttribute = ` data-diversereason="${escapeHtml(entry.diverseReason || "")}"`;
      const diverseSummaryAttribute = ` data-diversesummary="${escapeHtml(entry.diverseSummary || "")}"`;
      const workCommentAttribute = ` data-workcomment="${escapeHtml(entry.workComment || "")}"`;
      const statusAttribute = ` data-status="${escapeHtml(entry.status || "pending")}"`;
      const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
      const employeeCodeAttribute = ` data-employee-code="${escapeHtml(normalizedEmployeeCode)}"`;
      const reviewButtons = isPending && !isOpen && !isEntryForgottenClockOut(entry) && canApprove
        ? `
          <button type="button" class="btn btn-success btn-sm action-btn people-project-entry-action people-calendar-approve"${employeeCodeAttribute} data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.approve"))}">
            <i class="fa-solid fa-check"></i>
          </button>
          <button type="button" class="btn btn-danger btn-sm action-btn people-project-entry-action people-calendar-reject"${employeeCodeAttribute} data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.reject"))}">
            <i class="fa-solid fa-ban"></i>
          </button>
        `
        : "";
      const manageButtons = canModify
        ? `
          <button type="button" class="btn btn-outline-secondary btn-sm action-btn people-project-entry-action people-calendar-edit"${employeeCodeAttribute} data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${entryTypeAttribute}${diverseReasonAttribute}${diverseSummaryAttribute}${workCommentAttribute}${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${statusAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
            <i class="fa-solid fa-pen"></i>
          </button>
          <button type="button" class="btn btn-outline-secondary btn-sm action-btn people-project-entry-action people-calendar-delete"${employeeCodeAttribute} data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
            <i class="fa-solid fa-trash"></i>
          </button>
        `
        : "";
      const permissionBadge = !canModify || (isPending && !isOpen && !canApprove)
        ? getEntryPermissionBadgeMarkup(entry)
        : "";
      return `
        <article class="people-project-entry-row">
          <div class="people-project-entry-date">${escapeHtml(formatDateLabel(entry.date))}</div>
          <div class="people-project-entry-main">
            <div class="people-project-entry-time mono">${getEntryRoundedTimeRangeMarkup(entry)}</div>
            ${exactTimeLabel ? `<div class="panel-note">${escapeHtml(exactTimeLabel)}</div>` : ""}
            <div class="people-project-entry-context">${escapeHtml(getPeopleProjectEntryContext(entry))}</div>
            ${renderEntryNotesPreview(entry)}
          </div>
          <div class="people-project-entry-side">
            <span class="inline-code-pill">${escapeHtml(duration)}</span>
            <span class="status-badge ${escapeHtml(getStatusTone(entry))}">${escapeHtml(getEntryStatusLabel(entry))}</span>
          </div>
          <div class="people-project-entry-actions">
            ${reviewButtons}
            ${manageButtons}
            ${permissionBadge}
          </div>
        </article>
      `;
    }).join("")
    : createEmptyState(t("employees.noProjectEntries"));

  return rowsMarkup;
}

function getEmployeeStatsProjectEntries(employeeCode, projectCode) {
  const normalizedProjectCode = String(projectCode || "").trim() || "__NO_PROJECT__";
  return getVisibleEmployeeEntries(employeeCode).filter(entry => {
    const entryProjectCode = String(entry && entry.projectCode || "").trim() || "__NO_PROJECT__";
    return entryProjectCode === normalizedProjectCode;
  });
}

function hydrateEmployeeProjectEntryDisclosure(detailsElement) {
  if (!detailsElement || !detailsElement.open) {
    return false;
  }

  const list = detailsElement.querySelector("[data-employee-project-entry-list]");
  if (!list || list.getAttribute("data-entries-loaded") === "true") {
    return false;
  }

  const employeeCode = String(detailsElement.getAttribute("data-employee-code") || "").trim();
  const projectCode = String(detailsElement.getAttribute("data-project-code") || "").trim();
  list.innerHTML = renderPeopleProjectEntryRows(getEmployeeStatsProjectEntries(employeeCode, projectCode), employeeCode);
  list.setAttribute("data-entries-loaded", "true");
  return true;
}

async function fetchEmployeeDetailEntries(employeeCode) {
  const response = await fetch(apiUrl + "employee/" + encodeURIComponent(employeeCode));
  if (response.status === 404) {
    return [];
  }
  const payload = await parseResponse(response);
  if (Array.isArray(payload)) {
    return payload;
  }

  if (!payload || (typeof payload === "object" && Object.keys(payload).length === 0)) {
    return [];
  }

  return [payload];
}

function getDefaultEmployeeMonthKey(employeeCode, entries) {
  return window.Saphir.calendarMonths.resolveActiveMonth(entries, employeesViewState.currentMonthByEmployee[employeeCode], {
    getTimestamp(entry) {
      return new Date(entry.date).getTime();
    },
    getEntryDate(entry) {
      return entry.date;
    },
    toMonthKey: toCalendarMonthKey,
    referenceDate: new Date(),
  });
}

function buildEmployeeInsightMarkup(entries, monthEntries) {
  const allEntries = Array.isArray(entries) ? entries : [];
  const visibleMonthEntries = Array.isArray(monthEntries) ? monthEntries : [];
  const monthTotalSeconds = visibleMonthEntries.reduce((accumulator, entry) => accumulator + getEntryDurationSeconds(entry), 0);
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
    projectTotals[projectCode].seconds += getEntryDurationSeconds(entry);
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
  return window.Saphir.entryStats.resolveStatus(entry, isEntryOpen);
}

function getTopEmployeeStatsBucket(buckets) {
  return window.Saphir.entryStats.selectTopBucket(buckets);
}

function buildEmployeeStatsModel(entries) {
  return window.Saphir.entryStats.summarize(entries, {
    getDurationSeconds: getEntryDurationSeconds,
    getStatus: getEmployeeStatsStatus,
    getTimestamp: toEntryDateTime,
    getProjectCode(entry) {
      return String(entry.projectCode || "").trim() || "__NO_PROJECT__";
    },
    getProject(projectCode, entry) {
      const rawProjectCode = String(entry.projectCode || "").trim();
      const projectRecord = rawProjectCode
        ? findProjectByCode(employeesViewState.entryLookups && employeesViewState.entryLookups.projects, projectCode)
        : null;
      return {
        projectCode,
        projectName: projectRecord ? getProjectDisplayName(projectRecord) : (rawProjectCode || t("shared.noProject")),
        colorKey: projectRecord ? getProjectColorKey(projectRecord) : getProjectColorKey(projectCode),
        markerKey: projectRecord ? getProjectMarkerKey(projectRecord) : getProjectMarkerKey(projectCode),
      };
    },
    getOvertimeCode(entry) {
      return String(entry.overtimeCode || "").trim() || t("shared.uncoded");
    },
    includeSourceEntries: false,
    includeProjectEntries: true,
  });
}

function buildEmployeeDetailedStatsMarkup(entries, employeeCode) {
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
          const shouldOpenEntries = String(employeesViewState.autoOpenProjectCode || "").trim() === String(project.projectCode || "").trim();
          return `
            <article class="self-project-stat-card${project.projectCode === "__NO_PROJECT__" ? "" : " project-colored-surface"}" style="${project.projectCode === "__NO_PROJECT__" ? "" : getProjectColorStyle(project)}">
              <div class="self-project-stat-main">
                <div>
                  <div class="self-project-stat-title">${project.projectCode === "__NO_PROJECT__" ? escapeHtml(t("shared.noProject")) : renderProjectIdentityPill(project, project.projectCode)}</div>
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
              <details class="project-card-entry-toggle" data-employee-code="${escapeHtml(employeeCode)}" data-project-code="${escapeHtml(project.projectCode)}" ${shouldOpenEntries ? "open" : ""}>
                <summary class="project-card-entry-summary">
                  <span class="project-card-entry-summary-left">
                    <span class="project-card-entry-arrow"><i class="fa-solid fa-chevron-right"></i></span>
                    <span>${escapeHtml(t("employees.entriesShort"))}</span>
                  </span>
                  <span class="panel-note">${escapeHtml(t("employees.projectEntriesSummary", { count: project.count, duration: secondsToDurationLabel(project.seconds) }))}</span>
                </summary>
                <div class="people-project-entry-list people-project-entry-list-compact" data-employee-project-entry-list data-entries-loaded="${shouldOpenEntries ? "true" : "false"}">
                  ${shouldOpenEntries ? renderPeopleProjectEntryRows(project.entries, employeeCode) : ""}
                </div>
              </details>
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
  return window.Saphir.calendarMonths.buildYear(entries, activeMonthKey, {
    getEntryDate(entry) {
      return entry.date;
    },
    toMonthKey: toCalendarMonthKey,
    formatMonthLabel(date) {
      return date.toLocaleDateString(getCurrentLocale(), { month: "short" });
    },
    referenceDate: new Date(),
  });
}

function buildEmployeeCalendarDays(entries, activeMonthKey) {
  return window.Saphir.calendarDays.buildMonth(entries, activeMonthKey, {
    getEntryDate(entry) {
      return entry.date;
    },
    getDurationSeconds: getEntryDurationSeconds,
    orderDayEntries(dayEntries) {
      return dayEntries;
    },
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

function markEntryRelatedViewsStaleFromPeople() {
  if (typeof window.requestAppViewRefresh === "function") {
    window.requestAppViewRefresh(["dashboardView", "adminView", "projectsView"]);
    return;
  }

  if (typeof window.markAppViewsStale === "function") {
    window.markAppViewsStale(["dashboardView", "adminView", "projectsView"]);
  }
}

function renderEmployeesDirectory(employees) {
  const container = document.getElementById("employeesDirectoryContainer");
  const detailContainer = document.getElementById("employeeDetailContainer");
  const canManageProfiles = canManageEmployeeProfiles();
  const addButton = document.getElementById("addEmployeeButton");
  const importButton = document.getElementById("gc179ImportButton");
  if (addButton) {
    addButton.classList.toggle("d-none", !canManageProfiles);
  }
  if (importButton) {
    importButton.classList.toggle("d-none", !canImportGc179Entries());
  }
  document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", employees.length);

  if (!employees || employees.length === 0) {
    container.classList.remove("is-sectioned");
    container.innerHTML = createEmptyState(t("employees.none"));
    detailContainer.innerHTML = "";
    employeesViewState.selectedEmployeeCode = "";
    return;
  }

  if (!employees.some(employee => employee.code === employeesViewState.selectedEmployeeCode)) {
    employeesViewState.selectedEmployeeCode = "";
  }

  container.classList.add("is-sectioned");
  container.innerHTML = getEmployeeDirectorySectionDefinitions(employees)
    .map(renderEmployeeDirectorySection)
    .join("");

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
  const isCurrentUser = isCurrentUserEmployeeCode(employee.code);
  const liveEntries = sortEntriesByDateTime(entries.filter(entry => isEntryOpen(entry)), true);
  const activeMonthKey = getDefaultEmployeeMonthKey(employee.code, entries);
  employeesViewState.currentMonthByEmployee[employee.code] = activeMonthKey;

  const monthEntries = entries.filter(entry => toCalendarMonthKey(entry.date) === activeMonthKey);
  const monthTotalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getEntryDurationSeconds(entry), 0);
  const employeeInsightsMarkup = buildEmployeeInsightMarkup(entries, monthEntries);
  const employeeDetailedStatsMarkup = buildEmployeeDetailedStatsMarkup(entries, employee.code);
  const responsibilityMarkup = renderEmployeeResponsibilitySummary(employee);
  const monthBoard = buildEmployeeMonthBoard(entries, activeMonthKey);
  const calendarMonth = buildEmployeeCalendarDays(monthEntries, activeMonthKey);
  const activeYear = calendarMonth.year;
  const dayCells = [];

  calendarMonth.days.forEach(day => {
    const dayEntries = day.entries;
    const isCurrentMonth = day.isCurrentMonth;
    const totalDaySeconds = day.totalSeconds;
    const entryPreview = dayEntries.map(entry => {
      const statusTone = getStatusTone(entry);
      const canModify = canModifyEntry(entry);
      const canApprove = canApproveEntry(entry);
      const permissionBadge = getEntryPermissionBadgeMarkup(entry);
      const calendarProject = findProjectByCode(employeesViewState.entryLookups && employeesViewState.entryLookups.projects, entry.projectCode) || entry.projectCode;
      const calendarContext = !isDiverseEntry(entry) && entry.projectCode
        ? `${renderProjectIdentityPill(calendarProject, entry.projectCode)}<span>${escapeHtml([entry.overtimeCode, entry.paymentOption ? formatPaymentOptionValue(entry.paymentOption) : "", entry.reasonCode].filter(Boolean).join(" | "))}</span>`
        : escapeHtml(getEntryContextLabel(entry));

      const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
      const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
      const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
      const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
      const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
      const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
      const entryTypeAttribute = ` data-entrytype="${escapeHtml(getEntryType(entry))}"`;
      const diverseReasonAttribute = ` data-diversereason="${escapeHtml(entry.diverseReason || "")}"`;
      const diverseSummaryAttribute = ` data-diversesummary="${escapeHtml(entry.diverseSummary || "")}"`;
      const workCommentAttribute = ` data-workcomment="${escapeHtml(entry.workComment || "")}"`;
      const statusAttribute = ` data-status="${escapeHtml(entry.status || "pending")}"`;
      const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
      const reviewButtons = String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry) && !isEntryForgottenClockOut(entry) && canApprove
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
          <div class="calendar-entry-meta project-entry-context">${calendarContext}</div>
          ${renderEntryNotesPreview(entry)}
          ${reviewButtons ? `<div class="calendar-entry-actions calendar-entry-actions-review">${reviewButtons}</div>` : ""}
          <div class="calendar-entry-actions calendar-entry-actions-manage">
            ${canModify ? `
              <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${entryTypeAttribute}${diverseReasonAttribute}${diverseSummaryAttribute}${workCommentAttribute}${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${statusAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
                <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
              </button>
              <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
                <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
              </button>
            ` : ""}
            ${permissionBadge}
          </div>
        </div>
      `;
    }).join("");

    dayCells.push(`
      <div class="calendar-day${isCurrentMonth ? "" : " is-muted"}${dayEntries.length > 0 ? " has-entries" : ""}">
        <div class="calendar-day-header">
          <span class="calendar-day-number">${day.dayNumber}</span>
          ${dayEntries.length > 0 ? `<span class="calendar-day-total">${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>` : ""}
        </div>
        <div class="calendar-day-body">
          ${entryPreview}
        </div>
      </div>
    `);
  });

  const liveEntriesMarkup = liveEntries.length > 0
    ? `
      <div class="calendar-live-strip">
        ${liveEntries.map(entry => {
          const elapsedSeconds = getEntryDurationSeconds(entry);
          const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
          const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
          const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
          const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
          const paymentOptionAttribute = ` data-paymentoption="${escapeHtml(entry.paymentOption || "cash")}"`;
          const reasonCodeAttribute = ` data-reasoncode="${escapeHtml(entry.reasonCode || "")}"`;
          const entryTypeAttribute = ` data-entrytype="${escapeHtml(getEntryType(entry))}"`;
          const diverseReasonAttribute = ` data-diversereason="${escapeHtml(entry.diverseReason || "")}"`;
          const diverseSummaryAttribute = ` data-diversesummary="${escapeHtml(entry.diverseSummary || "")}"`;
          const workCommentAttribute = ` data-workcomment="${escapeHtml(entry.workComment || "")}"`;
          const statusAttribute = ` data-status="${escapeHtml(entry.status || "pending")}"`;
          const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
          const canModify = canModifyEntry(entry);
          const permissionBadge = getEntryPermissionBadgeMarkup(entry);
          return `
            <article class="calendar-live-card">
              <div class="calendar-entry-main">
                <span class="calendar-entry-time">${escapeHtml(formatDateLabel(entry.date))} | ${buildTimeRangeMarkup(formatTimeString(getEntryExactPunchIn(entry)), t("shared.inProgress"))}</span>
                <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
              </div>
              <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
              <div class="calendar-entry-actions calendar-entry-actions-manage">
                ${canModify ? `
                  <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${entryTypeAttribute}${diverseReasonAttribute}${diverseSummaryAttribute}${workCommentAttribute}${overtimeCodeAttribute}${paymentOptionAttribute}${reasonCodeAttribute}${statusAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
                    <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
                  </button>
                  <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
                    <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
                  </button>
                ` : ""}
                ${permissionBadge}
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
          <button type="button" class="btn btn-outline-secondary btn-sm people-gc179-fdf-button" data-employee-code="${escapeHtml(employee.code)}" data-export-month="${escapeHtml(activeMonthKey)}">
            <i class="fa-solid fa-file-export"></i> ${escapeHtml(t("export.downloadGc179Fdf"))}
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
          <button type="button" class="btn btn-outline-secondary btn-sm people-gc179-fdf-button" data-employee-code="${escapeHtml(employee.code)}" data-export-month="${escapeHtml(activeMonthKey)}">
            <i class="fa-solid fa-file-export"></i> ${escapeHtml(t("export.downloadGc179Fdf"))}
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
            <div class="employee-detail-title${isCurrentUser ? " employee-name-self" : ""}" tabindex="-1">
              ${escapeHtml(employee.name)}
              ${isCurrentUser ? `<span class="self-card-badge">${escapeHtml(t("employees.currentUser"))}</span>` : ""}
            </div>
            <div class="employee-card-note">${escapeHtml(isArchivedEmployee(employee) ? t("employees.archived") : getEmployeeRoleLabel(employee))}</div>
          </div>
        </div>
        <div class="employee-detail-actions">
          ${isArchivedEmployee(employee) || isCurrentUser ? "" : `<button type="button" class="btn btn-primary btn-sm people-add-entry-button" data-employee-code="${escapeHtml(employee.code)}"><i class="fa-solid fa-plus"></i> ${escapeHtml(t("dashboard.addEntry"))}</button>`}
          ${canManageProfiles ? `<button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>` : ""}
        </div>
      </div>
      <div class="employee-detail-meta">
        <span class="inline-code-pill">${escapeHtml(t("employees.employeeCode"))} ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(getEmployeeRoleLabel(employee))}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: entries.length }))}</span>
        ${employeesViewState.selectedProjectCode ? `<span class="meta-pill">${escapeHtml(employeesViewState.selectedProjectCode)}</span>` : ""}
        ${isArchivedEmployee(employee) ? `<span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span>` : `<span class="status-badge approved">${escapeHtml(t("employees.scopeActive"))}</span>`}
      </div>
      ${responsibilityMarkup}
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
    return false;
  }

  if (employeesViewState.entriesByEmployee[employeeCode]) {
    renderEmployeeDetail(employee);
    return true;
  }

  setLoadingState("employeeDetailContainer", "detail", 1);

  try {
    const entries = await fetchEmployeeDetailEntries(employeeCode);
    employeesViewState.entriesByEmployee[employeeCode] = Array.isArray(entries) ? entries : [];
    renderEmployeeDetail(employee);
    return true;
  } catch (error) {
    console.error("Error loading employee detail entries:", error);
    container.innerHTML = createEmptyState(t("dashboard.timelineLoadError"));
    return false;
  }
}

function applyEmployeeSearchFilter() {
  const searchValue = document.getElementById("employeesSearchInput").value.trim();
  const projectCode = getEmployeesProjectFilterValue();
  employeesViewState.selectedProjectCode = projectCode;

  const searchResults = {};
  const filteredEmployees = employeesViewState.employees
    .filter(employee => {
      const searchResult = getEmployeeSearchResult(employee, searchValue);
      searchResults[employee.code] = searchResult;
      return searchResult.matches && employeeMatchesProjectFilter(employee, projectCode);
    })
    .sort((left, right) => {
      if (searchValue) {
        const leftRank = searchResults[left.code] ? searchResults[left.code].rank : 99;
        const rightRank = searchResults[right.code] ? searchResults[right.code].rank : 99;
        if (leftRank !== rightRank) {
          return leftRank - rightRank;
        }
      }

      return compareEmployeesByRoleThenName(left, right);
    });
  employeesViewState.filteredEmployees = filteredEmployees;
  renderEmployeeAnalytics(filteredEmployees);
  renderEmployeesDirectory(filteredEmployees);
}

function scheduleEmployeeSearchFilter() {
  if (employeesViewState.employeeFilterTimerId) {
    window.clearTimeout(employeesViewState.employeeFilterTimerId);
  }

  employeesViewState.employeeFilterTimerId = window.setTimeout(() => {
    employeesViewState.employeeFilterTimerId = null;
    applyEmployeeSearchFilter();
  }, 160);
}

function applyEmployeeScopeFilterFromState() {
  const scope = document.getElementById("employeesScopeSelect").value || "active";
  employeesViewState.employees = filterEmployeesByScope(employeesViewState.allEmployees, scope);
  applyEmployeeSearchFilter();
}

function loadEmployeesView({ rethrowOnError = false } = {}) {
  setLoadingState("employeesDirectoryContainer", "grid", 4);
  setEmployeeAnalyticsLoadingState();
  employeesViewState.employeeAnalyticsSignature = "";
  document.getElementById("employeeDetailContainer").innerHTML = "";
  const scope = document.getElementById("employeesScopeSelect").value || "active";
  return fetch(apiUrl + "employees/bootstrap?scope=all")
    .then(parseResponse)
    .then(async payload => {
      const employees = Array.isArray(payload && payload.employees) ? payload.employees : [];
      const lookups = payload && payload.lookups ? payload.lookups : {};
      const scopedProjects = Array.isArray(payload && payload.projects) ? payload.projects : [];
      const projectItems = Array.isArray(scopedProjects) ? scopedProjects : [];
      employeesViewState.entryLookups = {
        ...(lookups || {}),
        projects: projectItems,
      };
      populateEmployeesProjectFilter(projectItems);
      employeesViewState.allEmployees = Array.isArray(employees) ? employees : [];
      employeesViewState.employees = filterEmployeesByScope(employeesViewState.allEmployees, scope);
      applyEmployeeSearchFilter();
      if (employeesViewState.selectedEmployeeCode && getEmployeeByCode(employeesViewState.selectedEmployeeCode)) {
        return (await loadEmployeeDetail(employeesViewState.selectedEmployeeCode)) !== false;
      }
      return true;
    })
    .catch(error => {
      console.error("Error loading employees view:", error);
      if (rethrowOnError) {
        throw error;
      }
      showToast(t("employees.loadError"), "error");
      return false;
    });
}

function getEmployeeByCode(employeeCode) {
  return employeesViewState.employees.find(employee => employee.code === employeeCode) || null;
}

window.rerenderEmployeesViewForLanguageChange = function () {
  const projects = Array.isArray(employeesViewState.entryLookups && employeesViewState.entryLookups.projects)
    ? employeesViewState.entryLookups.projects
    : [];
  populateEmployeesProjectFilter(projects);
  employeesViewState.employeeAnalyticsSignature = "";
  applyEmployeeSearchFilter();
};

async function openPeopleProjectFilter(employeeCode, projectCode, entryId = "") {
  if (typeof showView === "function") {
    showView("employeesView");
  }

  employeesViewState.selectedEmployeeCode = employeeCode || "";
  employeesViewState.selectedProjectCode = "";
  employeesViewState.autoOpenProjectCode = projectCode || "";
  employeesViewState.focusEntryId = entryId || "";
  const projectSelect = document.getElementById("employeesProjectSelect");
  if (projectSelect) {
    projectSelect.value = "";
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
    prepareEmployeeEntryFocus(employeeCode, entryId);
    if (!focusEmployeeEntry(entryId)) {
      focusEmployeeDetailCard();
    }
  }
}

function prepareEmployeeEntryFocus(employeeCode, entryId) {
  const normalizedEntryId = String(entryId || "").trim();
  if (!normalizedEntryId) {
    return;
  }

  const entries = Array.isArray(employeesViewState.entriesByEmployee[employeeCode])
    ? employeesViewState.entriesByEmployee[employeeCode]
    : [];
  const targetEntry = entries.find(entry => String(entry && entry.entryId || "") === normalizedEntryId);
  if (!targetEntry) {
    return;
  }

  const monthKey = toCalendarMonthKey(targetEntry.date);
  if (monthKey) {
    employeesViewState.currentMonthByEmployee[employeeCode] = monthKey;
  }
  renderEmployeeDetail(getEmployeeByCode(employeeCode));
}

function focusEmployeeEntry(entryId) {
  const normalizedEntryId = String(entryId || employeesViewState.focusEntryId || "").trim();
  if (!normalizedEntryId) {
    return false;
  }

  const entryAction = Array.from(document.querySelectorAll("#employeeDetailContainer [data-entryid]"))
    .find(element => String(element.getAttribute("data-entryid") || "") === normalizedEntryId);
  const entryContainer = entryAction && entryAction.closest(".people-project-entry-row, .calendar-entry, .calendar-live-card");
  if (!entryContainer) {
    return false;
  }

  const disclosure = entryContainer.closest("details");
  if (disclosure) {
    disclosure.open = true;
  }
  entryContainer.classList.add("is-entry-focus-target");
  entryContainer.scrollIntoView({ behavior: "smooth", block: "center" });
  window.setTimeout(() => entryContainer.classList.remove("is-entry-focus-target"), 2400);
  employeesViewState.focusEntryId = "";
  return true;
}

window.openPeopleProjectFilter = openPeopleProjectFilter;

window.addEventListener("app:theme-changed", () => {
  const employeesView = document.getElementById("employeesView");
  if (!employeesView || !employeesView.classList.contains("active")) {
    return;
  }

  renderEmployeeAnalytics(employeesViewState.filteredEmployees || [], { force: true });
});

function updateActiveEmployeeDirectoryCard() {
  document.querySelectorAll("#employeesDirectoryContainer .employee-card").forEach(card => {
    card.classList.toggle(
      "is-active",
      String(card.getAttribute("data-employee-code") || "") === String(employeesViewState.selectedEmployeeCode || "")
    );
  });
}

function focusEmployeeDetailCard() {
  const detailContainer = document.getElementById("employeeDetailContainer");
  if (!detailContainer) {
    return false;
  }

  const detailTitle = detailContainer.querySelector(".employee-detail-title");
  if (detailTitle) {
    detailTitle.focus({ preventScroll: true });
  }

  const detailCard = detailContainer.querySelector(".employee-detail-card") || detailContainer;
  if (typeof detailCard.scrollIntoView === "function") {
    detailCard.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  return true;
}

async function openEmployeeDetailFromDirectory(employeeCode) {
  const normalizedEmployeeCode = String(employeeCode || "").trim();
  if (!normalizedEmployeeCode) {
    return false;
  }

  employeesViewState.selectedEmployeeCode = normalizedEmployeeCode;
  updateActiveEmployeeDirectoryCard();
  const loaded = await loadEmployeeDetail(normalizedEmployeeCode);
  if (!loaded) {
    return false;
  }

  return focusEmployeeDetailCard();
}

document.getElementById("employeesDirectoryContainer").addEventListener("click", event => {
  const openButton = event.target.closest(".employee-open-button");
  if (openButton) {
    const employeeCode = openButton.getAttribute("data-employee-code");
    if (employeeCode) {
      runButtonAction(openButton, () => openEmployeeDetailFromDirectory(employeeCode), {
        key: `employee-detail:${employeeCode}`,
      }).catch(error => {
        console.error("Unable to open employee file:", error);
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

  const titleButton = employeeCard.querySelector(".employee-card-title-button.employee-open-button");
  runButtonAction(titleButton, () => openEmployeeDetailFromDirectory(employeeCode), {
    key: `employee-detail:${employeeCode}`,
  }).catch(error => {
    console.error("Unable to open employee file:", error);
    showToast(t("employees.loadError"), "error");
  });
});

document.getElementById("employeeDetailContainer").addEventListener("toggle", event => {
  const disclosure = event.target && typeof event.target.closest === "function"
    ? event.target.closest(".project-card-entry-toggle")
    : null;
  if (disclosure) {
    hydrateEmployeeProjectEntryDisclosure(disclosure);
  }
}, true);

document.getElementById("employeeDetailContainer").addEventListener("click", async event => {
  const gc179Button = event.target.closest(".people-gc179-fdf-button");
  if (gc179Button) {
    const employeeCode = gc179Button.getAttribute("data-employee-code");
    const monthKey = gc179Button.getAttribute("data-export-month") || employeesViewState.currentMonthByEmployee[employeeCode];
    await runButtonAction(gc179Button, () => downloadGc179FdfExport({
      employeeCode,
      monthKey,
    }), { key: `people-gc179-export:${employeeCode}:${monthKey}` });
    return;
  }

  const yearButton = event.target.closest(".employee-calendar-year-button");
  if (yearButton) {
    const employeeCode = yearButton.getAttribute("data-employee-code");
    const direction = yearButton.getAttribute("data-calendar-year-nav");
    if (employeeCode && direction) {
      const currentMonthKey = employeesViewState.currentMonthByEmployee[employeeCode] || toCalendarMonthKey(new Date());
      employeesViewState.currentMonthByEmployee[employeeCode] = shiftCalendarMonthKey(currentMonthKey, direction === "prev" ? -12 : 12);
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

  const approveButton = event.target.closest(".people-calendar-approve");
  if (approveButton) {
    const employeeCode = approveButton.getAttribute("data-employee-code");
    if (employeeCode) {
      const actionKey = `people-entry-action:${employeeCode}:${approveButton.getAttribute("data-entryid") || `${approveButton.getAttribute("data-date")}:${approveButton.getAttribute("data-punchin")}`}`;
      await runButtonAction(approveButton, async () => {
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
          markEntryRelatedViewsStaleFromPeople();
        } catch (error) {
          console.error("Error approving entry from calendar:", error);
          showToast(t("dashboard.approvalError", { message: error.message }), "error");
        }
      }, { key: actionKey });
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
      const actionKey = `people-entry-action:${employeeCode}:${rejectButton.getAttribute("data-entryid") || `${rejectButton.getAttribute("data-date")}:${rejectButton.getAttribute("data-punchin")}`}`;
      await runButtonAction(rejectButton, async () => {
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
          markEntryRelatedViewsStaleFromPeople();
        } catch (error) {
          console.error("Error rejecting entry from calendar:", error);
          showToast(t("dashboard.approvalError", { message: error.message }), "error");
        }
      }, { key: actionKey });
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
      const actionKey = `people-entry-action:${employeeCode}:${deleteButton.getAttribute("data-entryid") || `${deleteButton.getAttribute("data-date")}:${deleteButton.getAttribute("data-punchin")}`}`;
      await runButtonAction(deleteButton, async () => {
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
          markEntryRelatedViewsStaleFromPeople();
        } catch (error) {
          console.error("Error deleting entry from calendar:", error);
          showToast(t("dashboard.entryDeleteError", { message: error.message }), "error");
        }
      }, { key: actionKey });
    }
    return;
  }

  const editButton = event.target.closest(".employee-edit-button");
  if (editButton) {
    const employee = getEmployeeByCode(editButton.getAttribute("data-employee-code"));
    if (employee) {
      await runButtonAction(editButton, () => openEmployeeEditorModal("edit", employee), {
        key: "employee-editor-open",
        disableWhileRunning: () => document.querySelectorAll("#addEmployeeButton, .employee-edit-button"),
      }).catch(error => {
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
      await openAddEntryModal(employeeCode, addEntryButton).catch(error => {
        console.error("Error opening add entry modal from People:", error);
        showToast(t("dashboard.entryOptionsError"), "error");
      });
    }
    return;
  }

  const entryEditButton = event.target.closest(".people-calendar-edit");
  if (entryEditButton) {
    const employeeCode = entryEditButton.getAttribute("data-employee-code");
    if (employeeCode) {
      setDashboardEmployeeContext(employeeCode);
      if (typeof openUpdateModal === "function") {
        await openUpdateModal(entryEditButton, employeeCode);
      }
    }
  }
});

document.getElementById("addEmployeeButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, () => openEmployeeEditorModal("create"), {
    key: "employee-editor-open",
    disableWhileRunning: () => document.querySelectorAll("#addEmployeeButton, .employee-edit-button"),
  }).catch(error => {
    console.error("Unable to open employee editor:", error);
    showToast(t("employees.loadError"), "error");
  });
});
document.getElementById("gc179ImportButton").addEventListener("click", () => openGc179ImportModal(employeesViewState.selectedEmployeeCode));
document.getElementById("gc179ImportPreviewButton").addEventListener("click", previewGc179Import);
document.getElementById("gc179ImportCommitButton").addEventListener("click", commitGc179Import);
document.getElementById("gc179ImportUndoButton").addEventListener("click", undoGc179Import);
document.getElementById("gc179ImportPreviewContainer").addEventListener("change", handleGc179ImportPreviewChange);
document.getElementById("gc179ImportFileInput").addEventListener("change", event => {
  const file = event.target.files && event.target.files[0] ? event.target.files[0] : null;
  syncGc179ImportFilePicker(file);
});
document.getElementById("gc179ImportForm").addEventListener("change", () => {
  setGc179ImportMessage("");
  resetGc179ImportPreview();
});
document.getElementById("employeeEditorRemoveButton").addEventListener("click", async event => {
  const triggerButton = event.currentTarget;
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  await runButtonAction(triggerButton, async () => {
    const removed = await removeEmployee(employee);
    if (removed) {
      const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
      if (modal) {
        modal.hide();
      }
    }
  }, { key: "employee-editor-mutation" });
});
document.getElementById("employeeEditorRestoreButton").addEventListener("click", async event => {
  const triggerButton = event.currentTarget;
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  await runButtonAction(triggerButton, async () => {
    const restored = await restoreEmployee(employee);
    if (restored) {
      const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
      if (modal) {
        modal.hide();
      }
    }
  }, { key: "employee-editor-mutation" });
});
document.getElementById("employeeEditorSaveButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, submitEmployeeEditor, { key: "employee-editor-mutation" });
});
document.getElementById("employeeEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  runButtonAction(event.submitter || document.getElementById("employeeEditorSaveButton"), submitEmployeeEditor, {
    key: "employee-editor-mutation",
  });
});
document.getElementById("employeeEditorRoleSelect").addEventListener("change", syncEmployeeEditorProjectAssignmentsPanel);
document.getElementById("employeeEditorProjectSearchInput").addEventListener("input", event => {
  employeesViewState.editorProjectAssignments.search = event.target.value || "";
  renderEmployeeEditorProjectAssignments();
});
document.getElementById("employeeEditorForm").addEventListener("change", event => {
  if (!event.target.classList.contains("employee-time-entry-type-checkbox")) {
    return;
  }

  if (!document.querySelector(".employee-time-entry-type-checkbox:checked")) {
    event.target.checked = true;
  }
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
document.getElementById("employeesSearchInput").addEventListener("input", scheduleEmployeeSearchFilter);
document.getElementById("employeesScopeSelect").addEventListener("change", applyEmployeeScopeFilterFromState);
document.getElementById("employeesProjectSelect").addEventListener("change", () => {
  employeesViewState.selectedProjectCode = getEmployeesProjectFilterValue();
  employeesViewState.autoOpenProjectCode = employeesViewState.selectedProjectCode;
  applyEmployeeSearchFilter();
});
document.getElementById("employeesResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("employeesSearchInput").value = "";
  document.getElementById("employeesScopeSelect").value = "active";
  document.getElementById("employeesProjectSelect").value = "";
  employeesViewState.selectedProjectCode = "";
  employeesViewState.autoOpenProjectCode = "";
  applyEmployeeScopeFilterFromState();
});
document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", 0);
