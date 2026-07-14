function Resolve-AdminTopLevelRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Method -eq "GET" -and
        ($Path -eq "/" -or $Path -eq "/index.html" -or $Path -match "^/assets/" -or $Path -match "^/scripts/")) {
        return "routes/frontend.routes.ps1"
    }

    if ($Path -match "^/auth(/|$)") { return "routes/auth.routes.ps1" }
    if ($Path -eq "/health" -or $Path -match "^/sync(/|$)") { return "routes/sync.routes.ps1" }
    if ($Path -match "^/seed(/|$)") { return "routes/seed.routes.ps1" }
    if ($Path -match "^/self(/|$)") { return "routes/self.routes.ps1" }
    if ($Path -match "^/history(/|$)") { return "routes/history.routes.ps1" }
    if ($Path -match "^/(dashboard|approvals|review)(/|$)") { return "routes/dashboard.routes.ps1" }
    if ($Path -match "^/employees?(/|$)") { return "routes/employee.routes.ps1" }
    if ($Path -match "^/projects(/|$)") { return "routes/project.routes.ps1" }
    if ($Path -match "^/stats(/|$)") { return "routes/project-stats.routes.ps1" }

    return ""
}

function Resolve-EmployeeRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Method -eq "GET" -and ($Path -eq "/employees" -or $Path -eq "/employees/bootstrap")) {
        return "routes/employee/list.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -eq "/employees") {
        return "routes/employee/create-record.routes.ps1"
    }
    if ($Method -eq "PUT" -and $Path -match "^/employees/\d+$") {
        return "routes/employee/update-record.routes.ps1"
    }
    if ($Method -eq "DELETE" -and $Path -match "^/employees/\d+$") {
        return "routes/employee/delete-record.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -match "^/employees/\d+/restore$") {
        return "routes/employee/restore-record.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -match "^/employee/password/\d+$") {
        return "routes/employee/password.routes.ps1"
    }
    if (($Method -eq "GET" -and $Path -match "^/employee/\d+$") -or
        ($Method -eq "POST" -and $Path -match "^/employee/\d+/gc179-open$")) {
        return "routes/employee/get.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -match "^/employee/add/\d+$") {
        return "routes/employee/add.routes.ps1"
    }
    if ($Method -eq "POST" -and ($Path -eq "/employee/gc179-import/preview" -or $Path -eq "/employee/gc179-import/commit" -or $Path -eq "/employee/gc179-import/undo")) {
        return "routes/employee/gc179-import.routes.ps1"
    }
    if ($Method -eq "PUT" -and $Path -match "^/employee/\d+$") {
        return "routes/employee/update.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -eq "/employee/approval/batch") {
        return "routes/employee/batch-approval.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -match "^/employee/approval/\d+$") {
        return "routes/employee/approval.routes.ps1"
    }
    if ($Method -eq "PUT" -and $Path -match "^/employee/message/\d+$") {
        return "routes/employee/message.routes.ps1"
    }
    if ($Method -eq "DELETE" -and $Path -match "^/employee/\d+$") {
        return "routes/employee/delete.routes.ps1"
    }

    return ""
}

function Resolve-ProjectRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Method -eq "GET" -and $Path -eq "/projects/bootstrap") {
        return "routes/projects/bootstrap.routes.ps1"
    }
    if ($Method -eq "GET" -and $Path -match "^/projects/?$") {
        return "routes/projects/get.routes.ps1"
    }
    if ($Method -eq "POST" -and $Path -eq "/projects") {
        return "routes/projects/add.routes.ps1"
    }
    if ($Method -eq "PUT" -and $Path -match "^/projects/[^/]+$") {
        return "routes/projects/update.routes.ps1"
    }
    if ($Method -eq "DELETE" -and $Path -match "^/projects/[^/]+$") {
        return "routes/projects/delete.routes.ps1"
    }

    return ""
}

function Resolve-ProjectStatsRouteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Method -ne "GET") {
        return ""
    }
    if ($Path -match "^/stats/projects/trends/?$") {
        return "routes/stats/trends.routes.ps1"
    }
    if ($Path -match "^/stats/projects/?$") {
        return "routes/stats/summary.routes.ps1"
    }
    if ($Path -match "^/stats/projects/[^/]+/?$") {
        return "routes/stats/detail.routes.ps1"
    }

    return ""
}
