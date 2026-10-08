(function initializeBudgetBeta(global) {
  "use strict";

  const state = { host: null, payload: null, options: {}, tab: "annual", metric: "hours", demo: false, period: "", a: "", b: "", sort: "change", search: "" };
  const charts = new Map();
  let observer = null;
  const text = key => t(`budgetBeta.${key}`);
  const money = value => formatCurrencyCents(value, "CAD");
  const duration = hours => secondsToDurationLabel(Math.round(Number(hours || 0) * 3600));

  function valueOf(record, metric, component = "totalAmountCents") {
    if (!record) return 0;
    if (metric === "hours") return Number(record.totalSeconds != null ? record.totalSeconds : record.approvedSeconds || 0) / 3600;
    const monetary = record.monetary;
    if (!monetary || (Number(monetary.calculatedEntryCount || 0) === 0 && Number(monetary.unavailableEntryCount || 0) > 0)) return null;
    if (monetary[component] == null) return null;
    return Number(monetary[component]);
  }

  function formatValue(value, metric = state.metric) {
    if (value == null) return text("unavailable");
    return metric === "money" ? money(value) : duration(value);
  }

  function deltaLabel(a, b, metric = state.metric) {
    if (a == null || b == null) return text("unavailable");
    const delta = b - a;
    const prefix = delta > 0 ? "+" : delta < 0 ? "−" : "";
    const percent = a > 0 ? ` (${prefix}${Math.abs(delta / a * 100).toLocaleString(getCurrentLocale(), { maximumFractionDigits: 1 })} %)` : "";
    return `${prefix}${formatValue(Math.abs(delta), metric)}${percent}`;
  }

  function recordDelta(recordA, recordB) {
    if (state.metric === "money" && [recordA, recordB].some(record => Number(record && record.monetary && record.monetary.unavailableEntryCount || 0) > 0)) return text("partialChange");
    return deltaLabel(valueOf(recordA, state.metric), valueOf(recordB, state.metric));
  }

  function comparisonRows(periodA, periodB, metric, sort = "change", search = "") {
    const rows = new Map();
    [periodA, periodB].forEach((period, index) => {
      (period && period.projects || []).forEach(project => {
        const code = String(project.projectCode || "");
        if (!code) return;
        if (!rows.has(code)) rows.set(code, { code, name: String(project.projectName || code), a: 0, b: 0, projectA: null, projectB: null });
        const row = rows.get(code);
        row[index === 0 ? "a" : "b"] = valueOf(project, metric);
        row[index === 0 ? "projectA" : "projectB"] = project;
      });
    });
    const query = String(search || "").trim().toLocaleLowerCase();
    return Array.from(rows.values()).filter(row => {
      const active = [row.projectA, row.projectB].some(project => project && Number(project.totalSeconds || 0) > 0);
      return active && (!query || `${row.code} ${row.name}`.toLocaleLowerCase().includes(query));
    }).sort((left, right) => {
      if (sort === "name") return left.name.localeCompare(right.name, getCurrentLocale());
      const rank = row => sort === "amount" ? Number(row.b || 0) : row.a == null || row.b == null ? -1 : Math.abs(row.b - row.a);
      return rank(right) - rank(left) || left.code.localeCompare(right.code);
    });
  }

  function demoPayload() {
    // Deliberately synthetic chart values, unrelated to employee salaries.
    // This payload stays in browser memory and is never sent to an API.
    const seeds = [
      ["QMS-730", "Quality Review", 24, 118400], ["DAT-390", "Data Services", 18, 104600],
      ["NET-640", "Network Renewal", 34, 214200], ["CLT-120", "Client Rollout", 16, 91300],
      ["APP-220", "Portal Upgrade", 28, 165600], ["FIN-510", "Financial Reporting", 20, 123700],
      ["HR-180", "HR Systems", 12, 70800], ["INF-600", "Infrastructure", 30, 179400],
    ];
    const periods = Array.from({ length: 12 }, (_, index) => {
      const projects = seeds.map(([code, name, hours, cents], projectIndex) => {
        const factor = [0.8, 1.15, 1.35, 0.65, 1, 1.5][(index + projectIndex) % 6];
        const amount = Math.round(cents * factor);
        const cash = Math.round(amount * (projectIndex % 3 === 0 ? 0.6 : 0.85));
        return { projectCode: code, projectName: name, totalSeconds: Math.round(hours * factor * 4) * 900, approvedEntryCount: 6, monetary: { currency: "CAD", calculatedEntryCount: 6, unavailableEntryCount: 0, approvedEntryCount: 6, totalAmountCents: amount, cashAmountCents: cash, compensatoryLeaveValueCents: amount - cash } };
      });
      return {
        id: `P${index + 1}`, configured: true, startDate: `2026-${String(index + 1).padStart(2, "0")}-01`,
        endDate: `2026-${String(index + 1).padStart(2, "0")}-${new Date(2026, index + 1, 0).getDate()}`,
        approvedSeconds: projects.reduce((sum, project) => sum + project.totalSeconds, 0), approvedEntryCount: 48,
        projectsWithOvertimeCount: projects.length, projects,
        monetary: { currency: "CAD", calculatedEntryCount: 48, unavailableEntryCount: 0, approvedEntryCount: 48, totalAmountCents: projects.reduce((sum, project) => sum + project.monetary.totalAmountCents, 0), cashAmountCents: projects.reduce((sum, project) => sum + project.monetary.cashAmountCents, 0), compensatoryLeaveValueCents: projects.reduce((sum, project) => sum + project.monetary.compensatoryLeaveValueCents, 0) },
      };
    });
    return { cycleLabel: text("demo"), periods };
  }

  function payload() { return state.demo ? demoPayload() : state.payload; }
  function periods() { return (payload().periods || []).filter(period => period.configured); }
  function periodById(id) { return periods().find(period => period.id === id); }
  function range(period) { return period ? `${formatDateLabel(period.startDate)} – ${formatDateLabel(period.endDate)}` : ""; }

  function theme() {
    const style = global.getComputedStyle(state.host);
    const get = (key, fallback) => style.getPropertyValue(key).trim() || fallback;
    return { foreground: get("--label-primary", "#e5e7eb"), muted: get("--label-tertiary", "#9ca3af"), border: get("--separator", "#39404a"), surface: get("--surface", "#24262d"), accent: get("--accent-strong", "#67a6ff") };
  }

  function tooltipRecord(record) {
    const missing = Number(record && record.monetary && record.monetary.unavailableEntryCount || 0);
    return `${escapeHtml(t("projects.approvedHours"))}: <strong>${escapeHtml(formatValue(valueOf(record, "hours"), "hours"))}</strong><br>${escapeHtml(t("money.estimatedValue"))}: <strong>${escapeHtml(formatValue(valueOf(record, "money"), "money"))}</strong>${missing ? `<br>${escapeHtml(t("money.incompleteCoverage", { count: missing }))}` : ""}`;
  }

  function toolbox(colors) {
    return { right: 8, top: 0, iconStyle: { borderColor: colors.muted }, emphasis: { iconStyle: { borderColor: colors.accent } }, feature: {
      dataZoom: { title: { zoom: text("zoom"), back: text("resetZoom") }, yAxisIndex: "none" },
      restore: { title: text("resetZoom") },
      saveAsImage: { title: text("saveImage"), name: `SAPHIR-${state.demo ? "DEMO-" : ""}periods`, backgroundColor: colors.surface, pixelRatio: 2 },
    } };
  }

  function annualOption(data, metric, colors) {
    const allPeriods = data.periods || [];
    const colorA = colors.accent;
    const colorB = "#7a68d9";
    const components = metric === "money" ? ["cashAmountCents", "compensatoryLeaveValueCents"] : ["totalAmountCents"];
    return {
      backgroundColor: colors.surface, animationDuration: 240, textStyle: { color: colors.foreground, fontFamily: "inherit" },
      aria: { enabled: true },
      grid: { left: 76, right: 24, top: 82, bottom: 72 },
      toolbox: toolbox(colors),
      legend: { show: metric === "money", left: 12, top: 32, textStyle: { color: colors.foreground } },
      tooltip: { trigger: "axis", confine: true, backgroundColor: colors.surface, borderColor: colors.border, textStyle: { color: colors.foreground }, formatter: items => {
        const period = allPeriods[items[0] && items[0].dataIndex];
        return period ? `<strong>${escapeHtml(period.id)}</strong><br>${escapeHtml(range(period))}<br>${period.configured ? tooltipRecord(period) : escapeHtml(t("projects.budgetNotConfigured"))}` : "";
      } },
      xAxis: { type: "category", data: allPeriods.map(period => period.id), axisTick: { show: false }, axisLine: { lineStyle: { color: colors.border } }, axisLabel: { color: colors.muted, hideOverlap: true } },
      yAxis: { type: "value", name: metric === "money" ? "CAD" : text("hours"), nameTextStyle: { color: colors.muted }, axisLabel: { color: colors.muted, formatter: value => metric === "money" ? (value / 100).toLocaleString(getCurrentLocale(), { maximumFractionDigits: 0 }) : `${value} h` }, splitLine: { lineStyle: { color: colors.border, type: "dashed" } } },
      dataZoom: [{ type: "inside", xAxisIndex: 0, filterMode: "none" }, { type: "slider", xAxisIndex: 0, height: 22, bottom: 14, textStyle: { color: colors.muted }, borderColor: colors.border, brushSelect: false }],
      series: components.map((component, index) => ({
        name: metric === "hours" ? text("hours") : t(index === 0 ? "money.cash" : "money.compensatoryLeave"), type: "bar", stack: "value", barMaxWidth: 52,
        itemStyle: { color: index === 0 ? colorA : colorB, borderRadius: metric === "hours" || index === 1 ? [5, 5, 0, 0] : 0 },
        emphasis: { focus: "series" }, data: allPeriods.map(period => period.configured ? valueOf(period, metric, component) : null),
      })),
    };
  }

  function comparisonOption(rows, a, b, colors) {
    return {
      backgroundColor: colors.surface, animationDuration: 200, textStyle: { color: colors.foreground }, aria: { enabled: true },
      grid: { left: 112, right: 60, top: 52, bottom: 40 },
      legend: { data: [a.id, b.id], top: 0, left: 12, textStyle: { color: colors.foreground } },
      toolbox: { ...toolbox(colors), feature: { saveAsImage: toolbox(colors).feature.saveAsImage } },
      tooltip: { trigger: "axis", axisPointer: { type: "shadow" }, confine: true, backgroundColor: colors.surface, borderColor: colors.border, textStyle: { color: colors.foreground }, formatter: items => {
        const row = rows[items[0] && items[0].dataIndex];
        if (!row) return "";
        return `<strong>${escapeHtml(row.name)} · ${escapeHtml(row.code)}</strong><br>${escapeHtml(a.id)}: ${escapeHtml(formatValue(row.a))}<br>${escapeHtml(b.id)}: ${escapeHtml(formatValue(row.b))}<br>${escapeHtml(text("change"))}: <strong>${escapeHtml(recordDelta(row.projectA, row.projectB))}</strong>`;
      } },
      xAxis: { type: "value", splitNumber: 4, axisLabel: { color: colors.muted, hideOverlap: true, formatter: value => state.metric === "money" ? `${(value / 100).toLocaleString(getCurrentLocale(), { maximumFractionDigits: 0 })} $` : `${value} h` }, splitLine: { lineStyle: { color: colors.border, type: "dashed" } } },
      yAxis: { type: "category", inverse: true, data: rows.map(row => row.code), axisTick: { show: false }, axisLine: { show: false }, axisLabel: { color: colors.foreground } },
      dataZoom: rows.length > 10 ? [{ type: "slider", yAxisIndex: 0, right: 4, width: 16, startValue: 0, endValue: 9, zoomLock: true }, { type: "inside", yAxisIndex: 0, zoomLock: true, moveOnMouseWheel: true }] : [],
      series: [a, b].map((period, index) => ({ name: period.id, type: "bar", barMaxWidth: 16, emphasis: { focus: "series" }, itemStyle: { color: index === 0 ? "#8895a7" : colors.accent, borderRadius: [0, 3, 3, 0] }, data: rows.map(row => row[index === 0 ? "a" : "b"]) })),
    };
  }

  function dispose() {
    if (observer) observer.disconnect();
    observer = null;
    charts.forEach(chart => chart.dispose());
    charts.clear();
  }

  function createChart(id, option) {
    const target = state.host.querySelector(`#${id}`);
    if (!target || target.clientWidth === 0) return null;
    if (id !== "budgetBetaAnnualChart") {
      const rowCount = option.yAxis && option.yAxis.data ? option.yAxis.data.length : 0;
      target.style.height = `${Math.max(230, Math.min(state.host.clientWidth < 600 ? 400 : 520, rowCount * 56 + 110))}px`;
    }
    if (charts.has(id)) charts.get(id).dispose();
    const chart = global.echarts.init(target, null, { renderer: "canvas" });
    charts.set(id, chart);
    chart.setOption(option);
    if (!observer && typeof global.ResizeObserver === "function") {
      observer = new global.ResizeObserver(() => charts.forEach(instance => { if (!instance.isDisposed() && instance.getDom().clientWidth > 0) instance.resize(); }));
      observer.observe(state.host);
    }
    return chart;
  }

  function optionsMarkup(selected) {
    return periods().map(period => `<option value="${escapeHtml(period.id)}"${period.id === selected ? " selected" : ""}>${escapeHtml(`${period.id} · ${range(period)}`)}</option>`).join("");
  }

  function dataTable(rows, headings) {
    return `<details class="budget-beta-data"><summary>${escapeHtml(text("exactData"))}</summary><div class="budget-beta-table-wrap"><table><thead><tr>${headings.map(label => `<th scope="col">${escapeHtml(label)}</th>`).join("")}</tr></thead><tbody>${rows.map(row => `<tr>${row.map((cell, index) => index === 0 ? `<th scope="row">${escapeHtml(cell)}</th>` : `<td>${escapeHtml(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table></div></details>`;
  }

  function renderDrilldown() {
    const period = periodById(state.period);
    const host = state.host.querySelector("#budgetBetaDrilldown");
    if (!period || !host) return;
    const ranked = comparisonRows(null, period, state.metric, "amount");
    host.innerHTML = `<div class="budget-beta-panel-heading"><div><h3>${escapeHtml(text("projectBreakdown"))} · ${escapeHtml(period.id)}</h3><span>${escapeHtml(range(period))}</span></div></div>${ranked.length ? '<div id="budgetBetaDetailChart" class="budget-beta-chart budget-beta-chart-detail" role="img"></div>' : createEmptyState(t("projects.budgetNoActivity"))}${dataTable(ranked.map(row => [row.name, formatValue(row.b)]), [t("shared.project"), text(state.metric === "money" ? "amounts" : "hours")])}`;
    if (!ranked.length) return;
    const colors = theme();
    const option = comparisonOption(ranked, { id: text("reference") }, period, colors);
    option.legend.show = false;
    option.series = [option.series[1]];
    const chart = createChart("budgetBetaDetailChart", option);
    if (chart) chart.on("click", event => { if (ranked[event.dataIndex] && !state.demo && typeof state.options.openProject === "function") Promise.resolve(state.options.openProject(ranked[event.dataIndex].code, period)).catch(error => { console.error(error); showToast(t("projects.statsUnavailable"), "error"); }); });
  }

  function renderComparisonChart() {
    const a = periodById(state.a);
    const b = periodById(state.b);
    if (!a || !b) return;
    const rows = comparisonRows(a, b, state.metric, state.sort, state.search);
    const host = state.host.querySelector("#budgetBetaComparisonResult");
    const same = a.id === b.id;
    host.innerHTML = `${same ? `<p class="budget-beta-notice">${escapeHtml(text("samePeriod"))}</p>` : ""}<div class="budget-beta-summary"><span><small>${escapeHtml(a.id)}</small><strong>${escapeHtml(formatValue(valueOf(a, state.metric)))}</strong></span><span><small>${escapeHtml(b.id)}</small><strong>${escapeHtml(formatValue(valueOf(b, state.metric)))}</strong></span><span><small>${escapeHtml(text("change"))}</small><strong>${escapeHtml(recordDelta(a, b))}</strong></span></div>${rows.length ? '<div id="budgetBetaComparisonChart" class="budget-beta-chart" role="img"></div>' : createEmptyState(t("projects.noMatchingProjects"))}${dataTable(rows.map(row => [row.name, formatValue(row.a), formatValue(row.b), recordDelta(row.projectA, row.projectB)]), [t("shared.project"), a.id, b.id, text("change")])}`;
    if (!rows.length) return;
    const chart = createChart("budgetBetaComparisonChart", comparisonOption(rows, a, b, theme()));
    if (chart) chart.on("click", event => { if (rows[event.dataIndex] && !state.demo && typeof state.options.openProject === "function") Promise.resolve(state.options.openProject(rows[event.dataIndex].code, event.seriesIndex === 0 ? a : b)).catch(error => { console.error(error); showToast(t("projects.statsUnavailable"), "error"); }); });
  }

  function renderContent() {
    dispose();
    const configured = periods();
    const valid = id => configured.some(period => period.id === id);
    const defaults = getDefaultProjectBudgetPeriodIds(configured);
    if (!valid(state.a)) state.a = defaults[0] || "";
    if (!valid(state.b)) state.b = defaults[defaults.length - 1] || state.a;
    if (!valid(state.period)) state.period = state.b;
    const missing = configured.reduce((sum, period) => sum + Number(period.monetary && period.monetary.unavailableEntryCount || 0), 0);
    state.host.innerHTML = `
      <div class="budget-beta-toolbar">
        <div class="budget-beta-tabs" role="group" aria-label="${escapeHtml(text("analysis"))}">
          <button type="button" data-beta-tab="annual" aria-pressed="${state.tab === "annual"}" class="chip-button${state.tab === "annual" ? " active" : ""}">${escapeHtml(text("annual"))}</button>
          <button type="button" data-beta-tab="comparison" aria-pressed="${state.tab === "comparison"}" class="chip-button${state.tab === "comparison" ? " active" : ""}">${escapeHtml(text("compare"))}</button>
        </div>
        <label class="budget-beta-field"><span>${escapeHtml(text("measure"))}</span><select class="form-select form-select-sm" data-beta-metric><option value="hours"${state.metric === "hours" ? " selected" : ""}>${escapeHtml(text("hours"))}</option><option value="money"${state.metric === "money" ? " selected" : ""}>${escapeHtml(text("amounts"))}</option></select></label>
        <label class="budget-beta-demo-switch"><input type="checkbox" data-beta-demo${state.demo ? " checked" : ""}>${escapeHtml(text("demo"))}</label>
      </div>
      ${state.demo ? `<p class="budget-beta-notice" role="status"><i class="fa-solid fa-flask" aria-hidden="true"></i>${escapeHtml(text("demoNotice"))}</p>` : ""}
      ${state.metric === "money" ? `<p class="budget-beta-money-note">${escapeHtml(t("money.salaryOnlyEstimate"))}${missing ? ` · ${escapeHtml(t("money.incompleteCoverage", { count: missing }))}` : ""}</p>` : ""}
      ${configured.length === 0 ? createEmptyState(t("projects.budgetPeriodsEmpty")) : state.tab === "annual" ? `
        <section class="budget-beta-panel">
          <div class="budget-beta-panel-heading"><div><h3>${escapeHtml(text("annualTitle"))}</h3><span>${escapeHtml(text("annualHint"))}</span></div></div>
          <div id="budgetBetaAnnualChart" class="budget-beta-chart" role="img" aria-label="${escapeHtml(text("annualTitle"))}"></div>
          ${dataTable(configured.map(period => [period.id, range(period), formatValue(valueOf(period, state.metric))]), [text("period"), text("dates"), text(state.metric === "money" ? "amounts" : "hours")])}
        </section>
        <section class="budget-beta-panel"><label class="budget-beta-field budget-beta-period-picker"><span>${escapeHtml(text("detailPeriod"))}</span><select class="form-select form-select-sm" data-beta-period>${optionsMarkup(state.period)}</select></label><div id="budgetBetaDrilldown"></div></section>
      ` : `
        <section class="budget-beta-panel"><div class="budget-beta-comparison-controls">
          <label class="budget-beta-field"><span>${escapeHtml(text("periodA"))}</span><select class="form-select form-select-sm" data-beta-a>${optionsMarkup(state.a)}</select></label>
          <button type="button" class="btn btn-outline-secondary btn-sm" data-beta-swap aria-label="${escapeHtml(text("swap"))}" title="${escapeHtml(text("swap"))}"><i class="fa-solid fa-right-left" aria-hidden="true"></i></button>
          <label class="budget-beta-field"><span>${escapeHtml(text("periodB"))}</span><select class="form-select form-select-sm" data-beta-b>${optionsMarkup(state.b)}</select></label>
          <label class="budget-beta-field"><span>${escapeHtml(text("sort"))}</span><select class="form-select form-select-sm" data-beta-sort><option value="change"${state.sort === "change" ? " selected" : ""}>${escapeHtml(text("largestChange"))}</option><option value="amount"${state.sort === "amount" ? " selected" : ""}>${escapeHtml(text("largestB"))}</option><option value="name"${state.sort === "name" ? " selected" : ""}>${escapeHtml(text("name"))}</option></select></label>
        </div><input type="search" class="form-control budget-beta-search" data-beta-search value="${escapeHtml(state.search)}" placeholder="${escapeHtml(text("search"))}" aria-label="${escapeHtml(text("search"))}"><div id="budgetBetaComparisonResult"></div></section>
      `}
    `;
    if (!configured.length) return;
    if (state.tab === "annual") {
      const chart = createChart("budgetBetaAnnualChart", annualOption(payload(), state.metric, theme()));
      if (chart) chart.on("click", event => {
        const period = payload().periods[event.dataIndex];
        if (!period || !period.configured) return;
        state.period = period.id;
        state.host.querySelector("[data-beta-period]").value = state.period;
        renderDrilldown();
      });
      renderDrilldown();
    } else renderComparisonChart();
  }

  function render(host, serverPayload, options = {}) {
    if (state.host && state.host !== host) dispose();
    state.host = host;
    state.payload = serverPayload || { periods: [] };
    state.options = options;
    host.onclick = event => {
      const tab = event.target.closest("[data-beta-tab]");
      if (tab) { state.tab = tab.dataset.betaTab; renderContent(); }
      if (event.target.closest("[data-beta-swap]")) { [state.a, state.b] = [state.b, state.a]; renderContent(); }
    };
    host.onchange = event => {
      if (event.target.matches("[data-beta-metric]")) state.metric = event.target.value;
      else if (event.target.matches("[data-beta-demo]")) { state.demo = event.target.checked; state.period = ""; state.a = ""; state.b = ""; }
      else if (event.target.matches("[data-beta-period]")) { state.period = event.target.value; renderDrilldown(); return; }
      else if (event.target.matches("[data-beta-a]")) state.a = event.target.value;
      else if (event.target.matches("[data-beta-b]")) state.b = event.target.value;
      else if (event.target.matches("[data-beta-sort]")) state.sort = event.target.value;
      else return;
      renderContent();
    };
    host.oninput = event => { if (event.target.matches("[data-beta-search]")) { state.search = event.target.value; renderComparisonChart(); } };
    renderContent();
  }

  global.Saphir = global.Saphir || {};
  global.Saphir.budgetBeta = Object.freeze({ render, dispose, resize: () => charts.forEach(chart => chart.resize()), model: Object.freeze({ valueOf, comparisonRows, annualOption }) });
})(window);
