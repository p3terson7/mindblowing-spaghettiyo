@{
    RootModule        = "Saphir.OvertimeCompensation.psm1"
    ModuleVersion     = "1.1.0"
    GUID              = "9e8c651d-08c6-4761-970e-4dfc041973af"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure, versioned overtime multiplier rules shared by GC179 exports and monetary analytics."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-SaphirOvertimeRateCatalog",
        "Get-SaphirOvertimeMonetaryContract",
        "Get-SaphirOvertimeCategory",
        "Get-SaphirOvertimeRatePlan",
        "Get-SaphirOvertimeRateSegments",
        "ConvertTo-SaphirHourlyRateCents",
        "Get-SaphirOvertimeCostEstimate"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
