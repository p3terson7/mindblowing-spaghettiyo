if ($request.Url.AbsolutePath -match '^/bug-reports/(bug-[0-9a-fA-F]{32})/comments/?$') {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 'Authentication required.'
        continue
    }
    $reportId = [string]$Matches[1]
    try {
        if ($request.HttpMethod -ne 'POST') {
            $response.Headers['Allow'] = 'POST'
            respondWithError $response 405 'Method not allowed.'
            continue
        }
        $payload = Read-JsonRequestBody -Request $request
        if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains 'expectedRevision')) {
            respondWithError $response 400 'expectedRevision is required.'
            continue
        }
        $expectedRevision = 0
        if (-not [int]::TryParse([string]$payload.expectedRevision, [ref]$expectedRevision) -or $expectedRevision -lt 1) {
            respondWithError $response 400 'expectedRevision must be a positive integer.'
            continue
        }
        $result = Add-BugReportComment -ReportId $reportId -ExpectedRevision $expectedRevision -Input $payload -CurrentUser $currentUser
        $postCommitWarnings = New-Object System.Collections.ArrayList
        $historyWarning = Invoke-PostCommitActionSafely -Description 'Comment added, but history logging failed' -Action {
            logHistory 'Comment' ("Commented on bug report {0}." -f $reportId) ([string]$currentUser.displayName) -PublishChange:$false
        }
        if ($historyWarning) { [void]$postCommitWarnings.Add($historyWarning) }
        $syncWarning = Invoke-PostCommitActionSafely -Description 'Comment added, but cross-machine refresh publication failed' -Action {
            Publish-DataChange -Category 'bug-reports' -Resource $reportId | Out-Null
        }
        if ($syncWarning) { [void]$postCommitWarnings.Add($syncWarning) }
        respondWithSuccess $response (([PSCustomObject][ordered]@{
            message  = 'Comment added successfully.'
            report   = $result.report
            comment  = $result.comment
            warnings = @($postCommitWarnings.ToArray())
        }) | ConvertTo-Json -Depth 16)
    }
    catch [System.ArgumentException] {
        respondWithError $response 400 $_.Exception.Message
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('SaphirHttpStatusCode')) {
            [int]$_.Exception.Data['SaphirHttpStatusCode']
        } else { 0 }
        if ($statusCode -in @(403, 404, 409)) { respondWithError $response $statusCode $_.Exception.Message }
        elseif ($statusCode -eq 503) { Rethrow-HttpStatusException -Exception $_.Exception }
        else {
            Write-Warning ("Unable to add bug-report comment: {0}" -f $_.Exception.Message)
            respondWithError $response 500 'Unable to add the comment.'
        }
    }
    continue
}

if ($request.Url.AbsolutePath -match '^/bug-reports/(bug-[0-9a-fA-F]{32})/attachments/?$') {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 'Authentication required.'
        continue
    }
    $reportId = [string]$Matches[1]
    try {
        if ($request.HttpMethod -ne 'POST') {
            $response.Headers['Allow'] = 'POST'
            respondWithError $response 405 'Method not allowed.'
            continue
        }
        $expectedRevision = 0
        if (-not [int]::TryParse([string]$request.Headers['X-SAPHIR-Expected-Revision'], [ref]$expectedRevision) -or $expectedRevision -lt 1) {
            respondWithError $response 400 'X-SAPHIR-Expected-Revision must be a positive integer.'
            continue
        }
        $rawFileName = [string]$request.Headers['X-SAPHIR-File-Name']
        try { $fileName = [System.Uri]::UnescapeDataString($rawFileName) }
        catch { throw [System.ArgumentException]::new('The image filename is invalid.') }
        $bytes = Read-BoundedRequestBytes -Request $request -MaxBytes 8388608
        $result = Add-BugReportAttachment `
            -ReportId $reportId `
            -ExpectedRevision $expectedRevision `
            -Bytes $bytes `
            -FileName $fileName `
            -ContentType ([string]$request.ContentType) `
            -CurrentUser $currentUser

        $postCommitWarnings = New-Object System.Collections.ArrayList
        $syncWarning = Invoke-PostCommitActionSafely -Description 'Image uploaded, but cross-machine refresh publication failed' -Action {
            Publish-DataChange -Category 'bug-reports' -Resource $reportId | Out-Null
        }
        if ($syncWarning) { [void]$postCommitWarnings.Add($syncWarning) }
        respondWithSuccess $response (([PSCustomObject][ordered]@{
            message    = 'Image uploaded successfully.'
            report     = $result.report
            attachment = $result.attachment
            warnings   = @($postCommitWarnings.ToArray())
        }) | ConvertTo-Json -Depth 16)
    }
    catch [System.ArgumentException] {
        respondWithError $response 400 $_.Exception.Message
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('SaphirHttpStatusCode')) {
            [int]$_.Exception.Data['SaphirHttpStatusCode']
        } else { 0 }
        if ($statusCode -in @(403, 404, 408, 409, 413)) {
            respondWithError $response $statusCode $_.Exception.Message
        }
        elseif ($statusCode -eq 503) { Rethrow-HttpStatusException -Exception $_.Exception }
        else {
            Write-Warning ("Unable to upload bug-report image: {0}" -f $_.Exception.Message)
            respondWithError $response 500 'Unable to upload the image.'
        }
    }
    continue
}

if ($request.Url.AbsolutePath -match '^/bug-reports/(bug-[0-9a-fA-F]{32})/attachments/(attachment-[0-9a-fA-F]{32})/?$') {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 'Authentication required.'
        continue
    }
    try {
        if ($request.HttpMethod -ne 'GET') {
            $response.Headers['Allow'] = 'GET'
            respondWithError $response 405 'Method not allowed.'
            continue
        }
        $attachment = Get-BugReportAttachment -ReportId ([string]$Matches[1]) -AttachmentId ([string]$Matches[2]) -CurrentUser $currentUser
        $response.Headers['Cache-Control'] = 'private, no-store, max-age=0'
        $response.Headers['X-Content-Type-Options'] = 'nosniff'
        Write-HttpResponseSafely -Response $response -StatusCode 200 -Bytes ([byte[]]$attachment.bytes) -ContentType ([string]$attachment.metadata.contentType)
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Data -and $_.Exception.Data.Contains('SaphirHttpStatusCode')) {
            [int]$_.Exception.Data['SaphirHttpStatusCode']
        } else { 0 }
        if ($statusCode -in @(404)) { respondWithError $response $statusCode $_.Exception.Message }
        elseif ($statusCode -eq 503) { Rethrow-HttpStatusException -Exception $_.Exception }
        else {
            Write-Warning ("Unable to download bug-report image: {0}" -f $_.Exception.Message)
            respondWithError $response 500 'Unable to load the image.'
        }
    }
    continue
}

if ($request.Url.AbsolutePath -match "^/bug-reports(?:/([^/]+))?/?$") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    $reportId = ([string]$Matches[1]).Trim()
    $isCollection = [string]::IsNullOrWhiteSpace($reportId)

    try {
        if ($isCollection -and $request.HttpMethod -eq "GET") {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $reports = @(Get-BugReports `
                -CurrentUser $currentUser `
                -Scope ([string]$query["scope"]) `
                -Status ([string]$query["status"]) `
                -Priority ([string]$query["priority"]) `
                -Category ([string]$query["category"]))
            respondWithSuccess $response (([PSCustomObject][ordered]@{
                reports = $reports
                count   = $reports.Count
            }) | ConvertTo-Json -Depth 8)
            continue
        }

        if ($isCollection -and $request.HttpMethod -eq "POST") {
            $payload = Read-JsonRequestBody -Request $request
            if ($null -eq $payload) {
                respondWithError $response 400 "A bug report is required."
                continue
            }

            $report = Add-BugReport -Input $payload -CurrentUser $currentUser
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $historyWarning = Invoke-PostCommitActionSafely -Description "Bug report created, but history logging failed" -Action {
                logHistory "Create" ("Created bug report {0}." -f [string]$report.reportId) ([string]$currentUser.displayName) -PublishChange:$false
            }
            if ($historyWarning) { [void]$postCommitWarnings.Add($historyWarning) }
            $syncWarning = Invoke-PostCommitActionSafely -Description "Bug report created, but cross-machine refresh publication failed" -Action {
                Publish-DataChange -Category "bug-reports" -Resource ([string]$report.reportId) | Out-Null
            }
            if ($syncWarning) { [void]$postCommitWarnings.Add($syncWarning) }

            respondWithSuccess $response (([PSCustomObject][ordered]@{
                message  = "Bug report created successfully."
                report   = $report
                warnings = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 16)
            continue
        }

        if (-not $isCollection -and $reportId -match "^bug-[0-9a-fA-F]{32}$" -and $request.HttpMethod -eq "GET") {
            $report = Get-BugReport -ReportId $reportId -CurrentUser $currentUser
            respondWithSuccess $response (($report) | ConvertTo-Json -Depth 16)
            continue
        }

        if (-not $isCollection -and $reportId -match "^bug-[0-9a-fA-F]{32}$" -and $request.HttpMethod -eq "PATCH") {
            $payload = Read-JsonRequestBody -Request $request
            if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains "expectedRevision")) {
                respondWithError $response 400 "expectedRevision is required."
                continue
            }
            $expectedRevision = 0
            if (-not [int]::TryParse([string]$payload.expectedRevision, [ref]$expectedRevision) -or $expectedRevision -lt 1) {
                respondWithError $response 400 "expectedRevision must be a positive integer."
                continue
            }

            $report = Update-BugReport -ReportId $reportId -ExpectedRevision $expectedRevision -Input $payload -CurrentUser $currentUser
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $historyWarning = Invoke-PostCommitActionSafely -Description "Bug report updated, but history logging failed" -Action {
                logHistory "Update" ("Updated bug report {0}." -f [string]$report.reportId) ([string]$currentUser.displayName) -PublishChange:$false
            }
            if ($historyWarning) { [void]$postCommitWarnings.Add($historyWarning) }
            $syncWarning = Invoke-PostCommitActionSafely -Description "Bug report updated, but cross-machine refresh publication failed" -Action {
                Publish-DataChange -Category "bug-reports" -Resource ([string]$report.reportId) | Out-Null
            }
            if ($syncWarning) { [void]$postCommitWarnings.Add($syncWarning) }

            respondWithSuccess $response (([PSCustomObject][ordered]@{
                message  = "Bug report updated successfully."
                report   = $report
                warnings = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 16)
            continue
        }

        if (-not $isCollection -and $reportId -notmatch "^bug-[0-9a-fA-F]{32}$") {
            respondWithError $response 404 "Bug report not found."
            continue
        }

        $response.Headers["Allow"] = if ($isCollection) { "GET, POST" } else { "GET, PATCH" }
        respondWithError $response 405 "Method not allowed."
    }
    catch [System.ArgumentException] {
        respondWithError $response 400 $_.Exception.Message
    }
    catch {
        $statusCode = 0
        if ($null -ne $_.Exception.Data -and
            $_.Exception.Data.Contains("SaphirHttpStatusCode")) {
            $statusCode = [int]$_.Exception.Data["SaphirHttpStatusCode"]
        }
        if ($statusCode -in @(403, 404, 408, 409, 413)) {
            respondWithError $response $statusCode $_.Exception.Message
        }
        elseif ($statusCode -eq 503) {
            Rethrow-HttpStatusException -Exception $_.Exception
        }
        else {
            Write-Warning ("Unable to process bug report request: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to process the bug report request."
        }
    }
    continue
}
