@{
    RootModule        = "Saphir.EntryDuration.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "66a78644-f5ce-4a57-9b3d-b036bf8d38a8"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure quarter-hour credit calculation for SAPHIR overtime entries."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-QuarterHourCreditSummary"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
