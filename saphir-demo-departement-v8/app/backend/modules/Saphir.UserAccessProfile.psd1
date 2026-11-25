@{
    RootModule        = "Saphir.UserAccessProfile.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "11f20a2a-9be3-4703-baf1-caeec474fe8e"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure user-role and time-entry access-profile normalization for the SAPHIR admin server."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-NormalizedRoleName",
        "ConvertTo-TimeEntryTypeArray",
        "Get-EmployeeTimeEntryTypesFromUserRecord"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
