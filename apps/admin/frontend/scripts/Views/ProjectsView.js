const projectDetailCache = {};
let currentProjectFilter = "6M";
let currentProjectCode = null;

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
    return await parseResponse(response);
  } catch (error) {
    console.error("Error fetching projects:", error);
    return [];
  }
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
    const response = await fetch(buildProjectStatsUrl(projectCode, filterPeriod));
    const data = await parseResponse(response);
    projectDetailCache[cacheKey] = data;
    renderProjectDetail(data);
  } catch (error) {
    console.error("Error loading project detail stats:", error);
    document.getElementById("projectDetailContainer").innerHTML = createEmptyState("Unable to load project statistics.");
  }
}

function loadProjectDetailStatsPromise(projectCode, filterPeriod = "all") {
  const cacheKey = getProjectDetailCacheKey(projectCode, filterPeriod);
  if (projectDetailCache[cacheKey]) {
    return Promise.resolve(projectDetailCache[cacheKey]);
  }

  return fetch(buildProjectStatsUrl(projectCode, filterPeriod))
    .then(parseResponse)
    .then(data => {
      projectDetailCache[cacheKey] = data;
      return data;
    })
    .catch(error => {
      console.error("Error loading project detail stats promise:", error);
      return null;
    });
}

async function loadAllProjectSummaryStats(filterPeriod = "all") {
  try {
    const projectsList = await fetchProjects();
    const details = await Promise.all(projectsList.map(async project => {
      const detail = await loadProjectDetailStatsPromise(project.projectCode, filterPeriod);
      if (detail) {
        detail.projectName = project.projectName;
      }
      return detail;
    }));

    const validDetails = details.filter(Boolean);
    if (!currentProjectCode && validDetails.length > 0) {
      currentProjectCode = validDetails[0].projectCode;
    }
    renderProjectSummaryCards(validDetails);

    if (currentProjectCode) {
      const activeDetail = validDetails.find(detail => detail.projectCode === currentProjectCode);
      if (activeDetail) {
        renderProjectDetail(activeDetail);
      } else if (validDetails[0]) {
        currentProjectCode = validDetails[0].projectCode;
        renderProjectDetail(validDetails[0]);
      }
    } else {
      document.getElementById("projectDetailContainer").innerHTML = createEmptyState("Choose a project to inspect its trend and employee breakdown.");
    }
  } catch (error) {
    console.error("Error loading all project summary stats:", error);
    document.getElementById("projectsSummaryContainer").innerHTML = createEmptyState("Unable to load projects.");
  }
}

async function refreshProjectsView() {
  clearProjectDetailCache();
  await loadAllProjectSummaryStats(currentProjectFilter);
  await loadProjectTrendChart(currentProjectFilter);
  if (currentProjectCode) {
    await loadProjectDetailStats(currentProjectCode, currentProjectFilter);
  }
}

function renderProjectSummaryCards(projectDetails) {
  const container = document.getElementById("projectsSummaryContainer");
  if (!projectDetails || projectDetails.length === 0) {
    container.innerHTML = createEmptyState("No project statistics available yet.");
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
        <span class="meta-pill">Entries ${escapeHtml(detail.entryCount)}</span>
        <span class="meta-pill">Average ${escapeHtml(secondsToDurationLabel(timeStringToSeconds(detail.averageOvertime)))}</span>
      </div>
    </article>
  `).join("");
}

function renderProjectEmployeeEntries(entries) {
  if (!entries || entries.length === 0) {
    return createEmptyState("No entries for this employee in the selected period.");
  }

  return `
    <table class="table table-sm align-middle">
      <thead>
        <tr>
          <th>Date</th>
          <th>Punch In</th>
          <th>Punch Out</th>
          <th>Overtime</th>
        </tr>
      </thead>
      <tbody>
        ${entries.map(entry => `
          <tr>
            <td>${escapeHtml(formatDateLabel(entry.date))}</td>
            <td>${escapeHtml(formatTimeString(entry.punchIn))}</td>
            <td>${escapeHtml(formatTimeString(entry.punchOut))}</td>
            <td>${escapeHtml(secondsToDurationLabel(timeStringToSeconds(entry.overtime)))}</td>
          </tr>
        `).join("")}
      </tbody>
    </table>
  `;
}

function renderProjectDetail(detail) {
  const container = document.getElementById("projectDetailContainer");
  if (!detail) {
    container.innerHTML = createEmptyState("Choose a project to inspect its detail.");
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
          <span class="metric-label">Total Overtime</span>
          <strong class="metric-value mono">${escapeHtml(total)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">Entries</span>
          <strong class="metric-value mono">${escapeHtml(detail.entryCount)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">Average</span>
          <strong class="metric-value mono">${escapeHtml(average)}</strong>
        </div>
        <div class="project-summary-item">
          <span class="metric-label">Contributors</span>
          <strong class="metric-value mono">${escapeHtml(touchedBy)}</strong>
        </div>
      </div>
      <div class="employee-breakdown">
        <h5>Employee Breakdown</h5>
        ${detail.breakdownByEmployee && detail.breakdownByEmployee.length > 0 ? `
          <div class="accordion" id="employeeAccordion">
            ${detail.breakdownByEmployee.map((employee, index) => {
              const collapseId = `projectEmployeeCollapse${index}`;
              return `
                <div class="accordion-item">
                  <h2 class="accordion-header" id="projectHeading${index}">
                    <button class="accordion-button collapsed" type="button" data-bs-toggle="collapse" data-bs-target="#${collapseId}" aria-expanded="false" aria-controls="${collapseId}">
                      <span>${escapeHtml(employee.employee)}</span>
                      <span class="ms-auto me-4 employee-card-note">${escapeHtml(secondsToDurationLabel(timeStringToSeconds(employee.overtime)))} across ${escapeHtml(employee.entryCount)} entries</span>
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
        ` : createEmptyState("No overtime entries recorded for this project.")}
      </div>
    </article>
  `;
}

function renderProjectMultiLineChart(trendData) {
  const ctx = document.getElementById("projectMultiLineChart").getContext("2d");
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
  }
}

document.getElementById("projectsSummaryContainer").addEventListener("click", event => {
  const projectCard = event.target.closest(".project-summary-card");
  if (!projectCard) {
    return;
  }

  const projectCode = projectCard.getAttribute("data-project-code");
  if (projectCode) {
    currentProjectCode = projectCode;
    renderProjectSummaryCards(Object.values(projectDetailCache).filter(Boolean));
    loadProjectDetailStats(projectCode, currentProjectFilter);
  }
});

document.getElementById("projectRangeSelect").addEventListener("change", event => {
  currentProjectFilter = event.target.value;
  refreshProjectsView();
});
