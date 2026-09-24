@{
    RootModule        = 'Saphir.BugReports.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'ea266eef-cd8e-4ff6-a835-0c0ba7a82a39'
    Author            = 'SAPHIR'
    CompanyName       = 'SAPHIR'
    Copyright         = '(c) SAPHIR. All rights reserved.'
    Description       = 'Pure validation, authorization, and projection rules for SAPHIR bug reports.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertTo-SaphirBugReportCreateInput',
        'ConvertTo-SaphirBugReportCommentInput',
        'ConvertTo-SaphirBugReportPatchInput',
        'Test-SaphirBugReportVisible',
        'Test-SaphirBugReportReporterEditAllowed',
        'Test-SaphirBugReportAdministrativeUser',
        'New-SaphirBugReportSummary'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
