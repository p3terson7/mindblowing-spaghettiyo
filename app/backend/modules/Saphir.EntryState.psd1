@{
    RootModule        = "Saphir.EntryState.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "504aa006-d98e-4ecd-89d7-b3d80105d0ed"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure entry flag and open-state decisions for the SAPHIR admin server."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "ConvertTo-BooleanFlag",
        "Test-EntryForgottenClockOut",
        "Test-EntryOpen"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
