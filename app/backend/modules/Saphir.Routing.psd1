@{
    RootModule        = "Saphir.Routing.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "ae409224-b1af-4dc9-8b24-a3dd952857d2"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure route resolution and route catalog for the SAPHIR admin server."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-AdminRouteScriptPaths",
        "Resolve-AdminTopLevelRouteScript",
        "Resolve-EmployeeRouteScript",
        "Resolve-ProjectRouteScript",
        "Resolve-ProjectStatsRouteScript"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
