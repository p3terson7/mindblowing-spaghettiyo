const APP_LANGUAGE_KEY = "overtimeAppLanguage";
const APP_LANGUAGE_DEFAULT = "en";
const APP_LANGUAGE_FALLBACK = "en";
const APP_LANGUAGE_LOCALES = {
  en: "en-CA",
  fr: "fr-CA",
};

const APP_TRANSLATIONS = {
  en: {
    "app.title": "GÉEM Overtime Manager",
    "app.name": "GÉEM Overtime Manager",
    "brand.overtimeManager": "Overtime Manager",
    "brand.unifiedWorkspace": "Unified Overtime Workspace",

    "nav.workspace": "Workspace",
    "nav.myOvertime": "My Overtime",
    "nav.commandCenter": "Command Center",
    "nav.people": "People",
    "nav.review": "Review",
    "nav.projects": "Projects",

    "workspace.employee": "Employee Workspace",
    "workspace.admin": "Admin Workspace",
    "workspace.myOvertime": "My Overtime",
    "workspace.commandCenter": "Command Center",
    "workspace.people": "People",
    "workspace.review": "Review",
    "workspace.projects": "Projects",

    "status.connection": "Connection",
    "status.sync": "Sync",
    "status.notConfigured": "Not configured",
    "status.waitingForSignIn": "Waiting for sign-in",
    "status.liveRev": "Live | rev {version}",
    "status.updatedRev": "Updated | rev {version}",
    "status.syncPaused": "Sync paused",
    "status.sessionExpired": "Session expired",
    "status.passwordUpdateRequired": "Password update required",
    "status.signedOut": "Signed out",

    "session.notSignedIn": "Not signed in",
    "session.employeeCode": "EMP {code}",
    "session.role.admin": "ADMIN",
    "session.role.employee": "EMPLOYEE",

    "language.label": "Language",
    "language.english": "English",
    "language.french": "Français",

    "action.changePassword": "Change Password",
    "action.logOut": "Log Out",
    "action.apply": "Apply",
    "action.reset": "Reset",
    "action.refresh": "Refresh",
    "action.cancel": "Cancel",
    "action.confirm": "Confirm",
    "action.saveChanges": "Save Changes",
    "action.addEntry": "Add Entry",
    "action.updatePassword": "Update Password",
    "action.savePassword": "Save Password",
    "action.managePassword": "Manage Password",
    "action.approve": "Approve",
    "action.reject": "Reject",
    "action.openEmployee": "Open Employee",
    "action.saveNote": "Save Note",
    "action.delete": "Delete",
    "action.edit": "Edit",
    "action.remove": "Remove",
    "action.select": "Select",

    "shared.project": "Project",
    "shared.overtimeCode": "Overtime Code",
    "shared.noProject": "No project",
    "shared.uncoded": "Uncoded",
    "shared.system": "System",
    "shared.event": "Event",
    "shared.unknown": "Unknown",
    "shared.unknownDate": "Unknown date",
    "shared.unknownTime": "Unknown time",
    "shared.now": "Now",
    "shared.close": "Close",
    "shared.inProgress": "In progress",
    "shared.waitingForPunchOut": "Waiting for punch out",
    "shared.noMessage": "No message provided.",
    "shared.noManagerNote": "No manager note attached.",
    "shared.managerMessage": "Manager message",
    "shared.loadingEmployees": "Loading employees...",
    "shared.loadingProjects": "Loading projects...",
    "shared.loadingOvertimeCodes": "Loading overtime codes...",
    "shared.selectEmployee": "Select an employee",
    "shared.selectProject": "Select project",
    "shared.selectOvertimeCode": "Select overtime code",
    "shared.employeeAccount": "Employee account",
    "shared.passwordManagedByAdmin": "Password managed by admin",
    "shared.reviewRequired": "Review required",
    "shared.ready": "Ready",
    "shared.waiting": "Waiting",
    "shared.live": "Live",

    "shared.entry.one": "{count} entry",
    "shared.entry.other": "{count} entries",
    "shared.item.one": "{count} item",
    "shared.item.other": "{count} items",
    "shared.session.one": "{count} live session",
    "shared.session.other": "{count} live sessions",
    "shared.employee.one": "{count} employee",
    "shared.employee.other": "{count} employees",
    "shared.approval.one": "{count} approval",
    "shared.approval.other": "{count} approvals",

    "date.justNow": "Just now",
    "date.minutesAgo": "{count}m ago",
    "date.hoursAgo": "{count}h ago",
    "date.daysAgo": "{count}d ago",

    "status.approved": "Approved",
    "status.rejected": "Rejected",
    "status.pending": "Pending",
    "status.clockedIn": "Clocked in",
    "status.offClock": "Off the clock",
    "status.idle": "Idle",
    "status.needsAttention": "Needs attention",
    "status.awaitingApproval": "Awaiting approval",
    "status.readyForNext": "Ready for next overtime",
    "status.notCurrentlyClockedIn": "Not currently clocked in",
    "status.noHistory": "No overtime history yet",
    "status.readyToTrack": "Start overtime when you are ready to track extra hours.",

    "self.startOvertime": "Start Overtime",
    "self.endOvertime": "End Overtime",
    "self.thisMonth": "This Month",
    "self.approvedPendingCombined": "Approved and pending overtime combined",
    "self.pendingApprovals": "Pending Approvals",
    "self.entriesWaitingReview": "Entries waiting for manager review",
    "self.currentStatus": "Current Status",
    "self.timeline": "Activity",
    "self.recentActivity": "Recent Activity",
    "self.range.today": "Today",
    "self.range.week": "This Week",
    "self.range.month": "This Month",
    "self.range.all": "All",
    "self.range.custom": "Custom",
    "self.range.todayEmpty": "Today | 0",
    "self.selectionRequired": "Select a project and overtime code before starting overtime.",
    "self.startConfirm": "Start overtime at <strong>{time}</strong> for <strong>{project}</strong> with <strong>{code}</strong>?",
    "self.endConfirm": "Are you sure you want to <strong>end</strong> overtime at <strong>{time}</strong>?",
    "self.punchSuccess": "{action} successful at {time}.",
    "self.fetchError": "Error fetching entries: {message}",
    "self.actionError": "Error during {action}: {message}",
    "self.noEntries": "No entries.",
    "self.startedAt": "Started {date} | {time}",
    "self.openDuration": "{duration} open",
    "self.lastEntry": "Last entry {date} | {timeRange}",
    "self.hero.live": "Live",
    "self.hero.review": "Review",
    "self.hero.ready": "Ready",
    "self.hero.pending": "Pending",
    "self.hero.idle": "Idle",

    "dashboard.orgOvertime": "Org Overtime This Month",
    "dashboard.acrossEmployees": "Across all tracked employees",
    "dashboard.pendingApprovals": "Pending Approvals",
    "dashboard.waitingForAction": "Entries waiting for action",
    "dashboard.clockedInNow": "Clocked In Right Now",
    "dashboard.openSessions": "Open overtime sessions",
    "dashboard.trackedEmployees": "Tracked Employees",
    "dashboard.knownEmployees": "Known employee records",
    "dashboard.needsAttention": "Operations",
    "dashboard.actionQueues": "Action Queues",
    "dashboard.pendingQueueMetaWaiting": "Waiting for review",
    "dashboard.pendingQueueMetaEmpty": "Nothing waiting right now",
    "dashboard.activeQueueTitle": "Live Sessions",
    "dashboard.activeQueueMeta": "Live overtime sessions",
    "dashboard.activeQueueMetaEmpty": "No active overtime sessions",
    "dashboard.recentActivity": "Recent Activity",
    "dashboard.latestAudit": "Latest audit trail entries",
    "dashboard.inspector": "Inspector",
    "dashboard.timeline": "Timeline",
    "dashboard.employee": "Employee",
    "dashboard.sort": "Sort",
    "dashboard.newestFirst": "Newest first",
    "dashboard.noPending": "No pending approvals. The queue is clear.",
    "dashboard.noActive": "Nobody is currently clocked in for overtime.",
    "dashboard.noRecentHistory": "No recent history yet.",
    "dashboard.noEntriesFiltered": "No overtime entries found for the current filters.",
    "dashboard.noEmployeeSelected": "No employee selected.",
    "dashboard.timelineLoadError": "Unable to load the employee timeline.",
    "dashboard.loadError": "Unable to load dashboard.",
    "dashboard.selectEmployeeBeforeAdd": "Select an employee before adding an entry.",
    "dashboard.entryOptionsError": "Unable to load entry options.",
    "dashboard.deleteConfirm": "Delete this entry?",
    "dashboard.entryDeleted": "Entry deleted successfully.",
    "dashboard.entryUpdated": "Entry updated successfully.",
    "dashboard.entryAdded": "Entry added successfully.",
    "dashboard.entryDeleteError": "Error deleting entry: {message}",
    "dashboard.entryUpdateError": "Error updating entry: {message}",
    "dashboard.entryAddError": "Error adding entry: {message}",
    "dashboard.selectEmployeeAndDate": "Please select an employee and a date.",
    "dashboard.fillAllTimeFields": "Please fill in all hour and minute fields.",
    "dashboard.selectProject": "Please select a project.",
    "dashboard.selectOvertimeCode": "Please select an overtime code.",
    "dashboard.numericTimeValidation": "Hours and minutes must be numeric and up to 2 digits.",
    "dashboard.punchOutAfterPunchIn": "Punch Out must be after Punch In.",
    "dashboard.projectAndCodeRequired": "Project and overtime code are required.",
    "dashboard.noChanges": "No changes detected.",
    "dashboard.managerMessageSaved": "Manager note saved.",
    "dashboard.managerMessageError": "Unable to save manager note.",
    "dashboard.approvalError": "Error updating entry: {message}",
    "dashboard.genericApprovalError": "Error updating entry",
    "dashboard.jumpOpenEmployee": "Open Employee",
    "dashboard.addEntry": "Add Entry",
    "dashboard.started": "Started {date} | {time}",

    "employees.peopleAccess": "Employees",
    "employees.directory": "Employee Directory",
    "employees.search": "Search employees",
    "employees.searchPlaceholder": "Search by name or employee code",
    "employees.none": "No employees match the current search.",
    "employees.codeAndPasswordsRequired": "Employee code and both password fields are required.",
    "employees.passwordsDoNotMatch": "The new passwords do not match.",
    "employees.passwordUpdated": "Password updated successfully.",
    "employees.passwordUpdateError": "Unable to update employee password.",
    "employees.loadError": "Unable to load employees.",
    "employees.managePassword": "Manage Employee Password",
    "employees.passwordWillRevoke": "Existing sessions for this employee will be revoked after the reset.",
    "employees.requirePasswordChange": "Require a password change on next sign-in",
    "employees.setResetPassword": "Set / Reset Password",
    "employees.addEmployee": "Add Employee",
    "employees.editEmployee": "Edit Employee",
    "employees.employeeCode": "Employee Code",
    "employees.employeeName": "Employee Name",
    "employees.temporaryPassword": "Temporary Password",
    "employees.confirmTemporaryPassword": "Confirm Temporary Password",
    "employees.temporaryPasswordHint": "Leave the temporary password empty to use an auto-generated one.",
    "employees.passwordHintCreate": "Leave the password empty to use an auto-generated one.",
    "employees.passwordHintEdit": "Leave the password empty to keep the current one unchanged.",
    "employees.codeAndNameRequired": "Employee code and name are required.",
    "employees.entryCount": "{count} entries",
    "employees.employeeCreated": "Employee created successfully.",
    "employees.createdWithPassword": "{name} created. Temporary password: {password}",
    "employees.createError": "Unable to create employee.",
    "employees.employeeUpdated": "Employee updated successfully.",
    "employees.employeeUpdatedAndPassword": "Employee and password updated successfully.",
    "employees.updateError": "Unable to update employee.",
    "employees.removeConfirm": "Remove {name} ({code}) from active access?",
    "employees.employeeRemoved": "Employee removed successfully.",
    "employees.removeError": "Unable to remove employee.",

    "review.reviewFlow": "Approvals",
    "review.approvals": "Approvals",
    "review.loadError": "Unable to load approvals.",
    "review.pending": "Pending ({count})",
    "review.rejected": "Rejected ({count})",
    "review.approved": "Approved ({count})",
    "review.searchApprovals": "Filter approvals by employee or date",
    "review.nonePending": "No entries are waiting for approval.",
    "review.noneForState": "No entries found for this state.",

    "history.auditTrail": "History",
    "history.history": "History",
    "history.all": "All ({count})",
    "history.added": "Added ({count})",
    "history.updated": "Updated ({count})",
    "history.approvedRejected": "Approved / Rejected ({count})",
    "history.deleted": "Deleted ({count})",
    "history.search": "Filter audit history by employee, action, or message",
    "history.none": "No history entries match this filter.",
    "history.fetchError": "Error fetching history",
    "history.action.add": "Added",
    "history.action.update": "Updated",
    "history.action.approved": "Approved",
    "history.action.rejected": "Rejected",
    "history.action.delete": "Deleted",
    "history.action.event": "Event",
    "history.fragment.punchInFromTo": "Punch In from <strong>{from}</strong> to <strong>{to}</strong>.",
    "history.fragment.punchOutFromTo": "Punch Out from <strong>{from}</strong> to <strong>{to}</strong>.",
    "history.fragment.punchOutRecorded": "Punch Out recorded at <strong>{time}</strong>.",
    "history.fragment.projectCodeUpdated": "Project Code updated.",
    "history.fragment.overtimeCodeUpdated": "Overtime Code updated.",
    "history.message.addedEntry": "Added an entry on {date}, starting at <strong>{start}</strong> and finishing at <strong>{end}</strong> for project <strong>{projectCode}</strong> and overtime code <strong>{overtimeCode}</strong>.",
    "history.message.updatedEntry": "Updated an entry on {date}, {details}",
    "history.message.updatedEntrySimple": "Entry on {date} updated successfully.",
    "history.message.deletedEntry": "Deleted an entry on {date} starting at <strong>{time}</strong>.",
    "history.message.deletedEntryReason": "Deleted an entry on {date} starting at <strong>{time}</strong>. Reason: {reason}",
    "history.message.approvedEntry": "Approved an entry on {date} starting at <strong>{time}</strong>.",
    "history.message.rejectedEntry": "Rejected an entry on {date} starting at <strong>{time}</strong>.",
    "history.message.createdAccount": "Created a sign-in account and set a password for <strong>{name}</strong>.",
    "history.message.resetPassword": "Reset the password for <strong>{name}</strong>.",
    "history.message.resetPasswordRequireChange": "Reset the password for <strong>{name}</strong> and required a password change at next sign-in.",
    "history.message.employeeCreated": "Created an employee profile for <strong>{name}</strong> with code <strong>{code}</strong>.",
    "history.message.employeeUpdated": "Updated the employee profile for <strong>{name}</strong>.",
    "history.message.employeeRemoved": "Removed employee access for <strong>{name}</strong>.",
    "history.message.projectCreated": "Created a project named <strong>{name}</strong> with code <strong>{code}</strong>.",
    "history.message.projectUpdated": "Updated the project <strong>{code}</strong>.",
    "history.message.projectRemoved": "Removed the project <strong>{code}</strong>.",

    "projects.trends": "Trends",
    "projects.monthlyOvertime": "Monthly Overtime by Project",
    "projects.range": "Range",
    "projects.range.all": "All Time",
    "projects.range.1M": "Last 1 Month",
    "projects.range.6M": "Last 6 Months",
    "projects.range.1Y": "Last 1 Year",
    "projects.portfolio": "Projects",
    "projects.overview": "Project Overview",
    "projects.deepDive": "Details",
    "projects.detail": "Project Detail",
    "projects.statsUnavailable": "Unable to load project statistics.",
    "projects.selectToInspect": "Choose a project to inspect its trend and employee breakdown.",
    "projects.unableToLoad": "Unable to load projects.",
    "projects.noStats": "No project statistics available yet.",
    "projects.entries": "Entries {count}",
    "projects.average": "Average {value}",
    "projects.noEntriesForEmployee": "No entries for this employee in the selected period.",
    "projects.totalOvertime": "Total Overtime",
    "projects.overtimeLabel": "Overtime",
    "projects.timeRange": "Time Range",
    "projects.entriesLabel": "Entries",
    "projects.averageLabel": "Average",
    "projects.contributors": "Contributors",
    "projects.employeeBreakdown": "Employee Breakdown",
    "projects.noEntriesForProject": "No overtime entries recorded for this project.",
    "projects.acrossEntries": "{duration} across {count} entries",
    "projects.chartLibraryFailed": "Chart library failed to load.",
    "projects.chartLoadError": "Unable to load project trends.",
    "projects.addProject": "Add Project",
    "projects.editProject": "Edit Project",
    "projects.projectCode": "Project Code",
    "projects.projectName": "Project Name",
    "projects.codeAndNameRequired": "Project code and name are required.",
    "projects.projectCreated": "Project created successfully.",
    "projects.createError": "Unable to create project.",
    "projects.projectUpdated": "Project updated successfully.",
    "projects.updateError": "Unable to update project.",
    "projects.removeConfirm": "Remove project {name} ({code})?",
    "projects.projectRemoved": "Project removed successfully.",
    "projects.removeError": "Unable to remove project.",

    "auth.signIn": "Sign In",
    "auth.username": "Username or Employee Code",
    "auth.password": "Password",
    "auth.newPassword": "New Password",
    "auth.confirmNewPassword": "Confirm New Password",
    "auth.passwordPolicy": "Passwords must be at least 10 characters and include uppercase, lowercase, digit, and symbol characters.",
    "auth.connection": "Connection",
    "auth.apiUrl": "API URL",
    "auth.liveSync": "Live sync",
    "auth.roleAccess": "Role access",
    "auth.auditAnalytics": "Audit + analytics",
    "auth.usernamePasswordRequired": "Username and password are required.",
    "auth.passwordFieldsRequired": "Current password and both new password fields are required.",
    "auth.newPasswordsMismatch": "The new passwords do not match.",
    "auth.signInError": "Unable to sign in.",
    "auth.passwordUpdateError": "Unable to update password.",
    "auth.passwordUpdated": "Password updated successfully.",
    "auth.passwordChangeRequired": "Password change required before continuing.",
    "auth.authenticationIncomplete": "Authentication response was incomplete.",
    "auth.employeeCodeRequired": "Employee access requires an employee code.",
    "auth.sessionExpired": "Your session expired. Sign in again to continue.",
    "auth.signOutSuccess": "Signed out successfully.",
    "auth.signInToContinue": "Sign in to continue.",

    "modal.updateEntry": "Update Entry",
    "modal.addEntry": "Add Entry",
    "modal.date": "Date",
    "modal.punchIn": "Punch In",
    "modal.punchOut": "Punch Out",
    "modal.changePassword": "Change Password",
    "modal.currentPassword": "Current Password",
    "modal.employee": "Employee",
    "filters.month": "Month",
    "filters.year": "Year",
    "dashboard.selectEmployeeBeforeNote": "Select an employee before saving a note.",
    "error.requestFailedStatus": "Request failed with status {status}.",
  },
  fr: {
    "app.title": "Gestionnaire d'heures supp. GÉEM",
    "app.name": "Gestionnaire d'heures supp. GÉEM",
    "brand.overtimeManager": "Gestionnaire d'heures supp.",
    "brand.unifiedWorkspace": "Espace unifié des heures supp.",

    "nav.workspace": "Espace",
    "nav.myOvertime": "Mes heures supp.",
    "nav.commandCenter": "Centre de commande",
    "nav.people": "Personnel",
    "nav.review": "Révision",
    "nav.projects": "Projets",

    "workspace.employee": "Espace employé",
    "workspace.admin": "Espace admin",
    "workspace.myOvertime": "Mes heures supp.",
    "workspace.commandCenter": "Centre de commande",
    "workspace.people": "Personnel",
    "workspace.review": "Révision",
    "workspace.projects": "Projets",

    "status.connection": "Connexion",
    "status.sync": "Syncro",
    "status.notConfigured": "Non configuré",
    "status.waitingForSignIn": "En attente de connexion",
    "status.liveRev": "Actif | rév {version}",
    "status.updatedRev": "Mis à jour | rév {version}",
    "status.syncPaused": "Syncro en pause",
    "status.sessionExpired": "Session expirée",
    "status.passwordUpdateRequired": "Mise à jour du mot de passe requise",
    "status.signedOut": "Déconnecté",

    "session.notSignedIn": "Non connecté",
    "session.employeeCode": "EMP {code}",
    "session.role.admin": "ADMIN",
    "session.role.employee": "EMPLOYÉ",

    "language.label": "Langue",
    "language.english": "English",
    "language.french": "Français",

    "action.changePassword": "Mot de passe",
    "action.logOut": "Déconnexion",
    "action.apply": "Appliquer",
    "action.reset": "Réinitialiser",
    "action.refresh": "Actualiser",
    "action.cancel": "Annuler",
    "action.confirm": "Confirmer",
    "action.saveChanges": "Enregistrer",
    "action.addEntry": "Ajouter entrée",
    "action.updatePassword": "Mettre à jour",
    "action.savePassword": "Enregistrer",
    "action.managePassword": "Gérer le mot de passe",
    "action.approve": "Approuver",
    "action.reject": "Rejeter",
    "action.openEmployee": "Ouvrir employé",
    "action.saveNote": "Enregistrer note",
    "action.delete": "Supprimer",
    "action.edit": "Modifier",
    "action.remove": "Retirer",
    "action.select": "Choisir",

    "shared.project": "Projet",
    "shared.overtimeCode": "Code supp.",
    "shared.noProject": "Aucun projet",
    "shared.uncoded": "Non codé",
    "shared.system": "Système",
    "shared.event": "Événement",
    "shared.unknown": "Inconnu",
    "shared.unknownDate": "Date inconnue",
    "shared.unknownTime": "Heure inconnue",
    "shared.now": "Maintenant",
    "shared.close": "Fermer",
    "shared.inProgress": "En cours",
    "shared.waitingForPunchOut": "En attente du punch-out",
    "shared.noMessage": "Aucun message.",
    "shared.noManagerNote": "Aucune note du gestionnaire.",
    "shared.managerMessage": "Note gestionnaire",
    "shared.loadingEmployees": "Chargement des employés...",
    "shared.loadingProjects": "Chargement des projets...",
    "shared.loadingOvertimeCodes": "Chargement des codes...",
    "shared.selectEmployee": "Choisir un employé",
    "shared.selectProject": "Choisir projet",
    "shared.selectOvertimeCode": "Choisir code supp.",
    "shared.employeeAccount": "Compte employé",
    "shared.passwordManagedByAdmin": "Mot de passe géré par l'admin",
    "shared.reviewRequired": "Révision requise",
    "shared.ready": "Prêt",
    "shared.waiting": "En attente",
    "shared.live": "Actif",

    "shared.entry.one": "{count} entrée",
    "shared.entry.other": "{count} entrées",
    "shared.item.one": "{count} élément",
    "shared.item.other": "{count} éléments",
    "shared.session.one": "{count} session active",
    "shared.session.other": "{count} sessions actives",
    "shared.employee.one": "{count} employé",
    "shared.employee.other": "{count} employés",
    "shared.approval.one": "{count} approbation",
    "shared.approval.other": "{count} approbations",

    "date.justNow": "À l'instant",
    "date.minutesAgo": "il y a {count} min",
    "date.hoursAgo": "il y a {count} h",
    "date.daysAgo": "il y a {count} j",

    "status.approved": "Approuvé",
    "status.rejected": "Rejeté",
    "status.pending": "En attente",
    "status.clockedIn": "Pointé",
    "status.offClock": "Hors pointage",
    "status.idle": "Au repos",
    "status.needsAttention": "À revoir",
    "status.awaitingApproval": "En attente d'approbation",
    "status.readyForNext": "Prêt pour les prochaines heures supp.",
    "status.notCurrentlyClockedIn": "Aucun pointage en cours",
    "status.noHistory": "Aucun historique d'heures supp.",
    "status.readyToTrack": "Démarrez quand vous êtes prêt à comptabiliser des heures supplémentaires.",

    "self.startOvertime": "Débuter heures supp.",
    "self.endOvertime": "Terminer heures supp.",
    "self.thisMonth": "Ce mois-ci",
    "self.approvedPendingCombined": "Heures approuvées et en attente combinées",
    "self.pendingApprovals": "Approbations en attente",
    "self.entriesWaitingReview": "Entrées en attente de révision",
    "self.currentStatus": "Statut actuel",
    "self.timeline": "Activité",
    "self.recentActivity": "Activité récente",
    "self.range.today": "Aujourd'hui",
    "self.range.week": "Cette semaine",
    "self.range.month": "Ce mois-ci",
    "self.range.all": "Tout",
    "self.range.custom": "Personnalisé",
    "self.range.todayEmpty": "Aujourd'hui | 0",
    "self.selectionRequired": "Choisissez un projet et un code avant de débuter les heures supp.",
    "self.startConfirm": "Débuter les heures supp. à <strong>{time}</strong> pour <strong>{project}</strong> avec <strong>{code}</strong>?",
    "self.endConfirm": "Voulez-vous vraiment <strong>terminer</strong> les heures supp. à <strong>{time}</strong>?",
    "self.punchSuccess": "{action} réussi à {time}.",
    "self.fetchError": "Erreur lors du chargement des entrées : {message}",
    "self.actionError": "Erreur pendant {action} : {message}",
    "self.noEntries": "Aucune entrée.",
    "self.startedAt": "Débuté {date} | {time}",
    "self.openDuration": "{duration} en cours",
    "self.lastEntry": "Dernière entrée {date} | {timeRange}",
    "self.hero.live": "Actif",
    "self.hero.review": "Révision",
    "self.hero.ready": "Prêt",
    "self.hero.pending": "En attente",
    "self.hero.idle": "Au repos",

    "dashboard.orgOvertime": "Heures supp. org. ce mois-ci",
    "dashboard.acrossEmployees": "Tous employés suivis confondus",
    "dashboard.pendingApprovals": "Approbations en attente",
    "dashboard.waitingForAction": "Entrées à traiter",
    "dashboard.clockedInNow": "Pointés maintenant",
    "dashboard.openSessions": "Sessions ouvertes",
    "dashboard.trackedEmployees": "Employés suivis",
    "dashboard.knownEmployees": "Dossiers employés connus",
    "dashboard.needsAttention": "Opérations",
    "dashboard.actionQueues": "Files d'action",
    "dashboard.pendingQueueMetaWaiting": "En attente de révision",
    "dashboard.pendingQueueMetaEmpty": "Rien en attente pour l'instant",
    "dashboard.activeQueueTitle": "Sessions actives",
    "dashboard.activeQueueMeta": "Sessions en direct",
    "dashboard.activeQueueMetaEmpty": "Aucune session active",
    "dashboard.recentActivity": "Activité récente",
    "dashboard.latestAudit": "Dernières entrées d'audit",
    "dashboard.inspector": "Inspecteur",
    "dashboard.timeline": "Chronologie",
    "dashboard.employee": "Employé",
    "dashboard.sort": "Tri",
    "dashboard.newestFirst": "Plus récent d'abord",
    "dashboard.noPending": "Aucune approbation en attente.",
    "dashboard.noActive": "Personne n'est pointé en heures supp. en ce moment.",
    "dashboard.noRecentHistory": "Aucune activité récente.",
    "dashboard.noEntriesFiltered": "Aucune entrée d'heures supp. pour les filtres courants.",
    "dashboard.noEmployeeSelected": "Aucun employé sélectionné.",
    "dashboard.timelineLoadError": "Impossible de charger la chronologie de l'employé.",
    "dashboard.loadError": "Impossible de charger le tableau de bord.",
    "dashboard.selectEmployeeBeforeAdd": "Choisissez un employé avant d'ajouter une entrée.",
    "dashboard.entryOptionsError": "Impossible de charger les options de l'entrée.",
    "dashboard.deleteConfirm": "Supprimer cette entrée?",
    "dashboard.entryDeleted": "Entrée supprimée.",
    "dashboard.entryUpdated": "Entrée mise à jour.",
    "dashboard.entryAdded": "Entrée ajoutée.",
    "dashboard.entryDeleteError": "Erreur lors de la suppression : {message}",
    "dashboard.entryUpdateError": "Erreur lors de la mise à jour : {message}",
    "dashboard.entryAddError": "Erreur lors de l'ajout : {message}",
    "dashboard.selectEmployeeAndDate": "Choisissez un employé et une date.",
    "dashboard.fillAllTimeFields": "Remplissez tous les champs d'heure et de minute.",
    "dashboard.selectProject": "Choisissez un projet.",
    "dashboard.selectOvertimeCode": "Choisissez un code d'heures supp.",
    "dashboard.numericTimeValidation": "Les heures et minutes doivent être numériques et sur 2 chiffres maximum.",
    "dashboard.punchOutAfterPunchIn": "Le punch-out doit être après le punch-in.",
    "dashboard.projectAndCodeRequired": "Le projet et le code d'heures supp. sont requis.",
    "dashboard.noChanges": "Aucun changement détecté.",
    "dashboard.managerMessageSaved": "Note gestionnaire enregistrée.",
    "dashboard.managerMessageError": "Impossible d'enregistrer la note gestionnaire.",
    "dashboard.approvalError": "Erreur lors de la mise à jour : {message}",
    "dashboard.genericApprovalError": "Erreur lors de la mise à jour",
    "dashboard.jumpOpenEmployee": "Ouvrir employé",
    "dashboard.addEntry": "Ajouter entrée",
    "dashboard.started": "Débuté {date} | {time}",

    "employees.peopleAccess": "Employés",
    "employees.directory": "Répertoire employés",
    "employees.search": "Rechercher employés",
    "employees.searchPlaceholder": "Rechercher par nom ou code employé",
    "employees.none": "Aucun employé ne correspond à la recherche.",
    "employees.codeAndPasswordsRequired": "Le code employé et les deux champs de mot de passe sont requis.",
    "employees.passwordsDoNotMatch": "Les nouveaux mots de passe ne correspondent pas.",
    "employees.passwordUpdated": "Mot de passe mis à jour.",
    "employees.passwordUpdateError": "Impossible de mettre à jour le mot de passe de l'employé.",
    "employees.loadError": "Impossible de charger les employés.",
    "employees.managePassword": "Gérer le mot de passe employé",
    "employees.passwordWillRevoke": "Les sessions existantes pour cet employé seront révoquées après la réinitialisation.",
    "employees.requirePasswordChange": "Forcer un changement de mot de passe à la prochaine connexion",
    "employees.setResetPassword": "Définir / réinit. mot de passe",
    "employees.addEmployee": "Ajouter employé",
    "employees.editEmployee": "Modifier employé",
    "employees.employeeCode": "Code employé",
    "employees.employeeName": "Nom de l'employé",
    "employees.temporaryPassword": "Mot de passe temporaire",
    "employees.confirmTemporaryPassword": "Confirmer le mot de passe temporaire",
    "employees.temporaryPasswordHint": "Laissez vide pour utiliser un mot de passe généré automatiquement.",
    "employees.passwordHintCreate": "Laissez le mot de passe vide pour en générer un automatiquement.",
    "employees.passwordHintEdit": "Laissez le mot de passe vide pour conserver le mot de passe actuel.",
    "employees.codeAndNameRequired": "Le code employé et le nom sont requis.",
    "employees.entryCount": "{count} entrées",
    "employees.employeeCreated": "Employé créé avec succès.",
    "employees.createdWithPassword": "{name} créé. Mot de passe temporaire : {password}",
    "employees.createError": "Impossible de créer l'employé.",
    "employees.employeeUpdated": "Employé mis à jour avec succès.",
    "employees.employeeUpdatedAndPassword": "Employé et mot de passe mis à jour avec succès.",
    "employees.updateError": "Impossible de mettre à jour l'employé.",
    "employees.removeConfirm": "Retirer {name} ({code}) de l'accès actif?",
    "employees.employeeRemoved": "Employé retiré avec succès.",
    "employees.removeError": "Impossible de retirer l'employé.",

    "review.reviewFlow": "Approbations",
    "review.approvals": "Approbations",
    "review.loadError": "Impossible de charger les approbations.",
    "review.pending": "En attente ({count})",
    "review.rejected": "Rejeté ({count})",
    "review.approved": "Approuvé ({count})",
    "review.searchApprovals": "Filtrer par employé ou date",
    "review.nonePending": "Aucune entrée en attente d'approbation.",
    "review.noneForState": "Aucune entrée pour cet état.",

    "history.auditTrail": "Historique",
    "history.history": "Historique",
    "history.all": "Tout ({count})",
    "history.added": "Ajoutées ({count})",
    "history.updated": "Modifiées ({count})",
    "history.approvedRejected": "Approuvées / rejetées ({count})",
    "history.deleted": "Supprimées ({count})",
    "history.search": "Filtrer par employé, action ou message",
    "history.none": "Aucune entrée d'historique pour ce filtre.",
    "history.fetchError": "Erreur lors du chargement de l'historique",
    "history.action.add": "Ajoutée",
    "history.action.update": "Modifiée",
    "history.action.approved": "Approuvée",
    "history.action.rejected": "Rejetée",
    "history.action.delete": "Supprimée",
    "history.action.event": "Événement",
    "history.fragment.punchInFromTo": "Punch In de <strong>{from}</strong> à <strong>{to}</strong>.",
    "history.fragment.punchOutFromTo": "Punch Out de <strong>{from}</strong> à <strong>{to}</strong>.",
    "history.fragment.punchOutRecorded": "Punch Out saisi à <strong>{time}</strong>.",
    "history.fragment.projectCodeUpdated": "Code projet mis à jour.",
    "history.fragment.overtimeCodeUpdated": "Code d'heures supp. mis à jour.",
    "history.message.addedEntry": "Entrée ajoutée le {date}, de <strong>{start}</strong> à <strong>{end}</strong> pour le projet <strong>{projectCode}</strong> et le code d'heures supp. <strong>{overtimeCode}</strong>.",
    "history.message.updatedEntry": "Entrée modifiée le {date}, {details}",
    "history.message.updatedEntrySimple": "Entrée du {date} mise à jour avec succès.",
    "history.message.deletedEntry": "Entrée supprimée le {date} débutant à <strong>{time}</strong>.",
    "history.message.deletedEntryReason": "Entrée supprimée le {date} débutant à <strong>{time}</strong>. Raison : {reason}",
    "history.message.approvedEntry": "Entrée approuvée le {date} débutant à <strong>{time}</strong>.",
    "history.message.rejectedEntry": "Entrée rejetée le {date} débutant à <strong>{time}</strong>.",
    "history.message.createdAccount": "Compte créé et mot de passe défini pour <strong>{name}</strong>.",
    "history.message.resetPassword": "Mot de passe réinitialisé pour <strong>{name}</strong>.",
    "history.message.resetPasswordRequireChange": "Mot de passe réinitialisé pour <strong>{name}</strong> avec changement requis à la prochaine connexion.",
    "history.message.employeeCreated": "Profil employé créé pour <strong>{name}</strong> avec le code <strong>{code}</strong>.",
    "history.message.employeeUpdated": "Profil employé mis à jour pour <strong>{name}</strong>.",
    "history.message.employeeRemoved": "Accès employé retiré pour <strong>{name}</strong>.",
    "history.message.projectCreated": "Projet créé : <strong>{name}</strong> avec le code <strong>{code}</strong>.",
    "history.message.projectUpdated": "Projet <strong>{code}</strong> mis à jour.",
    "history.message.projectRemoved": "Projet <strong>{code}</strong> retiré.",

    "projects.trends": "Tendances",
    "projects.monthlyOvertime": "Heures supp. mensuelles par projet",
    "projects.range": "Période",
    "projects.range.all": "Tout",
    "projects.range.1M": "1 mois",
    "projects.range.6M": "6 mois",
    "projects.range.1Y": "1 an",
    "projects.portfolio": "Projets",
    "projects.overview": "Vue projets",
    "projects.deepDive": "Détails",
    "projects.detail": "Détail projet",
    "projects.statsUnavailable": "Impossible de charger les statistiques du projet.",
    "projects.selectToInspect": "Choisissez un projet pour voir sa tendance et sa répartition par employé.",
    "projects.unableToLoad": "Impossible de charger les projets.",
    "projects.noStats": "Aucune statistique de projet disponible.",
    "projects.entries": "Entrées {count}",
    "projects.average": "Moyenne {value}",
    "projects.noEntriesForEmployee": "Aucune entrée pour cet employé dans la période choisie.",
    "projects.totalOvertime": "Total heures supp.",
    "projects.overtimeLabel": "Heures supp.",
    "projects.timeRange": "Plage horaire",
    "projects.entriesLabel": "Entrées",
    "projects.averageLabel": "Moyenne",
    "projects.contributors": "Contributeurs",
    "projects.employeeBreakdown": "Répartition par employé",
    "projects.noEntriesForProject": "Aucune entrée d'heures supp. pour ce projet.",
    "projects.acrossEntries": "{duration} sur {count} entrées",
    "projects.chartLibraryFailed": "La librairie de graphiques n'a pas chargé.",
    "projects.chartLoadError": "Impossible de charger les tendances projets.",
    "projects.addProject": "Ajouter projet",
    "projects.editProject": "Modifier projet",
    "projects.projectCode": "Code projet",
    "projects.projectName": "Nom du projet",
    "projects.codeAndNameRequired": "Le code projet et le nom sont requis.",
    "projects.projectCreated": "Projet créé avec succès.",
    "projects.createError": "Impossible de créer le projet.",
    "projects.projectUpdated": "Projet mis à jour avec succès.",
    "projects.updateError": "Impossible de mettre à jour le projet.",
    "projects.removeConfirm": "Retirer le projet {name} ({code})?",
    "projects.projectRemoved": "Projet retiré avec succès.",
    "projects.removeError": "Impossible de retirer le projet.",

    "auth.signIn": "Connexion",
    "auth.username": "Utilisateur ou code employé",
    "auth.password": "Mot de passe",
    "auth.newPassword": "Nouveau mot de passe",
    "auth.confirmNewPassword": "Confirmer le nouveau mot de passe",
    "auth.passwordPolicy": "Le mot de passe doit contenir au moins 10 caractères, avec majuscule, minuscule, chiffre et symbole.",
    "auth.connection": "Serveur",
    "auth.apiUrl": "URL API",
    "auth.liveSync": "Syncro en direct",
    "auth.roleAccess": "Accès par rôle",
    "auth.auditAnalytics": "Audit + analytique",
    "auth.usernamePasswordRequired": "L'utilisateur et le mot de passe sont requis.",
    "auth.passwordFieldsRequired": "Le mot de passe actuel et les deux nouveaux champs sont requis.",
    "auth.newPasswordsMismatch": "Les nouveaux mots de passe ne correspondent pas.",
    "auth.signInError": "Impossible de se connecter.",
    "auth.passwordUpdateError": "Impossible de mettre à jour le mot de passe.",
    "auth.passwordUpdated": "Mot de passe mis à jour.",
    "auth.passwordChangeRequired": "Changement de mot de passe requis avant de continuer.",
    "auth.authenticationIncomplete": "La réponse d'authentification est incomplète.",
    "auth.employeeCodeRequired": "L'accès employé exige un code employé.",
    "auth.sessionExpired": "Votre session a expiré. Reconnectez-vous pour continuer.",
    "auth.signOutSuccess": "Déconnexion réussie.",
    "auth.signInToContinue": "Connectez-vous pour continuer.",

    "modal.updateEntry": "Modifier l'entrée",
    "modal.addEntry": "Ajouter une entrée",
    "modal.date": "Date",
    "modal.punchIn": "Punch-in",
    "modal.punchOut": "Punch-out",
    "modal.changePassword": "Changer le mot de passe",
    "modal.currentPassword": "Mot de passe actuel",
    "modal.employee": "Employé",
    "filters.month": "Mois",
    "filters.year": "Année",
    "dashboard.selectEmployeeBeforeNote": "Choisissez un employé avant d'enregistrer une note.",
    "error.requestFailedStatus": "La requête a échoué avec le statut {status}.",
  },
};

const appI18nState = {
  language: null,
  bound: false,
};

function resolveLanguageCandidate(language) {
  const normalized = String(language || "").trim().toLowerCase();
  if (normalized.startsWith("fr")) {
    return "fr";
  }
  if (normalized.startsWith("en")) {
    return "en";
  }
  return APP_LANGUAGE_DEFAULT;
}

function getStoredLanguage() {
  const storedValue = localStorage.getItem(APP_LANGUAGE_KEY);
  if (storedValue) {
    return resolveLanguageCandidate(storedValue);
  }

  const browserLanguage = navigator.language || navigator.userLanguage || APP_LANGUAGE_DEFAULT;
  return resolveLanguageCandidate(browserLanguage);
}

function getAppLanguage() {
  if (!appI18nState.language) {
    appI18nState.language = getStoredLanguage();
  }
  return appI18nState.language;
}

function getDictionary(language) {
  return APP_TRANSLATIONS[resolveLanguageCandidate(language)] || APP_TRANSLATIONS[APP_LANGUAGE_FALLBACK];
}

function interpolateTranslation(template, params) {
  return String(template).replace(/\{(\w+)\}/g, (match, key) => {
    const value = params && Object.prototype.hasOwnProperty.call(params, key) ? params[key] : match;
    return String(value);
  });
}

function t(key, params) {
  const activeDictionary = getDictionary(getAppLanguage());
  const fallbackDictionary = getDictionary(APP_LANGUAGE_FALLBACK);
  const template = Object.prototype.hasOwnProperty.call(activeDictionary, key)
    ? activeDictionary[key]
    : Object.prototype.hasOwnProperty.call(fallbackDictionary, key)
      ? fallbackDictionary[key]
      : key;

  return interpolateTranslation(template, params || {});
}

function tn(baseKey, count, params) {
  const suffix = Number(count) === 1 ? "one" : "other";
  return t(`${baseKey}.${suffix}`, { ...(params || {}), count });
}

function getI18nLocale() {
  return APP_LANGUAGE_LOCALES[getAppLanguage()] || APP_LANGUAGE_LOCALES[APP_LANGUAGE_FALLBACK];
}

function syncLanguageControls() {
  const currentLanguage = getAppLanguage();
  document.querySelectorAll("[data-language-select]").forEach(select => {
    if (select.value !== currentLanguage) {
      select.value = currentLanguage;
    }
  });
}

function applyTranslations(root) {
  const scope = root || document;
  scope.querySelectorAll("[data-i18n]").forEach(element => {
    element.textContent = t(element.getAttribute("data-i18n"));
  });

  scope.querySelectorAll("[data-i18n-html]").forEach(element => {
    element.innerHTML = t(element.getAttribute("data-i18n-html"));
  });

  scope.querySelectorAll("[data-i18n-placeholder]").forEach(element => {
    element.setAttribute("placeholder", t(element.getAttribute("data-i18n-placeholder")));
  });

  scope.querySelectorAll("[data-i18n-title]").forEach(element => {
    element.setAttribute("title", t(element.getAttribute("data-i18n-title")));
  });

  scope.querySelectorAll("[data-i18n-aria-label]").forEach(element => {
    element.setAttribute("aria-label", t(element.getAttribute("data-i18n-aria-label")));
  });

  document.documentElement.lang = getAppLanguage();
  document.title = t("app.title");
  syncLanguageControls();
}

function bindLanguageControls() {
  if (appI18nState.bound) {
    return;
  }

  document.addEventListener("change", event => {
    const target = event.target;
    if (!target || !target.matches("[data-language-select]")) {
      return;
    }
    setAppLanguage(target.value);
  });

  appI18nState.bound = true;
}

function setAppLanguage(language, options) {
  const resolvedLanguage = resolveLanguageCandidate(language);
  const nextOptions = options || {};
  const currentLanguage = getAppLanguage();
  const shouldRefresh = nextOptions.refresh !== false;

  appI18nState.language = resolvedLanguage;
  localStorage.setItem(APP_LANGUAGE_KEY, resolvedLanguage);
  applyTranslations();

  if (currentLanguage !== resolvedLanguage) {
    window.dispatchEvent(new CustomEvent("app:language-changed", {
      detail: {
        language: resolvedLanguage,
        refresh: shouldRefresh,
      },
    }));
  }
}

function translateStatus(status) {
  const normalized = String(status || "pending").trim().toLowerCase();
  if (!normalized) {
    return t("status.pending");
  }
  return t(`status.${normalized}`);
}

function translateHistoryAction(action) {
  const normalized = String(action || "event").trim().toLowerCase();
  return t(`history.action.${normalized}`);
}

window.t = t;
window.tn = tn;
window.getAppLanguage = getAppLanguage;
window.setAppLanguage = setAppLanguage;
window.getI18nLocale = getI18nLocale;
window.translateStatus = translateStatus;
window.translateHistoryAction = translateHistoryAction;
window.applyTranslations = applyTranslations;

window.addEventListener("DOMContentLoaded", () => {
  appI18nState.language = getStoredLanguage();
  bindLanguageControls();
  applyTranslations();
});
