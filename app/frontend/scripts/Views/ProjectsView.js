const projectDetailCache = {};
let currentProjectFilter = "6M";
let currentProjectCode = null;
let pendingProjectChartFrameId = null;
let pendingProjectInsightFrameId = null;
let pendingProjectDetailTimerId = null;
let pendingProjectDetailRequest = null;
let projectDetailRequestVersion = 0;
let projectPortfolioSearchTimerId = null;
let projectWorkspaceRouteSyncInProgress = false;
let projectWorkspaceTrendChartInstance = null;
let pendingProjectWorkspaceTrendFrameId = null;
const PROJECT_DETAIL_REQUEST_DELAY_MS = 90;
const PROJECT_PORTFOLIO_SEARCH_DEBOUNCE_MS = 140;
const PROJECT_WORKSPACE_RECENT_ENTRY_LIMIT = 6;
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
  portfolioScope: "active",
  portfolioSort: "activity",
  workspaceOpen: false,
  workspaceEntriesExpanded: false,
  workspaceOpener: null,
  portfolioScrollY: 0,
  contributorSort: {
    key: "approvedSeconds",
    direction: "desc",
  },
};

function renderProjectEditorColorOptions(selectedColorKey = "blue") {
  const select = document.getElementById("projectEditorColorSelect");
  if (!select) {
    return;
  }

  const projectCode = document.getElementById("projectEditorCodeInput")?.value || "";
  const normalizedSelection = normalizeProjectColorKey(selectedColorKey, projectCode);
  select.innerHTML = SAPHIR_PROJECT_COLOR_KEYS.map(colorKey => (
    `<option value="${escapeHtml(colorKey)}"${colorKey === normalizedSelection ? " selected" : ""}>${escapeHtml(t(`projects.color.${colorKey}`))}</option>`
  )).join("");
  syncProjectEditorColorPreview();
}

function syncProjectEditorColorPreview() {
  const select = document.getElementById("projectEditorColorSelect");
  const preview = document.getElementById("projectEditorColorPreview");
  if (!select || !preview) {
    return;
  }

  const projectCode = document.getElementById("projectEditorCodeInput")?.value || "";
  const project = { projectCode, colorKey: select.value };
  preview.setAttribute("style", getProjectColorStyle(project));
  preview.innerHTML = renderProjectColorDot(project);
}

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
  return normalizeProjectPortfolioSearchText(input && input.value);
}

function normalizeProjectPortfolioSearchText(value) {
  return String(value || "")
    .trim()
    .toLocaleLowerCase(typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

function normalizeProjectPortfolioScope(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return ["active", "archived", "all"].indexOf(normalized) >= 0 ? normalized : "active";
}

function normalizeProjectPortfolioSort(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return ["activity", "alphabetical", "sector"].indexOf(normalized) >= 0 ? normalized : "activity";
}

function getProjectPortfolioScopeValue() {
  const select = document.getElementById("projectPortfolioScopeSelect");
  return normalizeProjectPortfolioScope(select ? select.value : projectsViewState.portfolioScope);
}

function getProjectPortfolioSortValue() {
  const select = document.getElementById("projectPortfolioSortSelect");
  return normalizeProjectPortfolioSort(select ? select.value : projectsViewState.portfolioSort);
}

function syncProjectPortfolioControls() {
  const scopeSelect = document.getElementById("projectPortfolioScopeSelect");
  const sortSelect = document.getElementById("projectPortfolioSortSelect");
  const sortHint = document.querySelector("#projectsView .project-portfolio-sort-hint");
  if (scopeSelect) {
    scopeSelect.value = normalizeProjectPortfolioScope(projectsViewState.portfolioScope);
  }
  if (sortSelect) {
    sortSelect.value = normalizeProjectPortfolioSort(projectsViewState.portfolioSort);
  }
  if (sortHint) {
    sortHint.classList.toggle("d-none", normalizeProjectPortfolioSort(projectsViewState.portfolioSort) !== "activity");
  }
}

function projectMatchesPortfolioSearch(project) {
  const searchValue = normalizeProjectPortfolioSearchText(projectsViewState.portfolioSearch);
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
  ].map(normalizeProjectPortfolioSearchText).join(" ");

  const tokens = window.Saphir.textSearch.tokenize(searchValue);
  return window.Saphir.textSearch.matchesAll(haystack, tokens);
}

function projectMatchesPortfolioScope(project, scope = projectsViewState.portfolioScope) {
  const normalizedScope = normalizeProjectPortfolioScope(scope);
  if (normalizedScope === "all") {
    return true;
  }

  const archived = isProjectArchived(project);
  return normalizedScope === "archived" ? archived : !archived;
}

function getProjectPortfolioCollator() {
  const locale = typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined;
  if (typeof Intl === "object" && typeof Intl.Collator === "function") {
    return new Intl.Collator(locale, { sensitivity: "base", numeric: true });
  }
  return null;
}

function compareProjectPortfolioText(left, right, collator = getProjectPortfolioCollator()) {
  const leftValue = String(left || "").trim();
  const rightValue = String(right || "").trim();
  return collator
    ? collator.compare(leftValue, rightValue)
    : leftValue.localeCompare(rightValue, undefined, { sensitivity: "base", numeric: true });
}

function compareProjectSummariesAlphabetically(left, right, collator) {
  const leftName = String(left && left.projectName || left && left.projectCode || "").trim();
  const rightName = String(right && right.projectName || right && right.projectCode || "").trim();
  const nameComparison = compareProjectPortfolioText(leftName, rightName, collator);
  return nameComparison || compareProjectPortfolioText(left && left.projectCode, right && right.projectCode, collator);
}

function compareProjectSummariesBySector(left, right, collator) {
  const leftSector = String(left && left.sector || "").trim();
  const rightSector = String(right && right.sector || "").trim();
  if (!leftSector && rightSector) {
    return 1;
  }
  if (leftSector && !rightSector) {
    return -1;
  }

  const sectorComparison = compareProjectPortfolioText(leftSector, rightSector, collator);
  return sectorComparison || compareProjectSummariesAlphabetically(left, right, collator);
}

function compareProjectSummariesByActivity(left, right, collator) {
  const secondsComparison = getProjectTotalSeconds(right) - getProjectTotalSeconds(left);
  if (secondsComparison !== 0) {
    return secondsComparison;
  }

  const entryComparison = Number(right && right.entryCount || 0) - Number(left && left.entryCount || 0);
  return entryComparison || compareProjectSummariesAlphabetically(left, right, collator);
}

function sortProjectSummaries(projects, sortMode = projectsViewState.portfolioSort) {
  const normalizedSort = normalizeProjectPortfolioSort(sortMode);
  const collator = getProjectPortfolioCollator();
  return (Array.isArray(projects) ? projects.slice() : []).sort((left, right) => {
    if (normalizedSort === "alphabetical") {
      return compareProjectSummariesAlphabetically(left, right, collator);
    }
    if (normalizedSort === "sector") {
      return compareProjectSummariesBySector(left, right, collator);
    }
    return compareProjectSummariesByActivity(left, right, collator);
  });
}

function getScopedProjectSummaries(projects) {
  return (Array.isArray(projects) ? projects : [])
    .filter(project => projectMatchesPortfolioScope(project));
}

function getVisibleProjectSummaries(projects) {
  return sortProjectSummaries(
    getScopedProjectSummaries(projects).filter(project => projectMatchesPortfolioSearch(project))
  );
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
  renderProjectEditorColorOptions("blue");
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
  const restoreButton = document.getElementById("projectEditorRestoreButton");
  if (restoreButton) {
    restoreButton.classList.add("d-none");
  }
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
    renderProjectEditorColorOptions(getProjectColorKey(project));
    document.getElementById("projectEditorRemoveButton").classList.toggle("d-none", isProjectArchived(project));
    document.getElementById("projectEditorDeleteButton").classList.remove("d-none");
    const restoreButton = document.getElementById("projectEditorRestoreButton");
    if (restoreButton) {
      restoreButton.classList.toggle("d-none", !isProjectArchived(project));
    }
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
  return Number.isFinite(Number(project && project.totalSeconds))
    ? Number(project.totalSeconds)
    : timeStringToSeconds(project && project.totalOvertime || "00:00:00");
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
        backgroundColor: chartItems.map((item, index) => (
          item.project ? getProjectColorCssValue(item.project) : getProjectChartColors(chartItems.length)[index]
        )),
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
    project,
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

function getProjectWorkspaceRouteCode() {
  const match = String(window.location && window.location.hash || "").match(/^#projects\/([^/]+)$/);
  if (!match) {
    return "";
  }
  try {
    return decodeURIComponent(match[1]).trim();
  } catch (error) {
    return "";
  }
}

function setProjectWorkspaceRoute(projectCode, options = {}) {
  if (!window.history || typeof window.history.pushState !== "function") {
    return;
  }
  const normalizedCode = String(projectCode || "").trim();
  const nextHash = normalizedCode ? `#projects/${encodeURIComponent(normalizedCode)}` : "";
  const nextUrl = `${window.location.pathname}${window.location.search}${nextHash}`;
  const state = normalizedCode ? { saphirProjectWorkspace: normalizedCode } : null;
  if (options.replace) {
    window.history.replaceState(state, "", nextUrl);
  } else {
    window.history.pushState(state, "", nextUrl);
  }
}

function syncProjectWorkspaceHeader(project) {
  const title = document.getElementById("projectWorkspaceTitle");
  const identity = document.getElementById("projectWorkspaceIdentity");
  const workspace = document.getElementById("projectWorkspace");
  const rangeSelect = document.getElementById("projectWorkspaceRangeSelect");
  const editButton = document.getElementById("projectWorkspaceEditButton");
  const normalizedProject = project || getProjectByCode(currentProjectCode) || { projectCode: currentProjectCode };
  const projectName = String(normalizedProject.projectName || "").trim();
  const identityParts = [projectName ? normalizedProject.projectCode : "", normalizedProject.sector].filter(Boolean);

  if (title) {
    title.textContent = getProjectDisplayName(normalizedProject);
  }
  if (identity) {
    identity.textContent = identityParts.join(" | ");
  }
  if (workspace) {
    workspace.setAttribute("style", getProjectColorStyle(normalizedProject));
  }
  if (rangeSelect) {
    rangeSelect.value = currentProjectFilter;
  }
  if (editButton) {
    editButton.classList.toggle("d-none", !canManageProjects());
    editButton.setAttribute("data-project-code", String(normalizedProject.projectCode || ""));
  }
  ["projectWorkspaceReviewButton", "projectWorkspaceEntriesButton", "projectWorkspaceExportButton"].forEach(buttonId => {
    const button = document.getElementById(buttonId);
    if (button) {
      button.setAttribute("data-project-code", String(normalizedProject.projectCode || ""));
    }
  });
}

function setProjectWorkspaceVisibility(isOpen, options = {}) {
  if (!isOpen) {
    destroyProjectWorkspaceTrendChart();
  }
  const portfolio = document.getElementById("projectPortfolioWorkspace");
  const workspace = document.getElementById("projectWorkspace");
  const title = document.getElementById("projectWorkspaceTitle");
  if (!portfolio || !workspace) {
    return;
  }

  projectsViewState.workspaceOpen = Boolean(isOpen);
  portfolio.classList.toggle("d-none", isOpen);
  workspace.classList.toggle("d-none", !isOpen);
  workspace.setAttribute("aria-hidden", isOpen ? "false" : "true");

  if (isOpen) {
    syncProjectWorkspaceHeader(getProjectByCode(currentProjectCode));
    window.scrollTo({ top: 0, behavior: "auto" });
    if (options.focus !== false && title) {
      title.focus({ preventScroll: true });
    }
    return;
  }

  if (options.restoreScroll === false) {
    projectsViewState.workspaceOpener = null;
    return;
  }

  const exactOpener = projectsViewState.workspaceOpener;
  projectsViewState.workspaceOpener = null;
  window.requestAnimationFrame(() => {
    window.scrollTo({ top: projectsViewState.portfolioScrollY || 0, behavior: "auto" });
    if (options.restoreFocus !== false && currentProjectCode) {
      const trigger = exactOpener && exactOpener.isConnected
        ? exactOpener
        : Array.from(document.querySelectorAll(".project-open-button"))
          .find(button => String(button.getAttribute("data-project-code") || "") === String(currentProjectCode));
      if (trigger) {
        trigger.focus({ preventScroll: true });
      }
    }
  });
}

function closeProjectWorkspace(options = {}) {
  const closingProjectCode = currentProjectCode;
  supersedeProjectDetailRequests();
  setProjectWorkspaceVisibility(false, {
    restoreFocus: options.restoreFocus !== false,
    restoreScroll: options.restoreScroll !== false,
  });
  updateActiveProjectSummaryCard();

  if (options.updateRoute !== false && getProjectWorkspaceRouteCode()) {
    if (window.history && window.history.state && window.history.state.saphirProjectWorkspace === closingProjectCode) {
      window.history.back();
    } else {
      setProjectWorkspaceRoute("", { replace: true });
    }
  }
}

window.closeProjectWorkspaceForViewChange = function () {
  if (!projectsViewState.workspaceOpen) {
    return;
  }
  closeProjectWorkspace({
    updateRoute: false,
    restoreFocus: false,
    restoreScroll: false,
  });
};

function openProjectDetailFromPortfolio(projectCode, filterPeriod = currentProjectFilter, options = {}) {
  const normalizedCode = String(projectCode || "").trim();
  if (!normalizedCode) {
    return Promise.resolve(null);
  }

  if (!projectsViewState.workspaceOpen) {
    projectsViewState.portfolioScrollY = window.scrollY || document.documentElement.scrollTop || 0;
  }
  if (options.opener && typeof options.opener.focus === "function") {
    projectsViewState.workspaceOpener = options.opener;
  }
  currentProjectCode = normalizedCode;
  projectsViewState.workspaceEntriesExpanded = false;
  updateActiveProjectSummaryCard();
  setProjectWorkspaceVisibility(true, { focus: options.focus !== false });
  if (options.updateRoute !== false && getProjectWorkspaceRouteCode() !== normalizedCode) {
    setProjectWorkspaceRoute(normalizedCode);
  }

  // Rendering the loading state before awaiting the network makes the view
  // respond immediately even when the shared drive is temporarily slow.
  return loadProjectDetailStats(normalizedCode, filterPeriod);
}

function syncProjectWorkspaceFromRoute() {
  if (projectWorkspaceRouteSyncInProgress) {
    return;
  }
  projectWorkspaceRouteSyncInProgress = true;
  try {
    const routeCode = getProjectWorkspaceRouteCode();
    if (routeCode) {
      if (typeof showView === "function") {
        showView("projectsView");
      }
      if (projectsViewState.projects.length === 0) {
        currentProjectCode = routeCode;
        projectsViewState.workspaceOpen = true;
        setProjectWorkspaceVisibility(true, { focus: true });
        refreshProjectsView().catch(error => {
          console.error("Unable to restore the project workspace route:", error);
        });
        return;
      }
      if (!projectsViewState.workspaceOpen || String(currentProjectCode || "") !== routeCode) {
        openProjectDetailFromPortfolio(routeCode, currentProjectFilter, { updateRoute: false });
      }
    } else if (projectsViewState.workspaceOpen) {
      closeProjectWorkspace({ updateRoute: false, restoreFocus: true });
    }
  } finally {
    projectWorkspaceRouteSyncInProgress = false;
  }
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
  return window.Saphir.dateRanges.resolveProjects(
    filterPeriod || currentProjectFilter,
    projectsViewState.customRange,
    new Date(),
  );
}

function getProjectAnalyticsExportLocale() {
  return String(typeof getCurrentLocale === "function" ? getCurrentLocale() : "")
    .toLowerCase()
    .startsWith("fr")
    ? "fr"
    : "en";
}

function buildProjectAnalyticsExportUrl(filterPeriod = currentProjectFilter, projectCode = "") {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  const params = new URLSearchParams();
  if (startDate) {
    params.set("startDate", startDate);
  }
  if (endDate) {
    params.set("endDate", endDate);
  }
  params.set("locale", getProjectAnalyticsExportLocale());
  if (String(projectCode || "").trim()) {
    params.set("projectCode", String(projectCode).trim());
  }
  return `${apiUrl}stats/analytics-export?${params.toString()}`;
}

function getProjectAnalyticsExportFallbackFilename(filterPeriod = currentProjectFilter, projectCode = "") {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  const projectPart = String(projectCode || "").trim()
    ? `-${String(projectCode).trim().replace(/[^A-Za-z0-9._-]+/g, "-")}`
    : "";
  if (!startDate && !endDate) {
    return `saphir-analytics${projectPart}-all.html`;
  }
  return `saphir-analytics${projectPart}-${startDate || "start"}_${endDate || "end"}.html`;
}

function sanitizeProjectAnalyticsExportFilename(value, fallbackFilename) {
  const fallback = String(fallbackFilename || "saphir-analytics.html");
  const sanitized = String(value || "")
    .trim()
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-")
    .replace(/^\.+/, "")
    .slice(0, 180);
  if (!sanitized) {
    return fallback;
  }
  return /\.html?$/i.test(sanitized) ? sanitized : `${sanitized}.html`;
}

function getProjectAnalyticsExportFilename(response, fallbackFilename) {
  const disposition = response && response.headers
    ? String(response.headers.get("Content-Disposition") || "")
    : "";
  const encodedMatch = disposition.match(/filename\*\s*=\s*UTF-8''([^;]+)/i);
  if (encodedMatch) {
    try {
      return sanitizeProjectAnalyticsExportFilename(decodeURIComponent(encodedMatch[1].trim()), fallbackFilename);
    } catch (error) {
      // Fall through to the regular filename or the local fallback.
    }
  }

  const filenameMatch = disposition.match(/filename\s*=\s*"([^"]+)"/i)
    || disposition.match(/filename\s*=\s*([^;]+)/i);
  return sanitizeProjectAnalyticsExportFilename(filenameMatch ? filenameMatch[1] : "", fallbackFilename);
}

function triggerProjectAnalyticsExportDownload(reportBlob, filename) {
  const objectUrl = URL.createObjectURL(reportBlob);
  const link = document.createElement("a");
  link.href = objectUrl;
  link.download = filename;
  link.rel = "noopener";
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(objectUrl), 0);
}

async function downloadProjectAnalyticsHtmlReport(filterPeriod = currentProjectFilter, projectCode = "") {
  const response = await fetch(buildProjectAnalyticsExportUrl(filterPeriod, projectCode), {
    cache: "no-store",
    headers: {
      Accept: "text/html",
    },
  });
  if (!response.ok) {
    await parseResponse(response);
    return false;
  }

  const reportBlob = await response.blob();
  const fallbackFilename = getProjectAnalyticsExportFallbackFilename(filterPeriod, projectCode);
  const filename = getProjectAnalyticsExportFilename(response, fallbackFilename);
  triggerProjectAnalyticsExportDownload(reportBlob, filename);
  showToast(t("projects.analyticsExportSuccess"), "success");
  return true;
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
  // The portfolio switches scope locally, so the bootstrap intentionally
  // carries both active and archived summaries in one consistent snapshot.
  params.set("scope", "all");
  params.set("includeDetail", projectCode ? "true" : "false");

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
  return `${apiUrl}stats/projects/${encodeURIComponent(String(projectCode || "").trim())}${query ? `?${query}` : ""}`;
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
    const container = document.getElementById("projectDetailContainer");
    if (container) {
      container.setAttribute("aria-busy", "true");
    }
    destroyProjectWorkspaceTrendChart();
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
    destroyProjectWorkspaceTrendChart();
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.statsUnavailable"));
    return null;
  } finally {
    const isLatestPendingRequest = pendingProjectDetailRequest
      && pendingProjectDetailRequest.requestVersion === requestVersion;
    if (isLatestPendingRequest && isCurrentProjectDetailRequest(requestVersion, projectCode, filterPeriod)) {
      const container = document.getElementById("projectDetailContainer");
      if (container) {
        container.setAttribute("aria-busy", "false");
      }
    }
    if (isLatestPendingRequest) {
      pendingProjectDetailRequest = null;
    }
  }
}

async function refreshProjectsView() {
  clearProjectDetailCache();
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  syncProjectPortfolioControls();
  const routeProjectCode = getProjectWorkspaceRouteCode();
  const shouldOpenWorkspaceFromRoute = Boolean(routeProjectCode) && !projectsViewState.workspaceOpen;
  if (routeProjectCode) {
    projectsViewState.workspaceOpen = true;
    currentProjectCode = routeProjectCode;
    setProjectWorkspaceVisibility(true, { focus: false });
  }
  const requestedProjectCode = projectsViewState.workspaceOpen ? currentProjectCode : null;
  const addButton = document.getElementById("addProjectButton");
  if (addButton) {
    addButton.classList.toggle("d-none", !canManageProjects());
  }
  setLoadingState("projectsSummaryContainer", "grid", 4);
  if (projectsViewState.workspaceOpen) {
    const detailContainer = document.getElementById("projectDetailContainer");
    if (detailContainer) {
      detailContainer.setAttribute("aria-busy", "true");
    }
    destroyProjectWorkspaceTrendChart();
    setLoadingState("projectDetailContainer", "detail", 1);
  }
  setChartLoadingState("projectChartContainer");
  setProjectInsightsLoadingState();

  try {
    const response = await fetch(buildProjectBootstrapUrl(currentProjectFilter, requestedProjectCode));
    const payload = await parseResponse(response);
    const summary = Array.isArray(payload && payload.summary) ? payload.summary : [];
    const trends = payload && payload.trends ? payload.trends : {};
    projectsViewState.projects = summary;
    projectsViewState.trends = trends;
    projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();
    projectsViewState.portfolioScope = getProjectPortfolioScopeValue();
    projectsViewState.portfolioSort = getProjectPortfolioSortValue();

    const visibleProjects = getVisibleProjectSummaries(summary);
    if (projectsViewState.workspaceOpen) {
      const requestedProject = summary.find(project => String(project.projectCode || "") === String(requestedProjectCode || ""));
      currentProjectCode = requestedProjectCode && payload && String(payload.selectedProjectCode || "") === String(requestedProjectCode)
        ? payload.selectedProjectCode
        : (requestedProject ? requestedProject.projectCode : null);
      if (!currentProjectCode) {
        projectsViewState.workspaceOpen = false;
        setProjectWorkspaceVisibility(false, { restoreFocus: false });
        if (routeProjectCode) {
          setProjectWorkspaceRoute("", { replace: true });
        }
      }
    } else {
      currentProjectCode = null;
    }

    renderProjectSummaryCards(summary);
    renderProjectMultiLineChart(trends);
    renderProjectInsights(summary);

    if (projectsViewState.workspaceOpen) {
      syncProjectWorkspaceHeader(getProjectByCode(currentProjectCode));
    }

    if (projectsViewState.workspaceOpen && payload && payload.selectedProject && String(payload.selectedProject.projectCode || "") === String(currentProjectCode || "")) {
      projectDetailCache[getProjectDetailCacheKey(payload.selectedProject.projectCode, currentProjectFilter)] = payload.selectedProject;
      renderProjectDetail(payload.selectedProject);
    } else if (projectsViewState.workspaceOpen && currentProjectCode) {
      await loadProjectDetailStats(currentProjectCode, currentProjectFilter);
    } else {
      const detailContainer = document.getElementById("projectDetailContainer");
      if (detailContainer) {
        detailContainer.setAttribute("aria-busy", "false");
        destroyProjectWorkspaceTrendChart();
        detailContainer.innerHTML = "";
      }
      setProjectWorkspaceVisibility(false, { restoreFocus: false });
    }
    if (shouldOpenWorkspaceFromRoute) {
      const title = document.getElementById("projectWorkspaceTitle");
      if (title) {
        title.focus({ preventScroll: true });
      }
    }
    const detailContainer = document.getElementById("projectDetailContainer");
    if (detailContainer) {
      detailContainer.setAttribute("aria-busy", "false");
    }
    return true;
  } catch (error) {
    console.error("Error loading project data:", error);
    document.getElementById("projectsSummaryContainer").innerHTML = createEmptyState(t("projects.unableToLoad"));
    destroyProjectWorkspaceTrendChart();
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.statsUnavailable"));
    const chartStage = document.querySelector("#projectChartContainer .chart-stage");
    if (chartStage) {
      chartStage.innerHTML = createEmptyState(t("projects.chartLoadError"));
    }
    document.getElementById("projectInsightsSummary").innerHTML = createEmptyState(t("projects.unableToLoad"));
    const detailContainer = document.getElementById("projectDetailContainer");
    if (detailContainer) {
      detailContainer.setAttribute("aria-busy", "false");
    }
    setProjectInsightEmptyState("projectOvertimeShareChart", "projects.chartLoadError");
    setProjectInsightEmptyState("projectSectorDistributionChart", "projects.chartLoadError");
    return false;
  }
}

function renderProjectSummaryCards(projectDetails) {
  const container = document.getElementById("projectsSummaryContainer");
  const allProjects = Array.isArray(projectDetails) ? projectDetails : [];
  const scopedProjects = getScopedProjectSummaries(allProjects);
  const visibleProjects = getVisibleProjectSummaries(allProjects);
  updateProjectPortfolioCount(visibleProjects.length, scopedProjects.length);

  if (allProjects.length === 0) {
    container.classList.remove("is-sectioned");
    container.innerHTML = createEmptyState(t("projects.noStats"));
    return;
  }

  if (scopedProjects.length === 0) {
    container.classList.remove("is-sectioned");
    container.innerHTML = createEmptyState(t("projects.noProjectsInScope"));
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
      projectsViewState.workspaceOpen
        && String(card.getAttribute("data-project-code") || "") === String(currentProjectCode || "")
    );
  });
}

function renderProjectSummaryCard(detail) {
  const approvedSeconds = getProjectWorkspaceApprovedSeconds(detail);
  const total = secondsToDurationLabel(approvedSeconds);
  const approvedCount = Number(detail.approvedEntryCount != null ? detail.approvedEntryCount : detail.entryCount || 0);
  const averageSeconds = Number.isFinite(Number(detail.averageSeconds))
    ? Number(detail.averageSeconds)
    : timeStringToSeconds(detail.averageOvertime || "00:00:00");
  const pending = getProjectWorkspaceStatusBucket(detail, "pending");
  const admins = Array.isArray(detail.admins) ? detail.admins : [];
  const backupAdmins = Array.isArray(detail.backupAdmins) ? detail.backupAdmins : [];
  const projectName = String(detail.projectName || "").trim();
  const projectTitle = getProjectDisplayName(detail);
  const projectNote = [projectName ? detail.projectCode : "", detail.sector].filter(Boolean).join(" | ");
  const archivedBadge = isProjectArchived(detail) ? `<span class="status-badge rejected">${escapeHtml(t("projects.archived"))}</span>` : "";
  const restoreAction = canManageProjects() && isProjectArchived(detail)
    ? `<div class="employee-card-actions"><button type="button" class="btn btn-outline-primary btn-sm project-restore-button" data-project-code="${escapeHtml(detail.projectCode)}">${escapeHtml(t("projects.reinstate"))}</button></div>`
    : "";
  return `
    <article class="project-summary-card project-colored-surface${projectsViewState.workspaceOpen && currentProjectCode === detail.projectCode ? " is-active" : ""}${isProjectArchived(detail) ? " is-archived" : ""}" style="${getProjectColorStyle(detail)}" data-project-code="${escapeHtml(detail.projectCode)}">
      <div class="project-card-header">
        <div>
          <div class="project-card-title d-flex align-items-center gap-2">${renderProjectColorDot(detail)}<button type="button" class="project-card-title-button project-open-button" data-project-code="${escapeHtml(detail.projectCode)}" aria-controls="projectWorkspace">${escapeHtml(projectTitle)}</button></div>
          ${projectNote ? `<div class="employee-card-note">${escapeHtml(projectNote)}</div>` : ""}
        </div>
        <div class="project-card-status-stack">
          ${archivedBadge}
          <span class="inline-code-pill">${escapeHtml(total)}</span>
        </div>
      </div>
      <div class="project-card-meta">
        <span class="meta-pill">${escapeHtml(t("projects.approvedEntries", { count: approvedCount }))}</span>
        <span class="meta-pill">${escapeHtml(t("projects.average", { value: secondsToDurationLabel(averageSeconds) }))}</span>
        ${pending.count > 0 ? `<span class="status-badge pending">${escapeHtml(t("projects.pendingShort", { count: pending.count }))}</span>` : ""}
      </div>
      <div class="project-card-assignments">
        ${renderProjectAssignmentLine("projects.admins", detail.adminDisplay, admins)}
        ${renderProjectAssignmentLine("projects.backupAdmins", detail.backupAdminDisplay, backupAdmins)}
      </div>
      ${restoreAction}
    </article>
  `;
}

function applyProjectPortfolioSearch(options = {}) {
  projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();
  const visibleProjects = getVisibleProjectSummaries(projectsViewState.projects);
  const selectedProjectVisible = visibleProjects.some(project => String(project.projectCode || "") === String(currentProjectCode || ""));

  if (projectsViewState.workspaceOpen && !selectedProjectVisible) {
    const visibleProjectOrder = getProjectSummaryDisplayOrder(visibleProjects);
    currentProjectCode = visibleProjectOrder.length > 0 ? visibleProjectOrder[0].projectCode : null;
    if (options.updateDetail && projectsViewState.workspaceOpen) {
      if (currentProjectCode) {
        scheduleProjectDetailStats(currentProjectCode, currentProjectFilter);
      } else {
        supersedeProjectDetailRequests();
        const emptyKey = getScopedProjectSummaries(projectsViewState.projects).length === 0
          ? "projects.noProjectsInScope"
          : "projects.noMatchingProjects";
        destroyProjectWorkspaceTrendChart();
        document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t(emptyKey));
      }
    }
  }

  renderProjectSummaryCards(projectsViewState.projects);
}

function applyProjectPortfolioControls(options = {}) {
  projectsViewState.portfolioScope = getProjectPortfolioScopeValue();
  projectsViewState.portfolioSort = getProjectPortfolioSortValue();
  syncProjectPortfolioControls();
  applyProjectPortfolioSearch(options);
}

function getProjectWorkspaceContributors(detail) {
  const source = Array.isArray(detail && detail.contributors)
    ? detail.contributors
    : (Array.isArray(detail && detail.breakdownByEmployee) ? detail.breakdownByEmployee : []);
  const projectApprovedSeconds = getProjectWorkspaceApprovedSeconds(detail);
  return source.map(contributor => {
    const approvedSeconds = Number.isFinite(Number(contributor.approvedSeconds))
      ? Number(contributor.approvedSeconds)
      : timeStringToSeconds(contributor.overtime || "00:00:00");
    const approvedEntryCount = Number(contributor.approvedEntryCount != null
      ? contributor.approvedEntryCount
      : contributor.entryCount || 0);
    const entries = Array.isArray(contributor.entries) ? contributor.entries : [];
    const pendingEntries = entries.filter(entry => getProjectWorkspaceEntryStatus(entry) === "pending");
    const pendingSeconds = Number.isFinite(Number(contributor.pendingSeconds))
      ? Number(contributor.pendingSeconds)
      : pendingEntries.reduce((sum, entry) => sum + getProjectWorkspaceEntrySeconds(entry), 0);
    const lastActivityDate = String(contributor.lastActivityDate || contributor.lastActivityAt || getLatestProjectEntryDate(entries) || "");
    return {
      ...contributor,
      employee: String(contributor.employee || contributor.employeeName || contributor.employeeCode || ""),
      approvedSeconds,
      approvedEntryCount,
      pendingCount: Number(contributor.pendingCount != null ? contributor.pendingCount : pendingEntries.length),
      pendingSeconds,
      sharePercent: Number.isFinite(Number(contributor.sharePercent))
        ? Number(contributor.sharePercent)
        : (projectApprovedSeconds > 0 ? (approvedSeconds / projectApprovedSeconds) * 100 : 0),
      averageApprovedSeconds: Number.isFinite(Number(contributor.averageApprovedSeconds))
        ? Number(contributor.averageApprovedSeconds)
        : (approvedEntryCount > 0 ? approvedSeconds / approvedEntryCount : 0),
      lastActivityDate,
      entries,
    };
  });
}

function getProjectWorkspaceEntryStatus(entry) {
  if (entry && (entry.isOpen === true || entry.statusBucket === "open")) {
    return "open";
  }
  return String(entry && (entry.statusBucket || entry.status) || "pending").trim().toLowerCase();
}

function getProjectWorkspaceEntrySeconds(entry) {
  if (Number.isFinite(Number(entry && entry.durationSeconds))) {
    return Number(entry.durationSeconds);
  }
  if (Number.isFinite(Number(entry && entry.overtimeSeconds))) {
    return Number(entry.overtimeSeconds);
  }
  if (Number.isFinite(Number(entry && entry.totalSeconds))) {
    return Number(entry.totalSeconds);
  }
  return timeStringToSeconds(entry && entry.overtime || "00:00:00");
}

function getLatestProjectEntryDate(entries) {
  return (Array.isArray(entries) ? entries : []).reduce((latest, entry) => {
    const candidate = String(entry && (entry.activityAt || entry.date) || "");
    return candidate > latest ? candidate : latest;
  }, "");
}

function getProjectWorkspaceApprovedSeconds(detail) {
  const approvedBucket = detail && detail.statusBuckets && detail.statusBuckets.approved;
  if (approvedBucket && Number.isFinite(Number(approvedBucket.seconds))) {
    return Number(approvedBucket.seconds);
  }
  if (Number.isFinite(Number(detail && detail.totalSeconds))) {
    return Number(detail.totalSeconds);
  }
  return timeStringToSeconds(detail && detail.totalOvertime || "00:00:00");
}

function getProjectWorkspaceStatusBucket(detail, status) {
  const bucket = detail && detail.statusBuckets && detail.statusBuckets[status];
  if (bucket) {
    return {
      count: Number(bucket.count || 0),
      seconds: Number(bucket.seconds || 0),
    };
  }

  const entries = getProjectWorkspaceEntries(detail).filter(entry => getProjectWorkspaceEntryStatus(entry) === status);
  return {
    count: entries.length,
    seconds: entries.reduce((sum, entry) => sum + getProjectWorkspaceEntrySeconds(entry), 0),
  };
}

function getProjectWorkspaceEntries(detail) {
  if (Array.isArray(detail && detail.recentEntries)) {
    return detail.recentEntries.slice();
  }
  return getProjectWorkspaceContributors(detail).reduce((entries, contributor) => (
    entries.concat(contributor.entries.map(entry => ({
      ...entry,
      employeeCode: entry.employeeCode || contributor.employeeCode,
      employeeName: entry.employeeName || contributor.employee,
    })))
  ), []).sort((left, right) => {
    const leftKey = `${left.date || ""}T${left.punchIn || ""}`;
    const rightKey = `${right.date || ""}T${right.punchIn || ""}`;
    return rightKey.localeCompare(leftKey);
  });
}

function getProjectWorkspaceComparison(detail) {
  const comparison = detail && detail.comparison || {};
  if (comparison.available !== true || comparison.percentChange == null || !Number.isFinite(Number(comparison.percentChange))) {
    return { available: false, label: t("projects.notAvailable"), tone: "neutral" };
  }
  const value = Number(comparison.percentChange);
  const prefix = value > 0 ? "+" : "";
  return {
    available: true,
    label: `${prefix}${value.toLocaleString(typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined, { maximumFractionDigits: 1 })}%`,
    tone: value > 0 ? "up" : (value < 0 ? "down" : "neutral"),
  };
}

function getProjectWorkspaceShareLabel(detail) {
  const scope = String(detail && detail.departmentShare && detail.departmentShare.scope || "").trim();
  if (scope === "visibleProjects" && !canManageProjects()) {
    return t("projects.accessibleProjectsShare");
  }
  return t("projects.departmentShare");
}

function getProjectWorkspaceShareBasis(detail) {
  const scope = String(detail && detail.departmentShare && detail.departmentShare.scope || "").trim();
  if (scope === "visibleProjects" && !canManageProjects()) {
    return t("projects.accessibleProjectsShareBasis");
  }
  return t("projects.departmentShareBasis");
}

function normalizeProjectTrendPoints(detail) {
  const trend = detail && detail.approvedTrend;
  let points = [];
  if (Array.isArray(trend)) {
    points = trend.map((point, index) => ({
      label: String(point && (point.label || point.month || point.period) || index + 1),
      seconds: Number(point && (point.seconds != null ? point.seconds : point.totalSeconds != null ? point.totalSeconds : point.approvedSeconds) || 0),
    }));
  } else if (trend && Array.isArray(trend.labels) && Array.isArray(trend.values)) {
    points = trend.labels.map((label, index) => ({ label: String(label), seconds: Number(trend.values[index] || 0) }));
  }
  if (points.length === 0 || !points.every(point => /^\d{4}-\d{2}$/.test(point.label))) {
    return points;
  }

  const period = detail && detail.period || {};
  const firstPoint = points[0].label;
  const lastPoint = points[points.length - 1].label;
  const startMonth = /^\d{4}-\d{2}/.test(String(period.startDate || ""))
    ? String(period.startDate).slice(0, 7)
    : firstPoint;
  const endMonth = /^\d{4}-\d{2}/.test(String(period.endDate || ""))
    ? String(period.endDate).slice(0, 7)
    : lastPoint;
  const toMonthIndex = value => {
    const parts = value.split("-").map(Number);
    return (parts[0] * 12) + parts[1] - 1;
  };
  const startIndex = toMonthIndex(startMonth);
  const endIndex = toMonthIndex(endMonth);
  const monthCount = endIndex - startIndex + 1;
  if (!Number.isFinite(monthCount) || monthCount < 1 || monthCount > 240) {
    return points;
  }

  const pointMap = new Map(points.map(point => [point.label, point]));
  return Array.from({ length: monthCount }, (_, offset) => {
    const monthIndex = startIndex + offset;
    const year = Math.floor(monthIndex / 12);
    const month = (monthIndex % 12) + 1;
    const label = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}`;
    return pointMap.get(label) || { label, seconds: 0 };
  });
}

function formatProjectTrendPeriodLabel(value) {
  const label = String(value || "").trim();
  const monthMatch = /^(\d{4})-(\d{2})$/.exec(label);
  if (!monthMatch) {
    return label;
  }

  const year = Number(monthMatch[1]);
  const month = Number(monthMatch[2]);
  if (!Number.isInteger(year) || month < 1 || month > 12) {
    return label;
  }

  const locale = typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined;
  return new Intl.DateTimeFormat(locale, {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(year, month - 1, 1)));
}

function destroyProjectWorkspaceTrendChart() {
  if (pendingProjectWorkspaceTrendFrameId) {
    window.cancelAnimationFrame(pendingProjectWorkspaceTrendFrameId);
    pendingProjectWorkspaceTrendFrameId = null;
  }
  if (projectWorkspaceTrendChartInstance) {
    projectWorkspaceTrendChartInstance.destroy();
    projectWorkspaceTrendChartInstance = null;
  }
}

function renderProjectWorkspaceTrendTable(points) {
  return `
    <details class="project-workspace-trend-data">
      <summary>${escapeHtml(t("projects.trendDataToggle"))}</summary>
      <div class="project-workspace-trend-data-wrap">
        <table>
          <caption>${escapeHtml(t("projects.trendDataCaption"))}</caption>
          <thead>
            <tr>
              <th scope="col">${escapeHtml(t("projects.month"))}</th>
              <th scope="col">${escapeHtml(t("projects.duration"))}</th>
            </tr>
          </thead>
          <tbody>
            ${points.map(point => `
              <tr>
                <th scope="row">${escapeHtml(formatProjectTrendPeriodLabel(point.label))}</th>
                <td class="mono">${escapeHtml(secondsToDurationLabel(point.seconds))}</td>
              </tr>
            `).join("")}
          </tbody>
        </table>
      </div>
    </details>
  `;
}

function renderProjectWorkspaceTrend(detail) {
  const points = normalizeProjectTrendPoints(detail);
  if (points.length === 0) {
    return createEmptyState(t("projects.noTrendData"));
  }
  const total = points.reduce((sum, point) => sum + point.seconds, 0);
  return `
    <div class="project-workspace-trend">
      <div class="project-workspace-trend-chart">
        <canvas id="projectWorkspaceTrendChart" role="img"
          aria-label="${escapeHtml(t("projects.trendAccessible", { total: secondsToDurationLabel(total) }))}"></canvas>
      </div>
      <div id="projectWorkspaceTrendData">
        ${renderProjectWorkspaceTrendTable(points)}
      </div>
    </div>
  `;
}

function initializeProjectWorkspaceTrendChart(container, detail) {
  destroyProjectWorkspaceTrendChart();
  const canvas = container && container.querySelector("#projectWorkspaceTrendChart");
  const points = normalizeProjectTrendPoints(detail);
  if (!canvas || points.length === 0) {
    return;
  }

  const chartRegion = canvas.closest(".project-workspace-trend-chart");
  const dataFallback = container.querySelector(".project-workspace-trend-data");
  if (typeof Chart !== "function") {
    if (chartRegion) {
      chartRegion.innerHTML = createEmptyState(t("projects.chartLibraryFailed"));
    }
    if (dataFallback) {
      dataFallback.open = true;
    }
    return;
  }

  const theme = getProjectChartTheme();
  const projectColor = getProjectColorCssValue(detail);
  pendingProjectWorkspaceTrendFrameId = window.requestAnimationFrame(() => {
    pendingProjectWorkspaceTrendFrameId = null;
    if (!canvas.isConnected) {
      return;
    }
    const context = canvas.getContext("2d");
    if (!context) {
      return;
    }

    projectWorkspaceTrendChartInstance = new Chart(context, {
      type: "line",
      data: {
        labels: points.map(point => formatProjectTrendPeriodLabel(point.label)),
        datasets: [{
          label: t("projects.approvedHours"),
          data: points.map(point => Number(point.seconds) || 0),
          borderColor: projectColor,
          backgroundColor: projectColor,
          fill: false,
          borderWidth: 2.5,
          tension: 0.24,
          pointRadius: 4,
          pointHoverRadius: 6,
          pointHitRadius: 16,
        }],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        resizeDelay: 100,
        locale: typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined,
        interaction: {
          mode: "nearest",
          intersect: false,
        },
        plugins: {
          legend: {
            display: false,
          },
          tooltip: {
            enabled: true,
            backgroundColor: theme.tooltip,
            titleColor: theme.tooltipText,
            bodyColor: theme.tooltipText,
            displayColors: false,
            padding: 10,
            callbacks: {
              label: tooltipContext => `${t("projects.approvedHours")}: ${secondsToDurationLabel(tooltipContext.parsed.y)}`,
            },
          },
        },
        scales: {
          x: {
            grid: {
              display: false,
            },
            border: {
              color: theme.grid,
            },
            ticks: {
              color: theme.textMuted,
              maxRotation: 0,
              autoSkip: true,
              maxTicksLimit: 7,
            },
          },
          y: {
            beginAtZero: true,
            grid: {
              color: theme.grid,
            },
            border: {
              display: false,
            },
            ticks: {
              color: theme.textMuted,
              callback: value => secondsToDurationLabel(value),
              maxTicksLimit: 6,
            },
          },
        },
      },
    });
  });
}

function getSortedProjectWorkspaceContributors(detail) {
  const sortKey = projectsViewState.contributorSort.key;
  const direction = projectsViewState.contributorSort.direction === "asc" ? 1 : -1;
  const collator = getProjectPortfolioCollator();
  return getProjectWorkspaceContributors(detail).sort((left, right) => {
    if (sortKey === "employee") {
      return direction * compareProjectPortfolioText(left.employee, right.employee, collator);
    }
    if (sortKey === "lastActivityDate") {
      return direction * String(left.lastActivityDate || "").localeCompare(String(right.lastActivityDate || ""));
    }
    return direction * (Number(left[sortKey] || 0) - Number(right[sortKey] || 0));
  });
}

function renderProjectWorkspaceSortButton(key, label) {
  const active = projectsViewState.contributorSort.key === key;
  const direction = projectsViewState.contributorSort.direction;
  const icon = active ? (direction === "asc" ? "fa-arrow-up" : "fa-arrow-down") : "fa-sort";
  return `<button type="button" class="project-contributor-sort" data-sort-key="${escapeHtml(key)}" aria-pressed="${active ? "true" : "false"}">${escapeHtml(label)} <i class="fa-solid ${icon}" aria-hidden="true"></i></button>`;
}

function renderProjectWorkspaceContributors(detail) {
  const contributors = getSortedProjectWorkspaceContributors(detail);
  if (contributors.length === 0) {
    return createEmptyState(t("projects.noEntriesForProject"));
  }
  return `
    <div class="project-workspace-table-wrap">
      <table class="project-workspace-table">
        <thead>
          <tr>
            <th>${renderProjectWorkspaceSortButton("employee", t("projects.contributor"))}</th>
            <th>${renderProjectWorkspaceSortButton("approvedSeconds", t("projects.approvedHours"))}</th>
            <th>${renderProjectWorkspaceSortButton("sharePercent", t("projects.share"))}</th>
            <th>${renderProjectWorkspaceSortButton("approvedEntryCount", t("projects.entriesLabel"))}</th>
            <th>${renderProjectWorkspaceSortButton("pendingCount", t("status.pending"))}</th>
            <th>${renderProjectWorkspaceSortButton("lastActivityDate", t("projects.lastActivity"))}</th>
            <th><span class="visually-hidden">${escapeHtml(t("projects.workspaceActions"))}</span></th>
          </tr>
        </thead>
        <tbody>
          ${contributors.map(contributor => `
            <tr>
              <td>
                <strong>${escapeHtml(contributor.employee)}</strong>
                ${contributor.employeeCode ? `<span class="project-workspace-cell-note mono">${escapeHtml(contributor.employeeCode)}</span>` : ""}
              </td>
              <td class="mono">${escapeHtml(secondsToDurationLabel(contributor.approvedSeconds))}</td>
              <td>${escapeHtml(`${contributor.sharePercent.toLocaleString(typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined, { maximumFractionDigits: 1 })}%`)}</td>
              <td>${escapeHtml(contributor.approvedEntryCount)}</td>
              <td>${contributor.pendingCount > 0 ? `<span class="status-badge pending">${escapeHtml(contributor.pendingCount)}</span>` : "0"}</td>
              <td>${contributor.lastActivityDate ? escapeHtml(formatDateLabel(contributor.lastActivityDate.slice(0, 10))) : escapeHtml(t("projects.notAvailable"))}</td>
              <td>
                <button type="button" class="btn btn-outline-secondary btn-sm project-people-navigator" data-employee-code="${escapeHtml(contributor.employeeCode || "")}" data-project-code="${escapeHtml(detail.projectCode)}" aria-label="${escapeHtml(t("projects.openContributor", { name: contributor.employee }))}">
                  <i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i>
                </button>
              </td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    </div>
  `;
}

function renderProjectWorkspaceRecentEntries(detail) {
  const entries = getProjectWorkspaceEntries(detail);
  if (entries.length === 0) {
    return createEmptyState(t("projects.noEntriesForProject"));
  }
  const visibleEntries = projectsViewState.workspaceEntriesExpanded
    ? entries
    : entries.slice(0, PROJECT_WORKSPACE_RECENT_ENTRY_LIMIT);
  return `
    <div class="project-workspace-entry-list">
      ${visibleEntries.map(entry => {
        const status = getProjectWorkspaceEntryStatus(entry);
        const statusEntry = { ...entry, status: status === "open" ? "pending" : status };
        const exactTimeLabel = getEntryExactTimeLabel(entry);
        const canOpen = Boolean(entry.employeeCode && entry.entryId);
        return `
          <article class="project-workspace-entry-row">
            <div class="project-workspace-entry-identity">
              <strong>${escapeHtml(entry.employeeName || entry.employee || entry.employeeCode || t("projects.unknownEmployee"))}</strong>
              <span>${escapeHtml(formatDateLabel(entry.date))}</span>
            </div>
            <div class="project-workspace-entry-time">
              <span class="mono">${getEntryRoundedTimeRangeMarkup(entry)}</span>
              ${exactTimeLabel ? `<span class="project-workspace-cell-note">${escapeHtml(exactTimeLabel)}</span>` : ""}
            </div>
            <span class="mono project-workspace-entry-duration">${escapeHtml(secondsToDurationLabel(getProjectWorkspaceEntrySeconds(entry)))}</span>
            <span class="status-badge ${escapeHtml(status === "open" ? "pending" : getStatusTone(statusEntry))}">${escapeHtml(status === "open" ? t("projects.openEntry") : getEntryStatusLabel(statusEntry))}</span>
            <div class="project-workspace-entry-notes">${renderEntryNotesPreview(entry)}</div>
            ${canOpen ? `
              <button type="button" class="btn btn-outline-secondary btn-sm project-entry-navigator" data-employee-code="${escapeHtml(entry.employeeCode)}" data-project-code="${escapeHtml(detail.projectCode)}" data-entry-id="${escapeHtml(entry.entryId)}" aria-label="${escapeHtml(t("projects.openEntryForEmployee", { name: entry.employeeName || entry.employee || entry.employeeCode }))}">
                <i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i>
              </button>
            ` : ""}
          </article>
        `;
      }).join("")}
    </div>
    ${entries.length > PROJECT_WORKSPACE_RECENT_ENTRY_LIMIT ? `
      <button type="button" class="btn btn-outline-secondary btn-sm project-workspace-entry-toggle" aria-expanded="${projectsViewState.workspaceEntriesExpanded ? "true" : "false"}">
        ${escapeHtml(projectsViewState.workspaceEntriesExpanded ? t("projects.showRecentOnly") : t("projects.showRecentEntries", { count: entries.length }))}
      </button>
    ` : ""}
  `;
}

function renderProjectWorkspaceAttention(detail) {
  const pending = getProjectWorkspaceStatusBucket(detail, "pending");
  const open = getProjectWorkspaceStatusBucket(detail, "open");
  const items = [];
  if (pending.count > 0) {
    const pendingLabel = pending.count === 1
      ? t("projects.pendingEntry")
      : t("projects.pendingEntries", { count: pending.count });
    items.push(`<li><span class="project-attention-dot pending" aria-hidden="true"></span><span><strong>${escapeHtml(pendingLabel)}</strong><small>${escapeHtml(secondsToDurationLabel(pending.seconds))}</small></span></li>`);
  }
  if (open.count > 0) {
    const openLabel = open.count === 1
      ? t("projects.openEntryCount")
      : t("projects.openEntries", { count: open.count });
    items.push(`<li><span class="project-attention-dot live" aria-hidden="true"></span><span><strong>${escapeHtml(openLabel)}</strong><small>${escapeHtml(t("projects.openEntriesHint"))}</small></span></li>`);
  }
  return items.length > 0
    ? `<ul class="project-attention-list">${items.join("")}</ul>`
    : `<div class="project-attention-clear"><i class="fa-solid fa-circle-check" aria-hidden="true"></i><span>${escapeHtml(t("projects.nothingNeedsAttention"))}</span></div>`;
}

function renderProjectDetail(detail) {
  destroyProjectWorkspaceTrendChart();
  const container = document.getElementById("projectDetailContainer");
  if (!container) {
    return;
  }
  if (!detail) {
    container.innerHTML = createEmptyState(t("projects.statsUnavailable"));
    return;
  }

  syncProjectWorkspaceHeader(detail);
  const contributors = getProjectWorkspaceContributors(detail);
  const approvedSeconds = getProjectWorkspaceApprovedSeconds(detail);
  const approvedCount = Number(detail.approvedEntryCount != null ? detail.approvedEntryCount : detail.entryCount || 0);
  const pending = getProjectWorkspaceStatusBucket(detail, "pending");
  const comparison = getProjectWorkspaceComparison(detail);
  const departmentShare = detail.departmentShare && detail.departmentShare.percent != null && Number.isFinite(Number(detail.departmentShare.percent))
    ? Number(detail.departmentShare.percent)
    : null;
  const admins = Array.isArray(detail.admins) ? detail.admins : [];
  const backupAdmins = Array.isArray(detail.backupAdmins) ? detail.backupAdmins : [];
  const reviewButton = document.getElementById("projectWorkspaceReviewButton");
  if (reviewButton) {
    reviewButton.querySelector("span").textContent = pending.count > 0
      ? t("projects.reviewPendingCount", { count: pending.count })
      : t("projects.reviewPending");
  }

  container.innerHTML = `
    <div class="project-workspace-meta">
      ${renderProjectColorDot(detail)}
      ${detail.sector ? `<span class="meta-pill">${escapeHtml(t("projects.sector"))}: ${escapeHtml(detail.sector)}</span>` : ""}
      ${renderProjectAdminMeta("projects.admins", detail.adminDisplay, admins, "meta-pill-owner")}
      ${renderProjectAdminMeta("projects.backupAdmins", detail.backupAdminDisplay, backupAdmins)}
      ${isProjectArchived(detail) ? `<span class="status-badge rejected">${escapeHtml(t("projects.archived"))}</span>` : ""}
    </div>

    <section class="project-workspace-metrics" aria-label="${escapeHtml(t("projects.keyMetrics"))}">
      <article class="project-workspace-metric project-workspace-metric-primary">
        <span>${escapeHtml(t("projects.approvedHours"))}</span>
        <strong class="mono">${escapeHtml(secondsToDurationLabel(approvedSeconds))}</strong>
        <small>${escapeHtml(t("projects.approvedEntries", { count: approvedCount }))}</small>
      </article>
      <article class="project-workspace-metric">
        <span>${escapeHtml(t("projects.pendingHours"))}</span>
        <strong class="mono">${escapeHtml(secondsToDurationLabel(pending.seconds))}</strong>
        <small>${escapeHtml(pending.count === 1 ? t("projects.pendingEntry") : t("projects.pendingEntries", { count: pending.count }))}</small>
      </article>
      <article class="project-workspace-metric">
        <span>${escapeHtml(t("projects.contributors"))}</span>
        <strong class="mono">${escapeHtml(contributors.length)}</strong>
        <small>${escapeHtml(t("projects.selectedPeriod"))}</small>
      </article>
      <article class="project-workspace-metric project-workspace-comparison-${escapeHtml(comparison.tone)}">
        <span>${escapeHtml(t("projects.vsPreviousPeriod"))}</span>
        <strong>${escapeHtml(comparison.label)}</strong>
        <small>${escapeHtml(comparison.available ? t("projects.approvedHoursBasis") : t("projects.noPreviousPeriod"))}</small>
      </article>
      <article class="project-workspace-metric">
        <span>${escapeHtml(getProjectWorkspaceShareLabel(detail))}</span>
        <strong>${departmentShare == null ? escapeHtml(t("projects.notAvailable")) : escapeHtml(`${departmentShare.toLocaleString(typeof getCurrentLocale === "function" ? getCurrentLocale() : undefined, { maximumFractionDigits: 1 })}%`)}</strong>
        <small>${escapeHtml(getProjectWorkspaceShareBasis(detail))}</small>
      </article>
    </section>

    <div class="project-workspace-overview-grid">
      <section class="project-workspace-panel">
        <div class="project-workspace-section-heading">
          <div>
            <span class="panel-kicker">${escapeHtml(t("projects.approvedTrend"))}</span>
            <h3>${escapeHtml(t("projects.usageOverTime"))}</h3>
          </div>
          <span class="panel-note">${escapeHtml(t("projects.trendInteractionHint"))}</span>
        </div>
        ${renderProjectWorkspaceTrend(detail)}
      </section>
      <aside class="project-workspace-panel project-workspace-attention">
        <div class="project-workspace-section-heading">
          <div>
            <span class="panel-kicker">${escapeHtml(t("projects.attention"))}</span>
            <h3>${escapeHtml(t("projects.needsAttention"))}</h3>
          </div>
        </div>
        ${renderProjectWorkspaceAttention(detail)}
      </aside>
    </div>

    <section class="project-workspace-panel">
      <div class="project-workspace-section-heading">
        <div>
          <span class="panel-kicker">${escapeHtml(t("projects.contributors"))}</span>
          <h3>${escapeHtml(t("projects.employeeBreakdown"))}</h3>
        </div>
        <span class="panel-note">${escapeHtml(t("projects.sortContributorsHint"))}</span>
      </div>
      <div id="projectWorkspaceContributorsContainer">${renderProjectWorkspaceContributors(detail)}</div>
    </section>

    <section class="project-workspace-panel">
      <div class="project-workspace-section-heading">
        <div>
          <span class="panel-kicker">${escapeHtml(t("projects.activity"))}</span>
          <h3>${escapeHtml(t("projects.recentEntries"))}</h3>
        </div>
        <span class="panel-note">${escapeHtml(t("projects.recentEntriesHint"))}</span>
      </div>
      <div id="projectWorkspaceEntriesContainer">${renderProjectWorkspaceRecentEntries(detail)}</div>
    </section>
  `;
  initializeProjectWorkspaceTrendChart(container, detail);
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
  const colorKey = normalizeProjectColorKey(document.getElementById("projectEditorColorSelect").value, projectCode);
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
        colorKey,
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

async function restoreProject(project) {
  if (!canManageProjects() || !project || !project.projectCode) {
    return false;
  }

  const projectName = String(project.projectName || "").trim();
  const confirmed = window.confirm(t(projectName ? "projects.restoreConfirm" : "projects.restoreConfirmCodeOnly", {
    name: projectName,
    code: project.projectCode,
  }));
  if (!confirmed) {
    return false;
  }

  try {
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(project.projectCode) + "/restore", {
      method: "POST",
    });
    await parseResponse(response);
    invalidateProjectLookupCaches();
    if (currentProjectCode === project.projectCode) {
      currentProjectCode = null;
    }
    showToast(t("projects.projectRestored"), "success");
    await refreshProjectsView();
    return true;
  } catch (error) {
    console.error("Error restoring project:", error);
    showToast(error.message || t("projects.restoreError"), "error");
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
      borderColor: findProjectByCode(projectsViewState.projects, projectCode)
        ? getProjectColorCssValue(findProjectByCode(projectsViewState.projects, projectCode))
        : colors[index % colors.length],
      backgroundColor: findProjectByCode(projectsViewState.projects, projectCode)
        ? getProjectColorCssValue(findProjectByCode(projectsViewState.projects, projectCode))
        : colors[index % colors.length],
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
  const openButton = event.target.closest(".project-open-button");
  if (openButton) {
    event.stopPropagation();
    const projectCode = openButton.getAttribute("data-project-code");
    if (projectCode) {
      runButtonAction(openButton, () => openProjectDetailFromPortfolio(projectCode, currentProjectFilter, { opener: openButton }), {
        key: `project-detail:${projectCode}`,
      }).catch(error => {
        console.error("Unable to open project details:", error);
        showToast(t("projects.statsUnavailable"), "error");
      });
    }
    return;
  }

  const restoreButton = event.target.closest(".project-restore-button");
  if (restoreButton) {
    event.stopPropagation();
    const project = getProjectByCode(restoreButton.getAttribute("data-project-code"));
    if (project) {
      runButtonAction(restoreButton, () => restoreProject(project), {
        key: "project-editor-mutation",
        disableWhileRunning: () => document.querySelectorAll(".project-restore-button"),
      }).catch(error => {
        console.error("Unable to restore project:", error);
        showToast(error.message || t("projects.restoreError"), "error");
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
    const fallbackOpener = projectCard.querySelector(".project-card-title-button.project-open-button");
    openProjectDetailFromPortfolio(projectCode, currentProjectFilter, { opener: fallbackOpener }).catch(error => {
      console.error("Unable to open project workspace:", error);
      showToast(t("projects.statsUnavailable"), "error");
    });
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

const projectPortfolioScopeSelect = document.getElementById("projectPortfolioScopeSelect");
if (projectPortfolioScopeSelect) {
  projectPortfolioScopeSelect.addEventListener("change", () => {
    projectsViewState.portfolioScope = getProjectPortfolioScopeValue();
    applyProjectPortfolioControls({ updateDetail: true });
  });
}

const projectPortfolioSortSelect = document.getElementById("projectPortfolioSortSelect");
if (projectPortfolioSortSelect) {
  projectPortfolioSortSelect.addEventListener("change", () => {
    projectsViewState.portfolioSort = getProjectPortfolioSortValue();
    applyProjectPortfolioControls({ updateDetail: false });
  });
}

const projectPortfolioResetButton = document.getElementById("projectPortfolioResetButton");
if (projectPortfolioResetButton) {
  projectPortfolioResetButton.addEventListener("click", () => {
    const searchInput = document.getElementById("projectPortfolioSearchInput");
    if (searchInput) {
      searchInput.value = "";
    }
    projectsViewState.portfolioSearch = "";
    projectsViewState.portfolioScope = "active";
    projectsViewState.portfolioSort = "activity";
    syncProjectPortfolioControls();
    applyProjectPortfolioControls({ updateDetail: true });
  });
}

document.getElementById("projectDetailContainer").addEventListener("click", event => {
  const sortButton = event.target.closest(".project-contributor-sort");
  if (sortButton) {
    const sortKey = sortButton.getAttribute("data-sort-key");
    if (sortKey) {
      const currentSort = projectsViewState.contributorSort;
      projectsViewState.contributorSort = {
        key: sortKey,
        direction: currentSort.key === sortKey && currentSort.direction === "desc" ? "asc" : "desc",
      };
      const cacheKey = getProjectDetailCacheKey(currentProjectCode, currentProjectFilter);
      const detail = projectDetailCache[cacheKey];
      const contributorsContainer = document.getElementById("projectWorkspaceContributorsContainer");
      if (detail && contributorsContainer) {
        contributorsContainer.innerHTML = renderProjectWorkspaceContributors(detail);
      }
    }
    return;
  }

  const entryToggle = event.target.closest(".project-workspace-entry-toggle");
  if (entryToggle) {
    projectsViewState.workspaceEntriesExpanded = !projectsViewState.workspaceEntriesExpanded;
    const cacheKey = getProjectDetailCacheKey(currentProjectCode, currentProjectFilter);
    const detail = projectDetailCache[cacheKey];
    const entriesContainer = document.getElementById("projectWorkspaceEntriesContainer");
    if (detail && entriesContainer) {
      entriesContainer.innerHTML = renderProjectWorkspaceRecentEntries(detail);
    }
    return;
  }

  const entryNavigator = event.target.closest(".project-entry-navigator");
  if (entryNavigator) {
    const employeeCode = entryNavigator.getAttribute("data-employee-code");
    const projectCode = entryNavigator.getAttribute("data-project-code");
    const entryId = entryNavigator.getAttribute("data-entry-id");
    if (typeof window.openEmployeeEntryInPeopleView === "function") {
      runButtonAction(entryNavigator, () => window.openEmployeeEntryInPeopleView(employeeCode, projectCode, entryId), {
        key: `open-project-entry:${employeeCode}:${entryId}`,
      }).catch(error => {
        console.error("Unable to open project entry:", error);
        showToast(t("employees.loadError"), "error");
      });
    }
    return;
  }

  const navigatorButton = event.target.closest(".project-people-navigator");
  if (!navigatorButton) {
    return;
  }

  const employeeCode = navigatorButton.getAttribute("data-employee-code");
  const projectCode = navigatorButton.getAttribute("data-project-code");
  if (typeof window.openEmployeeEntryInPeopleView === "function") {
    runButtonAction(navigatorButton, () => window.openEmployeeEntryInPeopleView(employeeCode, projectCode, ""), {
      key: "open-employee",
    }).catch(error => {
      console.error("Unable to open employee file:", error);
      showToast(t("employees.loadError"), "error");
    });
  }
});

document.getElementById("projectWorkspaceBackButton").addEventListener("click", () => {
  closeProjectWorkspace({ updateRoute: true, restoreFocus: true });
});

document.getElementById("projectWorkspaceReviewButton").addEventListener("click", event => {
  const projectCode = event.currentTarget.getAttribute("data-project-code") || currentProjectCode;
  if (typeof window.openProjectInReview !== "function") {
    showToast(t("review.loadError"), "error");
    return;
  }
  runButtonAction(event.currentTarget, () => window.openProjectInReview(projectCode), {
    key: `project-review:${projectCode}`,
  }).catch(error => {
    console.error("Unable to open project review:", error);
    showToast(error.message || t("review.loadError"), "error");
  });
});

document.getElementById("projectWorkspaceEntriesButton").addEventListener("click", event => {
  const projectCode = event.currentTarget.getAttribute("data-project-code") || currentProjectCode;
  if (typeof window.openProjectEntriesInPeople !== "function") {
    showToast(t("employees.loadError"), "error");
    return;
  }
  runButtonAction(event.currentTarget, () => window.openProjectEntriesInPeople(projectCode), {
    key: `project-entries:${projectCode}`,
  }).catch(error => {
    console.error("Unable to open project entries:", error);
    showToast(error.message || t("employees.loadError"), "error");
  });
});

document.getElementById("projectWorkspaceExportButton").addEventListener("click", event => {
  const projectCode = event.currentTarget.getAttribute("data-project-code") || currentProjectCode;
  runButtonAction(event.currentTarget, () => downloadProjectAnalyticsHtmlReport(currentProjectFilter, projectCode), {
    key: `project-analytics-html-export:${projectCode}`,
  }).catch(error => {
    console.error("Unable to export the project analytics report:", error);
    showToast(t("projects.analyticsExportError", { message: error.message || error }), "error");
  });
});

document.getElementById("projectWorkspaceEditButton").addEventListener("click", event => {
  const project = getProjectByCode(event.currentTarget.getAttribute("data-project-code") || currentProjectCode);
  if (!project || !canManageProjects()) {
    return;
  }
  runButtonAction(event.currentTarget, () => openProjectEditorModal("edit", project), {
    key: "project-editor-open",
  }).catch(error => {
    console.error("Unable to open project editor:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});

document.getElementById("projectWorkspaceRangeSelect").addEventListener("change", event => {
  const nextRange = event.currentTarget.value;
  if (nextRange === "custom" && currentProjectFilter !== "custom") {
    event.currentTarget.value = currentProjectFilter;
    showToast(t("projects.customRangeInPortfolio"), "info");
    return;
  }
  if (!nextRange || nextRange === currentProjectFilter) {
    return;
  }
  runButtonAction(event.currentTarget, () => setProjectRange(nextRange), {
    key: "projects-filter-refresh",
  }).catch(error => {
    console.error("Unable to change the project workspace range:", error);
    showToast(t("projects.unableToLoad"), "error");
  });
});

window.addEventListener("popstate", syncProjectWorkspaceFromRoute);
window.addEventListener("hashchange", syncProjectWorkspaceFromRoute);

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
document.getElementById("projectAnalyticsExportButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, () => downloadProjectAnalyticsHtmlReport(currentProjectFilter), {
    key: "project-analytics-html-export",
  }).catch(error => {
    console.error("Unable to export the analytics report:", error);
    showToast(t("projects.analyticsExportError", { message: error.message || error }), "error");
  });
});
document.getElementById("addProjectButton").addEventListener("click", event => {
  runButtonAction(event.currentTarget, () => openProjectEditorModal("create"), {
    key: "project-editor-open",
    disableWhileRunning: () => document.querySelectorAll("#addProjectButton"),
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
const projectEditorRestoreButton = document.getElementById("projectEditorRestoreButton");
if (projectEditorRestoreButton) {
  projectEditorRestoreButton.addEventListener("click", event => {
    runButtonAction(event.currentTarget, async () => {
      const project = getProjectByCode(document.getElementById("projectEditorOriginalCodeInput").value.trim());
      const restored = await restoreProject(project);
      if (restored) {
        const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
        if (modal) {
          modal.hide();
        }
      }
    }, { key: "project-editor-mutation" }).catch(error => {
      console.error("Error restoring project:", error);
      showToast(error.message || t("projects.restoreError"), "error");
    });
  });
}
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
document.getElementById("projectEditorColorSelect").addEventListener("change", syncProjectEditorColorPreview);
document.getElementById("projectEditorCodeInput").addEventListener("input", syncProjectEditorColorPreview);
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
  if (projectsViewState.workspaceOpen && currentProjectCode) {
    const cacheKey = getProjectDetailCacheKey(currentProjectCode, currentProjectFilter);
    const detail = projectDetailCache[cacheKey];
    const container = document.getElementById("projectDetailContainer");
    if (detail && container) {
      initializeProjectWorkspaceTrendChart(container, detail);
    }
  }
});

window.rerenderProjectsViewForLanguageChange = function () {
  const selectedEditorColor = document.getElementById("projectEditorColorSelect")?.value || "blue";
  renderProjectEditorColorOptions(selectedEditorColor);
  projectsViewState.portfolioSearch = getProjectPortfolioSearchValue();
  syncProjectRangeButtons();
  syncProjectCustomRangeInputs();
  syncProjectPortfolioControls();
  renderProjectSummaryCards(projectsViewState.projects || []);
  renderProjectMultiLineChart(projectsViewState.trends || {});
  renderProjectInsights(projectsViewState.projects || []);

  const cacheKey = currentProjectCode
    ? getProjectDetailCacheKey(currentProjectCode, currentProjectFilter)
    : "";
  if (cacheKey && projectDetailCache[cacheKey]) {
    renderProjectDetail(projectDetailCache[cacheKey]);
  } else if (!currentProjectCode) {
    destroyProjectWorkspaceTrendChart();
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState(t("projects.selectToInspect"));
  }
};
