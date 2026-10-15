@{
    RootModule        = "Saphir.ProjectCatalog.psm1"
    ModuleVersion     = "1.1.0"
    GUID              = "a3e2bb59-8e40-49a2-8b93-417f5cf7a35c"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure project catalog normalization, visual identity, assignment, and archive decisions for SAPHIR."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-ProjectColorKeys",
        "Get-ProjectColorKeyFromText",
        "Get-DefaultProjectColorKey",
        "Test-ProjectColorKey",
        "Resolve-ProjectColorKey",
        "Get-ProjectMarkerKeys",
        "Get-ProjectMarkerKeyFromText",
        "Get-DefaultProjectMarkerKey",
        "Test-ProjectMarkerKey",
        "Resolve-ProjectMarkerKey",
        "ConvertTo-CodeArray",
        "Get-ProjectAdminCodes",
        "Get-ProjectBackupAdminCodes",
        "Test-ProjectArchived",
        "ConvertTo-NormalizedProjectObject",
        "ConvertTo-ProjectArchiveScope",
        "Select-ProjectsByArchiveScope"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
