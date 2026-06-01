const projectDetailCache = {};
let currentProjectFilter = "6M";
let currentProjectCode = null;
let pendingProjectChartFrameId = null;
const projectsViewState = {
  projects: [],
  employees: [],
  editorAssignments: {
    admins: new Set(),
    backupAdmins: new Set(),
    adminsSearch: "",
    backupAdminsSearch: "",
  },
  customRange: {
    startDate: "",
    endDate: "",
  },
};

function canManageProjects() {
  return typeof isSuperAdminUser === "function" && isSuperAdminUser();
}

function formatProjectAdminDisplay(displayItems, fallbackCodes) {
  const items = Array.isArray(displayItems) ? displayItems : [];
  if (items.length > 0) {
    return items.map(item => {
      const code = String(item && item.code ? item.code : "").trim();
      const name = String(item && item.name ? item.name : code).trim();
      return code && name && name !== code ? `${name} (${code})` : (name || code);
    }).filter(Boolean);
  }

  return (Array.isArray(fallbackCodes) ? fallbackCodes : [])
    .map(code => String(code || "").trim())
    .filter(Boolean);
}

function renderProjectAdminMeta(labelKey, displayItems, fallbackCodes, className = "") {
  const labels = formatProjectAdminDisplay(displayItems, fallbackCodes);
  if (labels.length === 0) {
    return "";
  }

  const extraClass = className ? ` ${className}` : "";
  return `<span class="meta-pill${extraClass}">${escapeHtml(t(labelKey))}: ${escapeHtml(labels.join(", "))}</span>`;
}

async function ensureProjectEditorEmployees(forceRefresh = false) {
  if (!forceRefresh && projectsViewState.employees.length > 0) {
    return;
  }

  const response = await fetch(apiUrl + "employees?scope=all");
  const employees = await parseResponse(response);
  projectsViewState.employees = Array.isArray(employees) ? employees : [];
}

function normalizeAssignmentCodes(codes) {
  return new Set((Array.isArray(codes) ? codes : [])
    .map(code => String(code || "").trim())
    .filter(Boolean));
}

function getProjectEditorAssignmentKindConfig(kind) {
  if (kind === "backupAdmins") {
    return {
      selected: projectsViewState.editorAssignments.backupAdmins,
      searchValue: projectsViewState.editorAssignments.backupAdminsSearch,
      inputClass: "project-editor-backup-admin-checkbox",
      listId: "projectEditorBackupAdminsList",
      emptyKey: "projects.noMatchingEmployees",
    };
  }

  return {
    selected: projectsViewState.editorAssignments.admins,
    searchValue: projectsViewState.editorAssignments.adminsSearch,
    inputClass: "project-editor-admin-checkbox",
    listId: "projectEditorAdminsList",
    emptyKey: "projects.noMatchingEmployees",
  };
}

function employeeMatchesProjectEditorSearch(employee, searchValue) {
  const normalizedSearch = String(searchValue || "").trim().toLowerCase();
  if (!normalizedSearch) {
    return true;
  }

  const code = String(employee && employee.code ? employee.code : "");
  const name = String(employee && employee.name ? employee.name : "");
  return `${code} ${name}`.toLowerCase().includes(normalizedSearch);
}

function renderProjectEditorAssignmentList(kind) {
  const config = getProjectEditorAssignmentKindConfig(kind);
  const container = document.getElementById(config.listId);
  if (!container) {
    return;
  }

  const employees = (projectsViewState.employees || []).filter(employee => employeeMatchesProjectEditorSearch(employee, config.searchValue));
  if (employees.length === 0) {
    container.innerHTML = createEmptyState(t(config.emptyKey));
    return;
  }

  container.innerHTML = employees.map(employee => {
    const code = String(employee.code || "");
    const name = String(employee.name || code);
    const inputId = `${config.listId}_${code}`.replace(/[^A-Za-z0-9_-]/g, "_");
    const checked = config.selected.has(code) ? " checked" : "";
    const role = typeof normalizeClientRole === "function" ? normalizeClientRole(employee.role || "employee") : "employee";
    const roleLabel = t(`employees.role.${role}`);
    const archived = employee.archived ? ` | ${t("employees.archived")}` : "";
    return `
      <label class="assignment-checkitem" for="${escapeHtml(inputId)}">
        <input class="form-check-input ${config.inputClass}" type="checkbox" id="${escapeHtml(inputId)}" value="${escapeHtml(code)}" data-assignment-kind="${escapeHtml(kind)}"${checked}>
        <span class="assignment-checkitem-main">
          <span class="assignment-checkitem-title">${escapeHtml(name)}</span>
          <span class="assignment-checkitem-meta">${escapeHtml(code)} | ${escapeHtml(roleLabel)}${escapeHtml(archived)}</span>
        </span>
      </label>
    `;
  }).join("");
}

function renderProjectEditorAssignmentLists() {
  renderProjectEditorAssignmentList("admins");
  renderProjectEditorAssignmentList("backupAdmins");
}

function getProjectEditorAssignmentCodes(kind) {
  const config = getProjectEditorAssignmentKindConfig(kind);
  return Array.from(config.selected).filter(Boolean).sort();
}

function setProjectEditorMessage(message, type) {
  const messageBox = document.getElementById("projectEditorMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function resetProjectEditorForm() {
  document.getElementById("projectEditorMode").value = "create";
  document.getElementById("projectEditorModalLabel").textContent = t("projects.addProject");
  document.getElementById("projectEditorCodeInput").value = "";
  document.getElementById("projectEditorCodeInput").readOnly = false;
  document.getElementById("projectEditorNameInput").value = "";
  document.getElementById("projectEditorSectorInput").value = "";
  projectsViewState.editorAssignments.admins = new Set();
  projectsViewState.editorAssignments.backupAdmins = new Set();
  projectsViewState.editorAssignments.adminsSearch = "";
  projectsViewState.editorAssignments.backupAdminsSearch = "";
  document.getElementById("projectEditorAdminsSearchInput").value = "";
  document.getElementById("projectEditorBackupAdminsSearchInput").value = "";
  document.getElementById("projectEditorAdminsList").innerHTML = "";
  document.getElementById("projectEditorBackupAdminsList").innerHTML = "";
  document.getElementById("projectEditorRemoveButton").classList.add("d-none");
  setProjectEditorMessage("");
}

async function openProjectEditorModal(mode, project) {
  resetProjectEditorForm();
  await ensureProjectEditorEmployees(true);

  const admins = project && Array.isArray(project.admins) ? project.admins : [];
  const backupAdmins = project && Array.isArray(project.backupAdmins) ? project.backupAdmins : [];
  projectsViewState.editorAssignments.admins = normalizeAssignmentCodes(admins);
  projectsViewState.editorAssignments.backupAdmins = normalizeAssignmentCodes(backupAdmins);
  renderProjectEditorAssignmentLists();

  if (mode === "edit" && project) {
    document.getElementById("projectEditorMode").value = "edit";
    document.getElementById("projectEditorModalLabel").textContent = t("projects.editProject");
    document.getElementById("projectEditorCodeInput").value = project.projectCode || "";
    document.getElementById("projectEditorCodeInput").readOnly = true;
    document.getElementById("projectEditorNameInput").value = project.projectName || "";
    document.getElementById("projectEditorSectorInput").value = project.sector || "";
    document.getElementById("projectEditorRemoveButton").classList.toggle("d-none", Boolean(project.archived));
  }

  const modal = new bootstrap.Modal(document.getElementById("projectEditorModal"));
  modal.show();
}

function getProjectByCode(projectCode) {
  return projectsViewState.projects.find(project => project.projectCode === projectCode) || null;
}

function ensureProjectChartCanvas() {
  const chartStage = document.querySelector("#projectChartContainer .chart-stage");
  if (!chartStage) {
    return null;
  }

  let canvas = document.getElementById("projectMultiLineChart");
  if (!canvas) {
    chartStage.innerHTML = '<canvas id="projectMultiLineChart"></canvas>';
    canvas = document.getElementById("projectMultiLineChart");
  }

  return canvas;
}

function clearProjectDetailCache() {
  Object.keys(projectDetailCache).forEach(cacheKey => {
    delete projectDetailCache[cacheKey];
  });
}

function getProjectDetailCacheKey(projectCode, filterPeriod) {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  return `${projectCode}_${filterPeriod}_${startDate || "all"}_${endDate || "all"}`;
}

function calculateDateRange(filterPeriod) {
  const normalizedFilter = filterPeriod || currentProjectFilter;
  const now = new Date();
  const endDate = now.toISOString().split("T")[0];
  let startDate = "";
  let resolvedEndDate = endDate;

  switch (normalizedFilter) {
    case "1M":
      startDate = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString().split("T")[0];
      break;
    case "6M":
      startDate = new Date(now.getFullYear(), now.getMonth() - 6, 1).toISOString().split("T")[0];
      break;
    case "1Y":
      startDate = new Date(now.getFullYear() - 1, now.getMonth(), now.getDate()).toISOString().split("T")[0];
      break;
    case "custom":
      startDate = normalizeDateInputValue(projectsViewState.customRange.startDate);
      resolvedEndDate = normalizeDateInputValue(projectsViewState.customRange.endDate);
      break;
    case "all":
    default:
      startDate = "";
      resolvedEndDate = "";
      break;
  }

  return { startDate, endDate: resolvedEndDate };
}

function syncProjectCustomRangeInputs() {
  const activeRange = calculateDateRange(currentProjectFilter);
  if (currentProjectFilter === "custom") {
    document.getElementById("projectStartDate").value = projectsViewState.customRange.startDate || "";
    document.getElementById("projectEndDate").value = projectsViewState.customRange.endDate || "";
    return;
  }

  document.getElementById("projectStartDate").value = activeRange.startDate || "";
  document.getElementById("projectEndDate").value = activeRange.endDate || "";
}

function syncProjectRangeButtons() {
  document.querySelectorAll("#projectQuickRangeButtons .chip-button").forEach(button => {
    button.classList.toggle("active", button.getAttribute("data-range") === currentProjectFilter);
  });
}

function getMatchingPresetProjectRange(startDate, endDate) {
  const normalizedStartDate = normalizeDateInputValue(startDate);
  const normalizedEndDate = normalizeDateInputValue(endDate);

  const supportedRanges = ["all", "1M", "6M", "1Y"];
  for (let index = 0; index < supportedRanges.length; index += 1) {
    const range = supportedRanges[index];
    const candidate = calculateDateRange(range);
    const candidateStart = normalizeDateInputValue(candidate.startDate);
    const candidateEnd = normalizeDateInputValue(candidate.endDate);
    if (candidateStart === normalizedStartDate && candidateEnd === normalizedEndDate) {
      return range;
    }
  }

  return "custom";
}

async function setProjectRange(range) {
  currentProjectFilter = range;
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  await refreshProjectsView();
}

function buildProjectBootstrapUrl(filterPeriod, projectCode) {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  const params = new URLSearchParams();

  if (startDate) {
    params.set("startDate", startDate);
  }
  if (endDate) {
    params.set("endDate", endDate);
  }
  if (projectCode) {
    params.set("projectCode", projectCode);
  }

  const query = params.toString();
  return `${apiUrl}projects/bootstrap${query ? `?${query}` : ""}`;
}

function buildProjectStatsUrl(projectCode, filterPeriod) {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  const params = new URLSearchParams();
  if (startDate) {
    params.set("startDate", startDate);
  }
  if (endDate) {
    params.set("endDate", endDate);
  }
  const query = params.toString();
  return `${apiUrl}stats/projects/${projectCode}${query ? `?${query}` : ""}`;
}

async function loadProjectDetailStats(projectCode, filterPeriod = "all") {
  const cacheKey = getProjectDetailCacheKey(projectCode, filterPeriod);
  if (projectDetailCache[cacheKey]) {
    renderProjectDetail(projectDetailCache[cacheKey]);
    return;
  }

  try {
    setLoadingState("projectDetailContainer", "detail", 1);
    const response = await fetch(buildProjectStatsUrl(projectCode, filterPeriod));
    const data = await parseResponse(response);
    projectDetailCache[cacheKey] = data;
    renderProjectDetail(data);
  } catch (error) {
    console.error("Error loading project detail stats:", error);
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.statsUnavailable"));
  }
}

async function refreshProjectsView() {
  clearProjectDetailCache();
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  const addButton = document.getElementById("addProjectButton");
  if (addButton) {
    addButton.classList.toggle("d-none", !canManageProjects());
  }
  setLoadingState("projectsSummaryContainer", "grid", 4);
  setLoadingState("projectDetailContainer", "detail", 1);
  setChartLoadingState("projectChartContainer");

  try {
    const response = await fetch(buildProjectBootstrapUrl(currentProjectFilter, currentProjectCode));
    const payload = await parseResponse(response);
    const summary = Array.isArray(payload && payload.summary) ? payload.summary : [];
    projectsViewState.projects = summary;

    currentProjectCode = payload && payload.selectedProjectCode ? payload.selectedProjectCode : (summary[0] ? summary[0].projectCode : null);

    renderProjectSummaryCards(summary);
    renderProjectMultiLineChart(payload && payload.trends ? payload.trends : {});

    if (payload && payload.selectedProject) {
      projectDetailCache[getProjectDetailCacheKey(payload.selectedProject.projectCode, currentProjectFilter)] = payload.selectedProject;
      renderProjectDetail(payload.selectedProject);
    } else if (currentProjectCode) {
      await loadProjectDetailStats(currentProjectCode, currentProjectFilter);
    } else {
      document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.selectToInspect"));
    }
  } catch (error) {
    console.error("Error loading project data:", error);
    document.getElementById("projectsSummaryContainer").innerHTML = createEmptyState(t("projects.unableToLoad"));
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.statsUnavailable"));
    const chartStage = document.querySelector("#projectChartContainer .chart-stage");
    if (chartStage) {
      chartStage.innerHTML = createEmptyState(t("projects.chartLoadError"));
    }
  }
}

function renderProjectSummaryCards(projectDetails) {
  const container = document.getElementById("projectsSummaryContainer");
  if (!projectDetails || projectDetails.length === 0) {
    container.innerHTML = createEmptyState(t("projects.noStats"));
    return;
  }

  container.innerHTML = projectDetails.map(detail => {
    const total = secondsToDurationLabel(timeStringToSeconds(detail.totalOvertime || "00:00:00"));
    const minValue = secondsToDurationLabel(timeStringToSeconds(detail.minOvertime || "00:00:00"));
    const maxValue = secondsToDurationLabel(timeStringToSeconds(detail.maxOvertime || "00:00:00"));
    const admins = Array.isArray(detail.admins) ? detail.admins : [];
    const backupAdmins = Array.isArray(detail.backupAdmins) ? detail.backupAdmins : [];
    const archivedBadge = detail.archived ? `<span class="status-badge rejected">${escapeHtml(t("projects.archived"))}</span>` : "";
    return `
      <article class="project-summary-card${currentProjectCode === detail.projectCode ? " is-active" : ""}${detail.archived ? " is-archived" : ""}" data-project-code="${escapeHtml(detail.projectCode)}">
        <div class="project-card-header">
          <div>
            <div class="project-card-title">${escapeHtml(detail.projectName)}</div>
            <div class="employee-card-note">${escapeHtml([detail.projectCode, detail.sector].filter(Boolean).join(" | "))}</div>
          </div>
          <div class="project-card-status-stack">
            ${archivedBadge}
            <span class="inline-code-pill">${escapeHtml(total)}</span>
          </div>
        </div>
        <div class="project-card-meta">
          <span class="meta-pill">${escapeHtml(t("projects.entries", { count: detail.entryCount }))}</span>
          <span class="meta-pill">${escapeHtml(t("projects.min", { value: minValue }))}</span>
          <span class="meta-pill">${escapeHtml(t("projects.max", { value: maxValue }))}</span>
          ${renderProjectAdminMeta("projects.admins", detail.adminDisplay, admins, "meta-pill-owner")}
          ${renderProjectAdminMeta("projects.backupAdmins", detail.backupAdminDisplay, backupAdmins)}
        </div>
        <div class="employee-card-actions${canManageProjects() ? "" : " d-none"}">
          <button type="button" class="btn btn-outline-secondary btn-sm project-edit-button" data-project-code="${escapeHtml(detail.projectCode)}">${escapeHtml(t("action.edit"))}</button>
        </div>
      </article>
    `;
  }).join("");
}

function renderProjectEmployeeEntries(entries) {
  if (!entries || entries.length === 0) {
    return createEmptyState(t("projects.noEntriesForEmployee"));
  }

  return `
    <div class="project-entry-list">
      <div class="project-entry-list-header">
        <span>${escapeHtml(t("modal.date"))}</span>
        <span>${escapeHtml(t("projects.timeRange"))}</span>
        <span>${escapeHtml(t("projects.overtimeLabel"))}</span>
      </div>
      ${entries.map(entry => {
        const exactTimeLabel = getEntryExactTimeLabel(entry);
        return `
          <div class="project-entry-row">
            <span class="project-entry-date">${escapeHtml(formatDateLabel(entry.date))}</span>
            <span class="project-entry-time mono">
              ${getEntryRoundedTimeRangeMarkup(entry)}
              ${exactTimeLabel ? `<span class="panel-note d-block">${escapeHtml(exactTimeLabel)}</span>` : ""}
            </span>
            <span class="project-entry-overtime mono">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(entry.overtime)))}</span>
          </div>
        `;
      }).join("")}
    </div>
  `;
}

function renderProjectDetail(detail) {
  const container = document.getElementById("projectDetailContainer");
  if (!detail) {
    container.innerHTML = createEmptyState(t("projects.selectToInspect"));
    return;
  }

  const touchedBy = (detail.breakdownByEmployee && detail.breakdownByEmployee.length) || 0;
  const total = detail.totalOvertime ? secondsToDurationLabel(timeStringToSeconds(detail.totalOvertime)) : "00h 00";
  const minValue = detail.minOvertime ? secondsToDurationLabel(timeStringToSeconds(detail.minOvertime)) : "00h 00";
  const maxValue = detail.maxOvertime ? secondsToDurationLabel(timeStringToSeconds(detail.maxOvertime)) : "00h 00";
  const admins = Array.isArray(detail.admins) ? detail.admins : [];
  const backupAdmins = Array.isArray(detail.backupAdmins) ? detail.backupAdmins : [];

  container.innerHTML = `
    <article class="project-detail-card">
      <div class="project-detail-title">
        <h4 class="m-0">${escapeHtml(detail.projectName || detail.projectCode)}</h4>
        <span class="inline-code-pill">${escapeHtml(detail.projectCode)}</span>
        ${detail.archived ? `<span class="status-badge rejected">${escapeHtml(t("projects.archived"))}</span>` : ""}
      </div>
      <div class="project-card-meta">
        ${detail.sector ? `<span class="meta-pill">${escapeHtml(t("projects.sector"))}: ${escapeHtml(detail.sector)}</span>` : ""}
        ${renderProjectAdminMeta("projects.admins", detail.adminDisplay, admins, "meta-pill-owner")}
        ${renderProjectAdminMeta("projects.backupAdmins", detail.backupAdminDisplay, backupAdmins)}
      </div>
      <div class="project-summary">
        <div class="project-summary-item">
          <span class="metric-label">${escapeHtml(t("projects.totalOvertime"))}</span>
          <strong class="metric-value mono">${escapeHtml(total)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">${escapeHtml(t("projects.entriesLabel"))}</span>
          <strong class="metric-value mono">${escapeHtml(detail.entryCount)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">${escapeHtml(t("projects.minLabel"))}</span>
          <strong class="metric-value mono">${escapeHtml(minValue)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">${escapeHtml(t("projects.maxLabel"))}</span>
          <strong class="metric-value mono">${escapeHtml(maxValue)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">${escapeHtml(t("projects.contributors"))}</span>
          <strong class="metric-value mono">${escapeHtml(touchedBy)}</strong>
        </div>
      </div>
      <div class="employee-breakdown">
        <h5>${escapeHtml(t("projects.employeeBreakdown"))}</h5>
        ${detail.breakdownByEmployee && detail.breakdownByEmployee.length > 0 ? `
          <div class="accordion project-breakdown-accordion" id="employeeAccordion">
            ${detail.breakdownByEmployee.map((employee, index) => {
              const collapseId = `projectEmployeeCollapse${index}`;
              return `
                <div class="accordion-item">
                  <h2 class="accordion-header" id="projectHeading${index}">
                    <button class="accordion-button collapsed" type="button" data-bs-toggle="collapse" data-bs-target="#${collapseId}" aria-expanded="false" aria-controls="${collapseId}">
                      <span class="project-breakdown-heading">
                        <span class="project-breakdown-name">${escapeHtml(employee.employee)}</span>
                        <span class="project-breakdown-meta">
                          <span class="meta-pill">${escapeHtml(t("projects.entries", { count: employee.entryCount }))}</span>
                          <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(employee.overtime)))}</span>
                        </span>
                      </span>
                    </button>
                  </h2>
                  <div id="${collapseId}" class="accordion-collapse collapse" aria-labelledby="projectHeading${index}" data-bs-parent="#employeeAccordion">
                    <div class="accordion-body">
                      <div class="project-breakdown-actions">
                        <button type="button" class="btn btn-outline-secondary btn-sm project-people-navigator" data-employee-code="${escapeHtml(employee.employeeCode || "")}" data-project-code="${escapeHtml(detail.projectCode)}">
                          <i class="fa-solid fa-arrow-up-right-from-square"></i> ${escapeHtml(t("projects.openInPeople"))}
                        </button>
                      </div>
                      ${renderProjectEmployeeEntries(employee.entries)}
                    </div>
                  </div>
                </div>
              `;
            }).join("")}
          </div>
        ` : createEmptyState(t("projects.noEntriesForProject"))}
      </div>
    </article>
  `;
}

async function submitProjectEditor() {
  setProjectEditorMessage("");

  const mode = document.getElementById("projectEditorMode").value;
  const projectCode = document.getElementById("projectEditorCodeInput").value.trim();
  const projectName = document.getElementById("projectEditorNameInput").value.trim();
  const sector = document.getElementById("projectEditorSectorInput").value.trim();
  const admins = getProjectEditorAssignmentCodes("admins");
  const backupAdmins = getProjectEditorAssignmentCodes("backupAdmins");
  const existingProject = getProjectByCode(projectCode);

  if (!projectCode || !projectName) {
    setProjectEditorMessage(t("projects.codeAndNameRequired"), "danger");
    return;
  }

  try {
    const response = await fetch(mode === "create" ? apiUrl + "projects" : apiUrl + "projects/" + encodeURIComponent(projectCode), {
      method: mode === "create" ? "POST" : "PUT",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        projectCode,
        projectName,
        sector,
        admins,
        backupAdmins,
        archived: existingProject ? Boolean(existingProject.archived) : false,
      }),
    });

    await parseResponse(response);
    if (typeof fetchOvertimeEntryLookups === "function") {
      await fetchOvertimeEntryLookups(true);
    }
    if (typeof fetchScopedProjects === "function") {
      await fetchScopedProjects(true);
    }
    const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
    if (modal) {
      modal.hide();
    }
    resetProjectEditorForm();
    showToast(t(mode === "create" ? "projects.projectCreated" : "projects.projectUpdated"), "success");
    await refreshProjectsView();
  } catch (error) {
    console.error("Error saving project:", error);
    setProjectEditorMessage(error.message || t(mode === "create" ? "projects.createError" : "projects.updateError"), "danger");
  }
}

async function archiveProject(project) {
  if (!project || !project.projectCode) {
    return;
  }

  const confirmed = window.confirm(t("projects.archiveConfirm", { name: project.projectName, code: project.projectCode }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(project.projectCode), {
      method: "DELETE",
    });
    await parseResponse(response);
    if (typeof fetchOvertimeEntryLookups === "function") {
      await fetchOvertimeEntryLookups(true);
    }
    if (typeof fetchScopedProjects === "function") {
      await fetchScopedProjects(true);
    }
    if (currentProjectCode === project.projectCode) {
      currentProjectCode = null;
    }
    showToast(t("projects.projectArchived"), "success");
    await refreshProjectsView();
  } catch (error) {
    console.error("Error archiving project:", error);
    showToast(error.message || t("projects.archiveError"), "error");
  }
}

function renderProjectMultiLineChart(trendData) {
  const canvas = ensureProjectChartCanvas();
  if (!canvas) {
    return;
  }

  if (typeof Chart !== "function") {
    const chartContainer = document.getElementById("projectChartContainer");
    if (chartContainer) {
      chartContainer.querySelector(".chart-stage").innerHTML = createEmptyState(t("projects.chartLibraryFailed"));
    }
    return;
  }

  if (pendingProjectChartFrameId) {
    window.cancelAnimationFrame(pendingProjectChartFrameId);
    pendingProjectChartFrameId = null;
  }

  const labelSet = new Set();
  Object.keys(trendData || {}).forEach(projectCode => {
    trendData[projectCode].forEach(item => labelSet.add(item.month));
  });

  const timeLabels = Array.from(labelSet).sort();
  const formattedLabels = timeLabels.map(formatYMToWords);
  const colors = ["#3574f0", "#46a35b", "#d18900", "#d14343", "#7d5cf5", "#0096b2"];

  const datasets = Object.keys(trendData || {}).map((projectCode, index) => {
    const dataPoints = timeLabels.map(label => {
      const entry = trendData[projectCode].find(item => item.month === label);
      return entry ? entry.overtime : 0;
    });

    return {
      label: projectCode,
      data: dataPoints,
      borderColor: colors[index % colors.length],
      backgroundColor: colors[index % colors.length],
      fill: false,
      tension: 0.28,
      borderWidth: 2,
      pointRadius: 3,
      pointHoverRadius: 5,
    };
  });

  pendingProjectChartFrameId = window.requestAnimationFrame(() => {
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      pendingProjectChartFrameId = null;
      return;
    }

    if (window.projectChartInstance) {
      window.projectChartInstance.destroy();
    }

    window.projectChartInstance = new Chart(ctx, {
      type: "line",
      data: {
        labels: formattedLabels,
        datasets,
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: {
            position: "top",
            labels: {
              color: "#5f6673",
              usePointStyle: true,
              boxWidth: 8,
            },
          },
          tooltip: {
            backgroundColor: "rgba(31, 35, 41, 0.92)",
            titleColor: "#ffffff",
            bodyColor: "#ffffff",
          },
        },
        scales: {
          x: {
            ticks: {
              color: "#7f8796",
            },
            grid: {
              color: "rgba(31, 35, 41, 0.06)",
            },
          },
          y: {
            beginAtZero: true,
            ticks: {
              color: "#7f8796",
            },
            grid: {
              color: "rgba(31, 35, 41, 0.08)",
            },
          },
        },
      },
    });

    if (window.projectChartInstance && typeof window.projectChartInstance.resize === "function") {
      window.projectChartInstance.resize();
    }

    pendingProjectChartFrameId = null;
  });
}

document.getElementById("projectsSummaryContainer").addEventListener("click", event => {
  const editButton = event.target.closest(".project-edit-button");
  if (editButton) {
    event.stopPropagation();
    const project = getProjectByCode(editButton.getAttribute("data-project-code"));
    if (project) {
      openProjectEditorModal("edit", project).catch(error => {
        console.error("Unable to open project editor:", error);
        showToast(t("projects.unableToLoad"), "error");
      });
    }
    return;
  }

  const projectCard = event.target.closest(".project-summary-card");
  if (!projectCard) {
    return;
  }

  const projectCode = projectCard.getAttribute("data-project-code");
  if (projectCode) {
    currentProjectCode = projectCode;
    renderProjectSummaryCards(projectsViewState.projects);
    loadProjectDetailStats(projectCode, currentProjectFilter);
  }
});

document.getElementById("projectDetailContainer").addEventListener("click", event => {
  const navigatorButton = event.target.closest(".project-people-navigator");
  if (!navigatorButton) {
    return;
  }

  const employeeCode = navigatorButton.getAttribute("data-employee-code");
  const projectCode = navigatorButton.getAttribute("data-project-code");
  if (typeof window.openPeopleProjectFilter === "function") {
    window.openPeopleProjectFilter(employeeCode, projectCode);
  }
});

document.getElementById("projectQuickRangeButtons").addEventListener("click", event => {
  const rangeButton = event.target.closest(".chip-button");
  if (!rangeButton) {
    return;
  }

  const nextRange = rangeButton.getAttribute("data-range");
  if (!nextRange || nextRange === currentProjectFilter) {
    return;
  }

  setProjectRange(nextRange);
});
document.getElementById("projectApplyCustomRangeButton").addEventListener("click", () => {
  const startDate = document.getElementById("projectStartDate").value;
  const endDate = document.getElementById("projectEndDate").value;
  if (startDate && endDate && startDate > endDate) {
    showToast(t("filters.invalidRange"), "error");
    return;
  }
  projectsViewState.customRange.startDate = startDate;
  projectsViewState.customRange.endDate = endDate;
  currentProjectFilter = getMatchingPresetProjectRange(startDate, endDate);
  syncProjectRangeButtons();
  refreshProjectsView();
});
document.getElementById("projectClearCustomRangeButton").addEventListener("click", () => {
  projectsViewState.customRange.startDate = "";
  projectsViewState.customRange.endDate = "";
  setProjectRange("6M");
});
document.getElementById("addProjectButton").addEventListener("click", () => {
  openProjectEditorModal("create").catch(error => {
    console.error("Unable to open project editor:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});
document.getElementById("projectEditorRemoveButton").addEventListener("click", async () => {
  const project = getProjectByCode(document.getElementById("projectEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
  if (modal) {
    modal.hide();
  }
  await archiveProject(project);
});
document.getElementById("projectEditorAdminsSearchInput").addEventListener("input", event => {
  projectsViewState.editorAssignments.adminsSearch = event.target.value || "";
  renderProjectEditorAssignmentList("admins");
});
document.getElementById("projectEditorBackupAdminsSearchInput").addEventListener("input", event => {
  projectsViewState.editorAssignments.backupAdminsSearch = event.target.value || "";
  renderProjectEditorAssignmentList("backupAdmins");
});
document.getElementById("projectEditorAdminsList").addEventListener("change", event => {
  const checkbox = event.target.closest(".project-editor-admin-checkbox");
  if (!checkbox) {
    return;
  }
  const employeeCode = String(checkbox.value || "").trim();
  if (!employeeCode) {
    return;
  }
  if (checkbox.checked) {
    projectsViewState.editorAssignments.admins.add(employeeCode);
  } else {
    projectsViewState.editorAssignments.admins.delete(employeeCode);
  }
});
document.getElementById("projectEditorBackupAdminsList").addEventListener("change", event => {
  const checkbox = event.target.closest(".project-editor-backup-admin-checkbox");
  if (!checkbox) {
    return;
  }
  const employeeCode = String(checkbox.value || "").trim();
  if (!employeeCode) {
    return;
  }
  if (checkbox.checked) {
    projectsViewState.editorAssignments.backupAdmins.add(employeeCode);
  } else {
    projectsViewState.editorAssignments.backupAdmins.delete(employeeCode);
  }
});
document.getElementById("projectEditorSaveButton").addEventListener("click", submitProjectEditor);
document.getElementById("projectEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  submitProjectEditor();
});
