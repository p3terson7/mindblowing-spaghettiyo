const projectDetailCache = {};
let currentProjectFilter = "6M";
let currentProjectCode = null;
let pendingProjectChartFrameId = null;
let pendingProjectInsightFrameId = null;
let pendingProjectDetailTimerId = null;
let pendingProjectDetailRequest = null;
let projectDetailRequestVersion = 0;
let projectPortfolioSearchTimerId = null;
const PROJECT_DETAIL_REQUEST_DELAY_MS = 90;
const PROJECT_PORTFOLIO_SEARCH_DEBOUNCE_MS = 140;
const projectInsightChartInstances = {};
const projectPalette = ["#0868d7", "#16865a", "#7558d8", "#008994", "#c27a00", "#c43840", "#c94f8a", "#4f72d8", "#7f6b52"];
const projectsViewState = {
  projects: [],
  employees: [],
  trends: {},
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
  portfolioSearch: "",
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

function getProjectPersonInitials(nameOrCode) {
  const parts = String(nameOrCode || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return "--";
  }

  if (parts.length === 1) {
    return parts[0].slice(0, 2).toUpperCase();
  }

  return `${parts[0].slice(0, 1)}${parts[parts.length - 1].slice(0, 1)}`.toUpperCase();
}

function formatProjectAssignmentPeople(displayItems, fallbackCodes) {
  const items = Array.isArray(displayItems) ? displayItems : [];
  if (items.length > 0) {
    return items.map(item => {
      const code = String(item && item.code ? item.code : "").trim();
      const name = String(item && item.name ? item.name : code).trim();
      return {
        code,
        name: name || code,
        label: code && name && name !== code ? `${name} (${code})` : (name || code),
      };
    }).filter(person => person.label);
  }

  return (Array.isArray(fallbackCodes) ? fallbackCodes : [])
    .map(code => String(code || "").trim())
    .filter(Boolean)
    .map(code => ({ code, name: code, label: code }));
}

function renderProjectAdminMeta(labelKey, displayItems, fallbackCodes, className = "") {
  const labels = formatProjectAdminDisplay(displayItems, fallbackCodes);
  if (labels.length === 0) {
    return "";
  }

  const extraClass = className ? ` ${className}` : "";
  return `<span class="meta-pill${extraClass}">${escapeHtml(t(labelKey))}: ${escapeHtml(labels.join(", "))}</span>`;
}

function renderProjectAssignmentLine(labelKey, displayItems, fallbackCodes) {
  const people = formatProjectAssignmentPeople(displayItems, fallbackCodes);
  if (people.length === 0) {
    return "";
  }

  const label = t(labelKey);
  const title = `${label}: ${people.map(person => person.label).join(", ")}`;
  return `
    <div class="project-assignment-line" title="${escapeHtml(title)}">
      <div class="project-assignment-label">${escapeHtml(label)}</div>
      <div class="project-assignment-people">
        ${people.map(person => `
          <span class="project-assignment-person">
            <span class="project-person-avatar">${escapeHtml(getProjectPersonInitials(person.name || person.code))}</span>
            <span class="project-person-text">${escapeHtml(person.label)}</span>
          </span>
        `).join("")}
      </div>
    </div>
  `;
}

function getProjectPortfolioSearchValue() {
  const input = document.getElementById("projectPortfolioSearchInput");
  return String(input && input.value || "").trim().toLowerCase();
}

function projectMatchesPortfolioSearch(project) {
  const searchValue = String(projectsViewState.portfolioSearch || "").trim().toLowerCase();
  if (!searchValue) {
    return true;
  }

  const adminLabels = formatProjectAdminDisplay(project && project.adminDisplay, project && project.admins).join(" ");
  const backupLabels = formatProjectAdminDisplay(project && project.backupAdminDisplay, project && project.backupAdmins).join(" ");
  const haystack = [
    project && project.projectCode,
    project && project.projectName,
    project && project.sector,
    adminLabels,
    backupLabels,
  ].map(value => String(value || "").toLowerCase()).join(" ");

  return searchValue.split(/\s+/).every(token => haystack.includes(token));
}

function getVisibleProjectSummaries(projects) {
  return (Array.isArray(projects) ? projects : []).filter(project => projectMatchesPortfolioSearch(project));
}

function getCurrentProjectUserRole() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  return user ? normalizeClientRole(user.role) : "employee";
}

function getCurrentProjectUserEmployeeCode() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  return user && user.employeeCode ? String(user.employeeCode).trim() : "";
}

function isProjectManagedByCurrentAdmin(project) {
  const role = getCurrentProjectUserRole();
  if (role === "superAdmin") {
    return true;
  }

  const employeeCode = getCurrentProjectUserEmployeeCode();
  if (role !== "admin" || !employeeCode) {
    return false;
  }

  if (project && project.canModify === true) {
    return true;
  }

  const admins = Array.isArray(project && project.admins)
    ? project.admins.map(code => String(code || "").trim())
    : [];
  const backupAdmins = Array.isArray(project && project.backupAdmins)
    ? project.backupAdmins.map(code => String(code || "").trim())
    : [];
  return admins.indexOf(employeeCode) >= 0 || backupAdmins.indexOf(employeeCode) >= 0;
}

function shouldSectionProjectSummary() {
  return getCurrentProjectUserRole() === "admin";
}

function getProjectSummarySections(projects) {
  const sourceProjects = Array.isArray(projects) ? projects : [];
  if (!shouldSectionProjectSummary()) {
    return [
      {
        key: "all",
        title: "",
        projects: sourceProjects,
      },
    ];
  }

  const managedProjects = [];
  const otherProjects = [];
  sourceProjects.forEach(project => {
    if (isProjectManagedByCurrentAdmin(project)) {
      managedProjects.push(project);
    } else {
      otherProjects.push(project);
    }
  });

  return [
    {
      key: "managed",
      title: t("projects.sectionMyProjects"),
      projects: managedProjects,
    },
    {
      key: "other",
      title: t("projects.sectionOtherProjects"),
      projects: otherProjects,
    },
  ].filter(section => section.projects.length > 0);
}

function getProjectSummaryDisplayOrder(projects) {
  return getProjectSummarySections(projects).reduce((items, section) => items.concat(section.projects), []);
}

function updateProjectPortfolioCount(visibleCount, totalCount) {
  const countElement = document.getElementById("projectPortfolioCount");
  if (!countElement) {
    return;
  }

  countElement.textContent = visibleCount === totalCount
    ? t("projects.count", { count: totalCount })
    : t("projects.countFiltered", { visible: visibleCount, total: totalCount });
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

  const employees = (projectsViewState.employees || [])
    .filter(employee => {
      const role = typeof normalizeClientRole === "function" ? normalizeClientRole(employee && employee.role || "employee") : "employee";
      return role === "admin" || role === "superAdmin";
    })
    .filter(employee => employeeMatchesProjectEditorSearch(employee, config.searchValue));
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
  document.getElementById("projectEditorOriginalCodeInput").value = "";
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
  document.getElementById("projectEditorDeleteButton").classList.add("d-none");
  setProjectEditorMessage("");
}

async function openProjectEditorModal(mode, project) {
  if (!canManageProjects()) {
    return;
  }

  resetProjectEditorForm();
  await ensureProjectEditorEmployees(true);

  const admins = project && Array.isArray(project.admins) ? project.admins : [];
  const backupAdmins = project && Array.isArray(project.backupAdmins) ? project.backupAdmins : [];
  projectsViewState.editorAssignments.admins = normalizeAssignmentCodes(admins);
  projectsViewState.editorAssignments.backupAdmins = normalizeAssignmentCodes(backupAdmins);
  renderProjectEditorAssignmentLists();

  if (mode === "edit" && project) {
    document.getElementById("projectEditorMode").value = "edit";
    document.getElementById("projectEditorOriginalCodeInput").value = project.projectCode || "";
    document.getElementById("projectEditorModalLabel").textContent = t("projects.editProject");
    document.getElementById("projectEditorCodeInput").value = project.projectCode || "";
    document.getElementById("projectEditorCodeInput").readOnly = false;
    document.getElementById("projectEditorNameInput").value = project.projectName || "";
    document.getElementById("projectEditorSectorInput").value = project.sector || "";
    document.getElementById("projectEditorRemoveButton").classList.toggle("d-none", Boolean(project.archived));
    document.getElementById("projectEditorDeleteButton").classList.remove("d-none");
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

function getProjectInsightStage(canvasId) {
  return document.querySelector(`[data-project-insight-stage="${canvasId}"]`);
}

function ensureProjectInsightCanvas(canvasId) {
  const stage = getProjectInsightStage(canvasId);
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

function destroyProjectInsightChart(canvasId) {
  if (projectInsightChartInstances[canvasId]) {
    projectInsightChartInstances[canvasId].destroy();
    delete projectInsightChartInstances[canvasId];
  }
}

function setProjectInsightEmptyState(canvasId, messageKey = "projects.noChartData") {
  destroyProjectInsightChart(canvasId);
  const stage = getProjectInsightStage(canvasId);
  if (stage) {
    stage.innerHTML = createEmptyState(t(messageKey));
  }
}

function setProjectInsightsLoadingState() {
  setLoadingState("projectInsightsSummary", "grid", 4);
  document.querySelectorAll(".project-insight-stage").forEach(stage => {
    stage.innerHTML = createLoadingState("chart", 1);
  });
}

function getProjectChartTheme() {
  const rootStyles = getComputedStyle(document.documentElement);
  return {
    textPrimary: rootStyles.getPropertyValue("--text-primary").trim() || "#1f2329",
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

function getProjectChartColors(count) {
  const rootStyles = getComputedStyle(document.documentElement);
  return Array.from({ length: count }, (_, index) => {
    const paletteIndex = index % projectPalette.length;
    return rootStyles.getPropertyValue(`--chart-${paletteIndex + 1}`).trim() || projectPalette[paletteIndex];
  });
}

function normalizeProjectAssignmentCodes(value) {
  if (Array.isArray(value)) {
    return value.map(code => String(code || "").trim()).filter(Boolean);
  }

  const normalized = String(value || "").trim();
  if (!normalized) {
    return [];
  }

  return normalized.split(/[;,]/).map(code => code.trim()).filter(Boolean);
}

function isProjectArchived(project) {
  const archivedValue = project && project.archived;
  if (typeof archivedValue === "boolean") {
    return archivedValue;
  }
  if (typeof archivedValue === "number") {
    return archivedValue !== 0;
  }

  return ["true", "1", "yes"].indexOf(String(archivedValue || "").trim().toLowerCase()) >= 0;
}

function getProjectTotalSeconds(project) {
  return timeStringToSeconds(project && project.totalOvertime || "00:00:00");
}

function getProjectSector(project) {
  return String(project && project.sector || "").trim() || t("projects.noSector");
}

function addProjectCountMetric(metrics, label, count) {
  if (!metrics[label]) {
    metrics[label] = 0;
  }
  metrics[label] += count;
}

function compactProjectChartItems(items, maxItems = 6) {
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

function createProjectTooltipLabel(context, valueType) {
  const rawValue = Number(context.parsed && typeof context.parsed === "object"
    ? (context.parsed.x != null ? context.parsed.x : context.parsed.y)
    : context.parsed || 0);
  const dataset = context.dataset && Array.isArray(context.dataset.data) ? context.dataset.data : [];
  const total = dataset.reduce((sum, item) => sum + Number(item || 0), 0);
  const percent = total > 0 ? Math.round((rawValue / total) * 100) : 0;
  const label = context.label || context.dataset.label || "";

  if (valueType === "duration") {
    return `${label}: ${secondsToDurationLabel(rawValue)} (${percent}%)`;
  }

  return `${label}: ${t("projects.projectCountValue", { count: rawValue })} (${percent}%)`;
}

function renderProjectDoughnutInsight(canvasId, items, valueType = "count") {
  const chartItems = compactProjectChartItems(items);
  if (chartItems.length === 0) {
    setProjectInsightEmptyState(canvasId);
    return;
  }

  const canvas = ensureProjectInsightCanvas(canvasId);
  if (!canvas) {
    return;
  }

  const theme = getProjectChartTheme();
  destroyProjectInsightChart(canvasId);
  projectInsightChartInstances[canvasId] = new Chart(canvas.getContext("2d"), {
    type: "doughnut",
    data: {
      labels: chartItems.map(item => item.label),
      datasets: [{
        data: chartItems.map(item => item.value),
        backgroundColor: getProjectChartColors(chartItems.length),
        borderColor: theme.panel,
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      resizeDelay: 150,
      cutout: "62%",
      plugins: {
        legend: {
          position: "bottom",
          labels: {
            color: theme.textSecondary,
            usePointStyle: true,
            boxWidth: 8,
          },
        },
        tooltip: {
          backgroundColor: theme.tooltip,
          titleColor: theme.tooltipText,
          bodyColor: theme.tooltipText,
          callbacks: {
            label: context => createProjectTooltipLabel(context, valueType),
          },
        },
      },
    },
  });
}

function compactProjectTrendData(trendData, maxDatasets = 6) {
  const source = trendData && typeof trendData === "object" ? trendData : {};
  const projectCodes = Object.keys(source);
  if (projectCodes.length <= maxDatasets) {
    return source;
  }

  const sortedCodes = projectCodes
    .map(projectCode => ({
      projectCode,
      total: (Array.isArray(source[projectCode]) ? source[projectCode] : [])
        .reduce((sum, item) => sum + Number(item && item.overtime || 0), 0),
    }))
    .sort((left, right) => right.total - left.total);

  const visibleCodes = sortedCodes.slice(0, maxDatasets - 1).map(item => item.projectCode);
  const groupedCodes = sortedCodes.slice(maxDatasets - 1).map(item => item.projectCode);
  const compacted = {};

  visibleCodes.forEach(projectCode => {
    compacted[projectCode] = source[projectCode];
  });

  const otherByMonth = {};
  groupedCodes.forEach(projectCode => {
    (Array.isArray(source[projectCode]) ? source[projectCode] : []).forEach(item => {
      const month = item && item.month;
      if (!month) {
        return;
      }
      otherByMonth[month] = (otherByMonth[month] || 0) + Number(item && item.overtime || 0);
    });
  });

  compacted[t("projects.other")] = Object.keys(otherByMonth)
    .sort()
    .map(month => ({ month, overtime: otherByMonth[month] }));

  return compacted;
}

function renderProjectInsights(projects) {
  const projectList = Array.isArray(projects) ? projects : [];
  const summaryContainer = document.getElementById("projectInsightsSummary");

  if (!summaryContainer) {
    return;
  }

  if (typeof Chart !== "function") {
    summaryContainer.innerHTML = createEmptyState(t("projects.chartLibraryFailed"));
    setProjectInsightEmptyState("projectOvertimeShareChart", "projects.chartLibraryFailed");
    setProjectInsightEmptyState("projectSectorDistributionChart", "projects.chartLibraryFailed");
    return;
  }

  if (projectList.length === 0) {
    summaryContainer.innerHTML = createEmptyState(t("projects.noStats"));
    setProjectInsightEmptyState("projectOvertimeShareChart");
    setProjectInsightEmptyState("projectSectorDistributionChart");
    return;
  }

  const activeProjects = projectList.filter(project => !isProjectArchived(project));
  const archivedProjects = projectList.filter(project => isProjectArchived(project));
  const sectorMetrics = {};
  const totalSeconds = projectList.reduce((sum, project) => sum + getProjectTotalSeconds(project), 0);
  const missingPrimaryCount = activeProjects.filter(project => normalizeProjectAssignmentCodes(project.admins).length === 0).length;
  const missingBackupCount = activeProjects.filter(project => normalizeProjectAssignmentCodes(project.backupAdmins).length === 0).length;

  projectList.forEach(project => {
    addProjectCountMetric(sectorMetrics, getProjectSector(project), 1);
  });

  summaryContainer.innerHTML = `
    <div class="project-insight-stat">
      <span class="metric-label">${escapeHtml(t("projects.insightTotalOvertime"))}</span>
      <strong class="metric-value mono">${escapeHtml(secondsToDurationLabel(totalSeconds))}</strong>
      <span class="metric-hint">${escapeHtml(t("projects.insightSelectedPeriod"))}</span>
    </div>
    <div class="project-insight-stat">
      <span class="metric-label">${escapeHtml(t("projects.insightActiveProjects"))}</span>
      <strong class="metric-value mono">${escapeHtml(`${activeProjects.length}/${projectList.length}`)}</strong>
      <span class="metric-hint">${escapeHtml(t("projects.insightArchivedHint", { count: archivedProjects.length }))}</span>
    </div>
    <div class="project-insight-stat">
      <span class="metric-label">${escapeHtml(t("projects.insightSectors"))}</span>
      <strong class="metric-value mono">${escapeHtml(Object.keys(sectorMetrics).length)}</strong>
      <span class="metric-hint">${escapeHtml(t("projects.insightSectorHint"))}</span>
    </div>
    <div class="project-insight-stat">
      <span class="metric-label">${escapeHtml(t("projects.insightCoverage"))}</span>
      <strong class="metric-value mono">${escapeHtml(missingPrimaryCount + missingBackupCount)}</strong>
      <span class="metric-hint">${escapeHtml(t("projects.insightCoverageHint", { primary: missingPrimaryCount, backup: missingBackupCount }))}</span>
    </div>
  `;

  if (pendingProjectInsightFrameId) {
    window.cancelAnimationFrame(pendingProjectInsightFrameId);
    pendingProjectInsightFrameId = null;
  }

  const overtimeItems = projectList.map(project => ({
    label: String(project.projectCode || project.projectName || t("shared.project")),
    value: getProjectTotalSeconds(project),
  }));
  const sectorItems = Object.keys(sectorMetrics)
    .sort((left, right) => sectorMetrics[right] - sectorMetrics[left])
    .map(sector => ({
      label: sector,
      value: sectorMetrics[sector],
    }));
  pendingProjectInsightFrameId = window.requestAnimationFrame(() => {
    renderProjectDoughnutInsight("projectOvertimeShareChart", overtimeItems, "duration");
    renderProjectDoughnutInsight("projectSectorDistributionChart", sectorItems, "count");
    pendingProjectInsightFrameId = null;
  });
}

function clearProjectDetailCache() {
  supersedeProjectDetailRequests();
  Object.keys(projectDetailCache).forEach(cacheKey => {
    delete projectDetailCache[cacheKey];
  });
}

function supersedeProjectDetailRequests() {
  projectDetailRequestVersion += 1;

  if (pendingProjectDetailTimerId !== null) {
    window.clearTimeout(pendingProjectDetailTimerId);
    pendingProjectDetailTimerId = null;
  }

  if (pendingProjectDetailRequest && pendingProjectDetailRequest.controller) {
    pendingProjectDetailRequest.controller.abort();
  }
  pendingProjectDetailRequest = null;
  return projectDetailRequestVersion;
}

function isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod) {
  return requestVersion === projectDetailRequestVersion
    && String(projectCode || "") === String(currentProjectCode || "")
    && String(filterPeriod || "") === String(currentProjectFilter || "");
}

function scheduleProjectDetailStats(projectCode, filterPeriod = "all") {
  const requestVersion = supersedeProjectDetailRequests();
  pendingProjectDetailTimerId = window.setTimeout(() => {
    pendingProjectDetailTimerId = null;
    loadProjectDetailStats(projectCode, filterPeriod, { requestVersion });
  }, PROJECT_DETAIL_REQUEST_DELAY_MS);
}

function invalidateProjectLookupCaches() {
  if (typeof clearOvertimeEntryLookupCache === "function") {
    clearOvertimeEntryLookupCache();
  }
  if (typeof clearScopedProjectLookupCache === "function") {
    clearScopedProjectLookupCache();
  }
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

async function loadProjectDetailStats(projectCode, filterPeriod = "all", options = {}) {
  const requestVersion = Number.isInteger(options.requestVersion)
    ? options.requestVersion
    : supersedeProjectDetailRequests();
  const cacheKey = getProjectDetailCacheKey(projectCode, filterPeriod);
  if (projectDetailCache[cacheKey]) {
    if (isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod)) {
      renderProjectDetail(projectDetailCache[cacheKey]);
    }
    return projectDetailCache[cacheKey];
  }

  const controller = typeof AbortController === "function" ? new AbortController() : null;
  pendingProjectDetailRequest = {
    controller,
    requestVersion,
  };

  try {
    setLoadingState("projectDetailContainer", "detail", 1);
    const response = await fetch(buildProjectStatsUrl(projectCode, filterPeriod), controller ? { signal: controller.signal } : undefined);
    const data = await parseResponse(response);
    if (!isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod)) {
      return null;
    }
    projectDetailCache[cacheKey] = data;
    renderProjectDetail(data);
    return data;
  } catch (error) {
    if ((error && error.name === "AbortError") || !isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod)) {
      return null;
    }
    console.error("Error loading project detail stats:", error);
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.statsUnavailable"));
    return null;
  } finally {
    if (pendingProjectDetailRequest && pendingProjectDetailRequest.requestVersion === requestVersion) {
      pendingProjectDetailRequest = null;
    }
  }
}

async function refreshProjectsView() {
  clearProjectDetailCache();
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  const requestedProjectCode = currentProjectCode;
  const addButton = document.getElementById("addProjectButton");
  if (addButton) {
    addButton.classList.toggle("d-none", !canManageProjects());
  }
  setLoadingState("projectsSummaryContainer", "grid", 4);
  setLoadingState("projectDetailContainer", "detail", 1);
  setChartLoadingState("projectChartContainer");
  setProjectInsightsLoadingState();

  try {
    const response = await fetch(buildProjectBootstrapUrl(currentProjectFilter, currentProjectCode));
    const payload = await parseResponse(response);
    const summary = Array.isArray(payload && payload.summary) ? payload.summary : [];
    const trends = payload && payload.trends ? payload.trends : {};
    projectsViewState.projects = summary;
    projectsViewState.trends = trends;
    projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();

    const visibleProjects = getVisibleProjectSummaries(summary);
    const visibleProjectOrder = getProjectSummaryDisplayOrder(visibleProjects);
    currentProjectCode = requestedProjectCode && payload && payload.selectedProjectCode
      ? payload.selectedProjectCode
      : (visibleProjectOrder[0] ? visibleProjectOrder[0].projectCode : null);
    if (currentProjectCode && !visibleProjects.some(project => String(project.projectCode || "") === String(currentProjectCode))) {
      currentProjectCode = visibleProjectOrder.length > 0 ? visibleProjectOrder[0].projectCode : null;
    }

    renderProjectSummaryCards(summary);
    renderProjectMultiLineChart(trends);
    renderProjectInsights(summary);

    if (payload && payload.selectedProject && String(payload.selectedProject.projectCode || "") === String(currentProjectCode || "")) {
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
    document.getElementById("projectInsightsSummary").innerHTML = createEmptyState(t("projects.unableToLoad"));
    setProjectInsightEmptyState("projectOvertimeShareChart", "projects.chartLoadError");
    setProjectInsightEmptyState("projectSectorDistributionChart", "projects.chartLoadError");
  }
}

function renderProjectSummaryCards(projectDetails) {
  const container = document.getElementById("projectsSummaryContainer");
  const allProjects = Array.isArray(projectDetails) ? projectDetails : [];
  const visibleProjects = getVisibleProjectSummaries(allProjects);
  updateProjectPortfolioCount(visibleProjects.length, allProjects.length);

  if (allProjects.length === 0) {
    container.classList.remove("is-sectioned");
    container.innerHTML = createEmptyState(t("projects.noStats"));
    return;
  }

  if (visibleProjects.length === 0) {
    container.classList.remove("is-sectioned");
    container.innerHTML = createEmptyState(t("projects.noMatchingProjects"));
    return;
  }

  const sections = getProjectSummarySections(visibleProjects);
  container.classList.toggle("is-sectioned", shouldSectionProjectSummary());
  container.innerHTML = sections.map(section => {
    const cardsMarkup = section.projects.map(renderProjectSummaryCard).join("");
    if (!section.title) {
      return cardsMarkup;
    }

    return `
      <section class="project-summary-section" data-project-section="${escapeHtml(section.key)}">
        <div class="project-summary-section-title">
          <span>${escapeHtml(section.title)}</span>
          <span class="project-summary-section-count">${escapeHtml(t("projects.projectCountValue", { count: section.projects.length }))}</span>
        </div>
        <div class="project-summary-section-grid">
          ${cardsMarkup}
        </div>
      </section>
    `;
  }).join("");
}

function updateActiveProjectSummaryCard() {
  document.querySelectorAll("#projectsSummaryContainer .project-summary-card").forEach(card => {
    card.classList.toggle(
      "is-active",
      String(card.getAttribute("data-project-code") || "") === String(currentProjectCode || "")
    );
  });
}

function renderProjectSummaryCard(detail) {
  const total = secondsToDurationLabel(timeStringToSeconds(detail.totalOvertime || "00:00:00"));
  const minValue = secondsToDurationLabel(timeStringToSeconds(detail.minOvertime || "00:00:00"));
  const maxValue = secondsToDurationLabel(timeStringToSeconds(detail.maxOvertime || "00:00:00"));
  const admins = Array.isArray(detail.admins) ? detail.admins : [];
  const backupAdmins = Array.isArray(detail.backupAdmins) ? detail.backupAdmins : [];
  const projectName = String(detail.projectName || "").trim();
  const projectTitle = getProjectDisplayName(detail);
  const projectNote = [projectName ? detail.projectCode : "", detail.sector].filter(Boolean).join(" | ");
  const archivedBadge = detail.archived ? `<span class="status-badge rejected">${escapeHtml(t("projects.archived"))}</span>` : "";
  return `
    <article class="project-summary-card${currentProjectCode === detail.projectCode ? " is-active" : ""}${detail.archived ? " is-archived" : ""}" data-project-code="${escapeHtml(detail.projectCode)}">
      <div class="project-card-header">
        <div>
          <div class="project-card-title">${escapeHtml(projectTitle)}</div>
          ${projectNote ? `<div class="employee-card-note">${escapeHtml(projectNote)}</div>` : ""}
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
      </div>
      <div class="project-card-assignments">
        ${renderProjectAssignmentLine("projects.admins", detail.adminDisplay, admins)}
        ${renderProjectAssignmentLine("projects.backupAdmins", detail.backupAdminDisplay, backupAdmins)}
      </div>
      <div class="employee-card-actions${canManageProjects() ? "" : " d-none"}">
        <button type="button" class="btn btn-outline-secondary btn-sm project-edit-button" data-project-code="${escapeHtml(detail.projectCode)}">${escapeHtml(t("action.edit"))}</button>
      </div>
    </article>
  `;
}

function applyProjectPortfolioSearch(options = {}) {
  projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();
  const visibleProjects = getVisibleProjectSummaries(projectsViewState.projects);
  const selectedProjectVisible = visibleProjects.some(project => String(project.projectCode || "") === String(currentProjectCode || ""));

  if (!selectedProjectVisible) {
    const visibleProjectOrder = getProjectSummaryDisplayOrder(visibleProjects);
    currentProjectCode = visibleProjectOrder.length > 0 ? visibleProjectOrder[0].projectCode : null;
    if (options.updateDetail) {
      if (currentProjectCode) {
        scheduleProjectDetailStats(currentProjectCode, currentProjectFilter);
      } else {
        supersedeProjectDetailRequests();
        document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.noMatchingProjects"));
      }
    }
  }

  renderProjectSummaryCards(projectsViewState.projects);
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
        <h4 class="m-0">${escapeHtml(getProjectDisplayName(detail))}</h4>
        ${String(detail.projectName || "").trim() ? `<span class="inline-code-pill">${escapeHtml(detail.projectCode)}</span>` : ""}
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
  if (!canManageProjects()) {
    return;
  }

  setProjectEditorMessage("");

  const mode = document.getElementById("projectEditorMode").value;
  const originalProjectCode = document.getElementById("projectEditorOriginalCodeInput").value.trim();
  const projectCode = document.getElementById("projectEditorCodeInput").value.trim();
  const projectName = document.getElementById("projectEditorNameInput").value.trim();
  const sector = document.getElementById("projectEditorSectorInput").value.trim();
  const admins = getProjectEditorAssignmentCodes("admins");
  const backupAdmins = getProjectEditorAssignmentCodes("backupAdmins");
  const existingProject = mode === "edit" ? getProjectByCode(originalProjectCode) : null;

  if (!projectCode || (mode === "edit" && !originalProjectCode)) {
    setProjectEditorMessage(t("projects.codeAndNameRequired"), "danger");
    return;
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$/.test(projectCode)) {
    setProjectEditorMessage(t("projects.projectCodeInvalid"), "danger");
    return;
  }
  if (projectName.length > 200) {
    setProjectEditorMessage(t("projects.projectNameTooLong"), "danger");
    return;
  }

  const normalizedOriginalCode = originalProjectCode.toLowerCase();
  const duplicateProjectCode = projectsViewState.projects.some(project => {
    const candidateCode = String(project && project.projectCode || "").trim();
    return candidateCode.toLowerCase() === projectCode.toLowerCase()
      && candidateCode.toLowerCase() !== normalizedOriginalCode;
  });
  if (duplicateProjectCode) {
    setProjectEditorMessage(t("projects.projectCodeDuplicate"), "danger");
    return;
  }

  try {
    const response = await fetch(mode === "create" ? apiUrl + "projects" : apiUrl + "projects/" + encodeURIComponent(originalProjectCode), {
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

    if (response.status === 409) {
      throw new Error(t("projects.renameInUse"));
    }
    await parseResponse(response);
    invalidateProjectLookupCaches();
    const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
    if (modal) {
      modal.hide();
    }
    resetProjectEditorForm();
    if (mode === "edit" && currentProjectCode === originalProjectCode) {
      currentProjectCode = projectCode;
    }
    showToast(t(mode === "create" ? "projects.projectCreated" : "projects.projectUpdated"), "success");
    await refreshProjectsView();
  } catch (error) {
    console.error("Error saving project:", error);
    setProjectEditorMessage(error.message || t(mode === "create" ? "projects.createError" : "projects.updateError"), "danger");
  }
}

async function archiveProject(project) {
  if (!canManageProjects() || !project || !project.projectCode) {
    return false;
  }

  const projectName = String(project.projectName || "").trim();
  const confirmed = window.confirm(t(projectName ? "projects.archiveConfirm" : "projects.archiveConfirmCodeOnly", {
    name: projectName,
    code: project.projectCode,
  }));
  if (!confirmed) {
    return false;
  }

  try {
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(project.projectCode), {
      method: "DELETE",
    });
    await parseResponse(response);
    invalidateProjectLookupCaches();
    if (currentProjectCode === project.projectCode) {
      currentProjectCode = null;
    }
    showToast(t("projects.projectArchived"), "success");
    await refreshProjectsView();
    return true;
  } catch (error) {
    console.error("Error archiving project:", error);
    showToast(error.message || t("projects.archiveError"), "error");
    return false;
  }
}

async function deleteProject(project) {
  if (!canManageProjects() || !project || !project.projectCode) {
    return false;
  }

  const projectName = String(project.projectName || "").trim();
  const confirmed = window.confirm(t(projectName ? "projects.deleteConfirm" : "projects.deleteConfirmCodeOnly", {
    name: projectName,
    code: project.projectCode,
  }));
  if (!confirmed) {
    return false;
  }

  try {
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(project.projectCode) + "?permanent=true", {
      method: "DELETE",
    });
    if (response.status === 409) {
      throw new Error(t("projects.deleteInUse"));
    }
    await parseResponse(response);
    invalidateProjectLookupCaches();
    if (currentProjectCode === project.projectCode) {
      currentProjectCode = null;
    }
    showToast(t("projects.projectDeleted"), "success");
    await refreshProjectsView();
    return true;
  } catch (error) {
    console.error("Error deleting project:", error);
    showToast(error.message || t("projects.deleteError"), "error");
    return false;
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

  const compactedTrendData = compactProjectTrendData(trendData);
  const labelSet = new Set();
  Object.keys(compactedTrendData || {}).forEach(projectCode => {
    compactedTrendData[projectCode].forEach(item => labelSet.add(item.month));
  });

  const timeLabels = Array.from(labelSet).sort();
  const formattedLabels = timeLabels.map(formatYMToWords);
  const theme = getProjectChartTheme();
  const colors = getProjectChartColors(6);

  const datasets = Object.keys(compactedTrendData || {}).map((projectCode, index) => {
    const dataPoints = timeLabels.map(label => {
      const entry = compactedTrendData[projectCode].find(item => item.month === label);
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
        animation: false,
        resizeDelay: 150,
        plugins: {
          legend: {
            position: "top",
            labels: {
              color: theme.textSecondary,
              usePointStyle: true,
              boxWidth: 8,
              padding: 18,
            },
          },
          tooltip: {
            backgroundColor: theme.tooltip,
            titleColor: theme.tooltipText,
            bodyColor: theme.tooltipText,
          },
        },
        scales: {
          x: {
            ticks: {
              color: theme.textMuted,
            },
            grid: {
              color: theme.grid,
            },
          },
          y: {
            beginAtZero: true,
            ticks: {
              color: theme.textMuted,
            },
            grid: {
              color: theme.grid,
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
      runButtonAction(editButton, () => openProjectEditorModal("edit", project), {
        key: "project-editor-open",
        disableWhileRunning: () => document.querySelectorAll("#addProjectButton, .project-edit-button"),
      }).catch(error => {
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
    updateActiveProjectSummaryCard();
    scheduleProjectDetailStats(projectCode, currentProjectFilter);
  }
});

document.getElementById("projectPortfolioSearchInput").addEventListener("input", () => {
  if (projectPortfolioSearchTimerId !== null) {
    window.clearTimeout(projectPortfolioSearchTimerId);
  }
  projectPortfolioSearchTimerId = window.setTimeout(() => {
    projectPortfolioSearchTimerId = null;
    applyProjectPortfolioSearch({ updateDetail: true });
  }, PROJECT_PORTFOLIO_SEARCH_DEBOUNCE_MS);
});

document.getElementById("projectDetailContainer").addEventListener("click", event => {
  const navigatorButton = event.target.closest(".project-people-navigator");
  if (!navigatorButton) {
    return;
  }

  const employeeCode = navigatorButton.getAttribute("data-employee-code");
  const projectCode = navigatorButton.getAttribute("data-project-code");
  if (typeof window.openPeopleProjectFilter === "function") {
    runButtonAction(navigatorButton, () => window.openPeopleProjectFilter(employeeCode, projectCode), {
      key: "open-employee",
    }).catch(error => {
      console.error("Unable to open employee file:", error);
      showToast(t("employees.loadError"), "error");
    });
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

  runButtonAction(rangeButton, () => setProjectRange(nextRange), {
    key: "projects-filter-refresh",
  }).catch(error => {
    console.error("Unable to change the project range:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});
document.getElementById("projectApplyCustomRangeButton").addEventListener("click", event => {
  const startDate = document.getElementById("projectStartDate").value;
  const endDate = document.getElementById("projectEndDate").value;
  if (startDate && endDate && startDate > endDate) {
    showToast(t("filters.invalidRange"), "error");
    return;
  }

  runButtonAction(event.currentTarget, async () => {
    projectsViewState.customRange.startDate = startDate;
    projectsViewState.customRange.endDate = endDate;
    currentProjectFilter = getMatchingPresetProjectRange(startDate, endDate);
    syncProjectRangeButtons();
    await refreshProjectsView();
  }, { key: "projects-filter-refresh" }).catch(error => {
    console.error("Unable to apply the custom project range:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});
document.getElementById("projectClearCustomRangeButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, async () => {
    projectsViewState.customRange.startDate = "";
    projectsViewState.customRange.endDate = "";
    await setProjectRange("6M");
  }, { key: "projects-filter-refresh" }).catch(error => {
    console.error("Unable to reset the project range:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});
document.getElementById("addProjectButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, () => openProjectEditorModal("create"), {
    key: "project-editor-open",
    disableWhileRunning: () => document.querySelectorAll("#addProjectButton, .project-edit-button"),
  }).catch(error => {
    console.error("Unable to open project editor:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});
document.getElementById("projectEditorRemoveButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, async () => {
    const project = getProjectByCode(document.getElementById("projectEditorOriginalCodeInput").value.trim());
    const archived = await archiveProject(project);
    if (archived) {
      const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
      if (modal) {
        modal.hide();
      }
    }
  }, { key: "project-editor-mutation" }).catch(error => {
    console.error("Error archiving project:", error);
    showToast(error.message || t("projects.archiveError"), "error");
  });
});
document.getElementById("projectEditorDeleteButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, async () => {
    const project = getProjectByCode(document.getElementById("projectEditorOriginalCodeInput").value.trim());
    const deleted = await deleteProject(project);
    if (deleted) {
      const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
      if (modal) {
        modal.hide();
      }
    }
  }, { key: "project-editor-mutation" }).catch(error => {
    console.error("Error deleting project:", error);
    showToast(error.message || t("projects.deleteError"), "error");
  });
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
document.getElementById("projectEditorSaveButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, submitProjectEditor, {
    key: "project-editor-mutation",
  }).catch(error => {
    console.error("Error saving project:", error);
    setProjectEditorMessage(error.message || t("projects.updateError"), "danger");
  });
});
document.getElementById("projectEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  const saveButton = document.getElementById("projectEditorSaveButton");
  runButtonAction(saveButton, submitProjectEditor, {
    key: "project-editor-mutation",
  }).catch(error => {
    console.error("Error saving project:", error);
    setProjectEditorMessage(error.message || t("projects.updateError"), "danger");
  });
});

window.addEventListener("app:theme-changed", () => {
  const projectsView = document.getElementById("projectsView");
  if (!projectsView || !projectsView.classList.contains("active")) {
    return;
  }

  renderProjectMultiLineChart(projectsViewState.trends || {});
  renderProjectInsights(projectsViewState.projects || []);
});

window.rerenderProjectsViewForLanguageChange = function () {
  projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  renderProjectSummaryCards(projectsViewState.projects || []);
  renderProjectMultiLineChart(projectsViewState.trends || {});
  renderProjectInsights(projectsViewState.projects || []);

  const cacheKey = currentProjectCode
    ? getProjectDetailCacheKey(currentProjectCode, currentProjectFilter)
    : "";
  if (cacheKey && projectDetailCache[cacheKey]) {
    renderProjectDetail(projectDetailCache[cacheKey]);
  } else if (!currentProjectCode) {
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.selectToInspect"));
  }
};
