@{
    RootModule        = "Saphir.EntryIdentity.psm1"
    ModuleVersion     = "1.0.0"
    GUID              = "f2ad2b54-7395-4c4e-aa38-ab49fcb28f2b"
    Author            = "SAPHIR"
    CompanyName       = "SAPHIR"
    Copyright         = "Copyright SAPHIR"
    Description       = "Pure entry identity and lookup decisions for the SAPHIR admin server."
    PowerShellVersion = "5.1"
    FunctionsToExport = @(
        "Get-EntryIdentifierValue",
        "Get-EntryExactPunchInText",
        "Get-EntryLegacyLookupKey",
        "Find-EntryIndex",
        "New-EntryIndexLookup",
        "Find-EntryIndexFromLookup"
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
