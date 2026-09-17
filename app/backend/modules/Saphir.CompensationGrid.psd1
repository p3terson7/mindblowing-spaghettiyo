@{
    RootModule        = "Saphir.CompensationGrid.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "77e1f9fd-d645-42b3-a0e0-9e6a1c1f31e5"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure compensation-grid validation and date-effective salary-rate resolution for SAPHIR."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "ConvertTo-CompensationGridCode",
        "ConvertTo-CompensationSalaryBand",
        "Test-CompensationSalaryGridDocument",
        "ConvertTo-CompensationSalaryGridDocument",
        "Resolve-CompensationSalaryBand"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
