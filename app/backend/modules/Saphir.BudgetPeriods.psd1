@{
    RootModule        = "Saphir.BudgetPeriods.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "8f573571-f1b6-44a0-9d10-e973a9de3d51"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure validation and normalization for configurable SAPHIR budget periods."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-SaphirBudgetPeriodIds",
        "ConvertTo-SaphirBudgetPeriodConfiguration",
        "Get-SaphirConfiguredBudgetPeriods"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
