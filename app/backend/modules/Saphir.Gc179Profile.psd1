@{
    RootModule        = "Saphir.Gc179Profile.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "9e155901-ceae-4e0b-8acb-f2830bc923de"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure GC179 employee-profile normalization for the SAPHIR admin server."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "ConvertTo-Gc179UpperText",
        "Get-Gc179NamePartsFromDisplayName",
        "ConvertTo-Gc179BooleanValue",
        "ConvertTo-Gc179PriText",
        "ConvertTo-Gc179HeaderCodeText",
        "ConvertTo-Gc179GroupText",
        "ConvertTo-Gc179SubGroupText",
        "ConvertTo-Gc179LevelText",
        "ConvertTo-Gc179PositionText",
        "ConvertTo-Gc179EchelonText",
        "ConvertTo-Gc179ProfileObject",
        "Get-Gc179ProfileFromUserRecord"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
