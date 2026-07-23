const NAV_VIEW_MAP = {
  navSelf: "selfView",
  navDashboard: "dashboardView",
  navEmployees: "employeesView",
  navAdmin: "adminView",
  navProjects: "projectsView",
};

const VIEW_METADATA = {
  selfView: {
    kickerKey: "workspace.employee",
    titleKey: "workspace.myOvertime",
    subtitle: "",
  },
  dashboardView: {
    kickerKey: "workspace.admin",
    titleKey: "workspace.commandCenter",
    subtitle: "",
  },
  employeesView: {
    kickerKey: "workspace.admin",
    titleKey: "workspace.people",
    subtitle: "",
  },
  adminView: {
    kickerKey: "workspace.admin",
    titleKey: "workspace.review",
    subtitle: "",
  },
  projectsView: {
    kickerKey: "workspace.admin",
    titleKey: "workspace.projects",
    subtitle: "",
  },
};

function getAllowedViewIds() {
  if (Array.isArray(window.allowedViewIds) && window.allowedViewIds.length > 0) {
    return window.allowedViewIds.slice();
  }

  return Object.values(NAV_VIEW_MAP);
}

function resolveAccessibleView(viewId) {
  const allowedViewIds = getAllowedViewIds();
  if (allowedViewIds.indexOf(viewId) >= 0) {
    return viewId;
  }

  return allowedViewIds.length > 0 ? allowedViewIds[0] : "dashboardView";
}

function updateWorkspaceHeading(viewId) {
  const metadata = VIEW_METADATA[viewId] || VIEW_METADATA.dashboardView;
  const kicker = document.getElementById("workspaceKicker");
  const title = document.getElementById("workspaceTitle");
  const subtitle = document.getElementById("workspaceSubtitle");

  if (kicker) {
    kicker.textContent = t(metadata.kickerKey);
  }
  if (title) {
    title.textContent = t(metadata.titleKey);
  }
  if (subtitle) {
    subtitle.textContent = metadata.subtitle;
    subtitle.classList.toggle("d-none", !metadata.subtitle);
  }
}

function showView(viewId) {
  const resolvedViewId = resolveAccessibleView(viewId);

  document.querySelectorAll(".view").forEach(view => view.classList.remove("active"));
  const targetView = document.getElementById(resolvedViewId);
  if (targetView) {
    targetView.classList.add("active");
  }

  document.querySelectorAll(".app-nav-link").forEach(link => link.classList.remove("active"));
  Object.keys(NAV_VIEW_MAP).forEach(navId => {
    if (NAV_VIEW_MAP[navId] === resolvedViewId) {
      const navLink = document.getElementById(navId);
      if (navLink) {
        navLink.classList.add("active");
      }
    }
  });

  localStorage.setItem("activeView", resolvedViewId);
  updateWorkspaceHeading(resolvedViewId);
  return resolvedViewId;
}

function bindNavigation(navId) {
  const navLink = document.getElementById(navId);
  if (!navLink) {
    return;
  }

  navLink.addEventListener("click", event => {
    event.preventDefault();
    if (navLink.getAttribute("aria-disabled") === "true") {
      return;
    }
    const viewId = NAV_VIEW_MAP[navId];
    runButtonAction(navLink, async () => {
      showView(viewId);
      if (typeof window.refreshAppViewById === "function") {
        await window.refreshAppViewById(viewId);
      } else if (typeof window.refreshAdminViewById === "function") {
        await window.refreshAdminViewById(viewId);
      }
    }, {
      key: "view-navigation",
      disableWhileRunning: () => document.querySelectorAll(".app-nav-link"),
    }).catch(error => {
      console.error(`Unable to open ${viewId}:`, error);
    });
  });
}

Object.keys(NAV_VIEW_MAP).forEach(bindNavigation);
window.updateWorkspaceHeading = updateWorkspaceHeading;

window.addEventListener("load", () => {
  const savedView = localStorage.getItem("activeView") || "dashboardView";
  showView(savedView);
});
