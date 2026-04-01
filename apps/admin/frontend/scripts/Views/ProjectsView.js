const projectDetailCache = {};
let currentProjectFilter = "6M";
let currentProjectCode = null;
let pendingProjectChartFrameId = null;
const projectsViewState = {
  projects: [],
};

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
  document.getElementById("projectEditorRemoveButton").classList.add("d-none");
  setProjectEditorMessage("");
}

function openProjectEditorModal(mode, project) {
  resetProjectEditorForm();

  if (mode === "edit" && project) {
    document.getElementById("projectEditorMode").value = "edit";
    document.getElementById("projectEditorModalLabel").textContent = t("projects.editProject");
    document.getElementById("projectEditorCodeInput").value = project.projectCode || "";
    document.getElementById("projectEditorCodeInput").readOnly = true;
    document.getElementById("projectEditorNameInput").value = project.projectName || "";
    document.getElementById("projectEditorRemoveButton").classList.remove("d-none");
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
  return `${projectCode}_${filterPeriod}`;
}

function calculateDateRange(filterPeriod) {
  const now = new Date();
  const endDate = now.toISOString().split("T")[0];
  let startDate = "";

  switch (filterPeriod) {
    case "1M":
      startDate = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString().split("T")[0];
      break;
    case "6M":
      startDate = new Date(now.getFullYear(), now.getMonth() - 6, 1).toISOString().split("T")[0];
      break;
    case "1Y":
      startDate = new Date(now.getFullYear() - 1, now.getMonth(), now.getDate()).toISOString().split("T")[0];
      break;
    case "all":
    default:
      startDate = "";
      break;
  }

  return { startDate, endDate };
}

async function fetchProjects() {
  try {
    const response = await fetch(apiUrl + "projects");
    const projects = await parseResponse(response);
    projectsViewState.projects = Array.isArray(projects) ? projects : [];
    return projectsViewState.projects;
  } catch (error) {
    console.error("Error fetching projects:", error);
    projectsViewState.projects = [];
    return [];
  }
}

function buildProjectBootstrapUrl(filterPeriod, projectCode) {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  const params = new URLSearchParams();

  if (filterPeriod !== "all" && startDate && endDate) {
    params.set("startDate", startDate);
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
  let url = apiUrl + "stats/projects/" + projectCode;
  if (filterPeriod !== "all" && startDate && endDate) {
    url += `?startDate=${startDate}&endDate=${endDate}`;
  }
  return url;
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

  container.innerHTML = projectDetails.map(detail => `
    <article class="project-summary-card${currentProjectCode === detail.projectCode ? " is-active" : ""}" data-project-code="${escapeHtml(detail.projectCode)}">
      <div class="project-card-header">
        <div>
          <div class="project-card-title">${escapeHtml(detail.projectName)}</div>
          <div class="employee-card-note">${escapeHtml(detail.projectCode)}</div>
        </div>
        <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(detail.totalOvertime)))}</span>
      </div>
      <div class="project-card-meta">
        <span class="meta-pill">${escapeHtml(t("projects.entries", { count: detail.entryCount }))}</span>
        <span class="meta-pill">${escapeHtml(t("projects.average", { value: secondsToDurationLabel(timeStringToSeconds(detail.averageOvertime)) }))}</span>
      </div>
      <div class="employee-card-actions">
        <button type="button" class="btn btn-outline-secondary btn-sm project-edit-button" data-project-code="${escapeHtml(detail.projectCode)}">${escapeHtml(t("action.edit"))}</button>
      </div>
    </article>
  `).join("");
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
      ${entries.map(entry => `
        <div class="project-entry-row">
          <span class="project-entry-date">${escapeHtml(formatDateLabel(entry.date))}</span>
          <span class="project-entry-time mono">${escapeHtml(formatTimeString(entry.punchIn))} -> ${escapeHtml(entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress"))}</span>
          <span class="project-entry-overtime mono">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(entry.overtime)))}</span>
        </div>
      `).join("")}
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
  const average = detail.averageOvertime ? secondsToDurationLabel(timeStringToSeconds(detail.averageOvertime)) : "00h 00m";
  const total = detail.totalOvertime ? secondsToDurationLabel(timeStringToSeconds(detail.totalOvertime)) : "00h 00m";

  container.innerHTML = `
    <article class="project-detail-card">
      <div class="project-detail-title">
        <h4 class="m-0">${escapeHtml(detail.projectName || detail.projectCode)}</h4>
        <span class="inline-code-pill">${escapeHtml(detail.projectCode)}</span>
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
          <span class="metric-label">${escapeHtml(t("projects.averageLabel"))}</span>
          <strong class="metric-value mono">${escapeHtml(average)}</strong>
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
      }),
    });

    await parseResponse(response);
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

async function removeProject(project) {
  if (!project || !project.projectCode) {
    return;
  }

  const confirmed = window.confirm(t("projects.removeConfirm", { name: project.projectName, code: project.projectCode }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "projects/" + encodeURIComponent(project.projectCode), {
      method: "DELETE",
    });
    await parseResponse(response);
    if (currentProjectCode === project.projectCode) {
      currentProjectCode = null;
    }
    showToast(t("projects.projectRemoved"), "success");
    await refreshProjectsView();
  } catch (error) {
    console.error("Error removing project:", error);
    showToast(error.message || t("projects.removeError"), "error");
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

async function loadProjectTrendChart(filterPeriod = "all") {
  const { startDate, endDate } = calculateDateRange(filterPeriod);
  let url = apiUrl + "stats/projects/trends";
  if (filterPeriod !== "all" && startDate && endDate) {
    url += `?startDate=${startDate}&endDate=${endDate}`;
  }

  try {
    const response = await fetch(url);
    const trendData = await parseResponse(response);
    renderProjectMultiLineChart(trendData || {});
  } catch (error) {
    console.error("Error fetching project trend data:", error);
    const chartStage = document.querySelector("#projectChartContainer .chart-stage");
    if (chartStage) {
      chartStage.innerHTML = createEmptyState(t("projects.chartLoadError"));
    }
  }
}

document.getElementById("projectsSummaryContainer").addEventListener("click", event => {
  const editButton = event.target.closest(".project-edit-button");
  if (editButton) {
    event.stopPropagation();
    const project = getProjectByCode(editButton.getAttribute("data-project-code"));
    if (project) {
      openProjectEditorModal("edit", project);
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

document.getElementById("projectRangeSelect").addEventListener("change", event => {
  currentProjectFilter = event.target.value;
  refreshProjectsView();
});

document.getElementById("addProjectButton").addEventListener("click", () => {
  openProjectEditorModal("create");
});
document.getElementById("projectEditorRemoveButton").addEventListener("click", async () => {
  const project = getProjectByCode(document.getElementById("projectEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("projectEditorModal"));
  if (modal) {
    modal.hide();
  }
  await removeProject(project);
});
document.getElementById("projectEditorSaveButton").addEventListener("click", submitProjectEditor);
document.getElementById("projectEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  submitProjectEditor();
});
