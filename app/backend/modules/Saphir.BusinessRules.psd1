@{
    RootModule        = "Saphir.BusinessRules.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "389bf57f-40dd-43e2-9a37-50c13ecf32dd"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure, versioned business-value contracts used by SAPHIR entry and classification workflows."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-SaphirBusinessRuleContract",
        "ConvertTo-SaphirEntryType",
        "ConvertTo-SaphirWorkSchedule",
        "Test-SaphirClassificationGroup",
        "Test-SaphirClassificationOrdinal"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
