if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/stats/analytics-export/?$") {
    try {
        $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
        $report = New-AnalyticsReportExport `
            -StartDate ([string]$query["startDate"]) `
            -EndDate ([string]$query["endDate"]) `
            -Locale ([string]$query["locale"]) `
            -ProjectCode ([string]$query["projectCode"]) `
            -CurrentUser $currentUser
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$report.Html)
        respondWithDownload `
            -response $response `
            -Bytes $bytes `
            -ContentType "text/html; charset=utf-8" `
            -FileName ([string]$report.FileName)
    }
    catch [System.ArgumentException] {
        respondWithError $response 400 $_.Exception.Message
    }
    catch [System.UnauthorizedAccessException] {
        respondWithError $response 403 $_.Exception.Message
    }
    catch [System.Collections.Generic.KeyNotFoundException] {
        respondWithError $response 404 $_.Exception.Message
    }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to generate analytics report: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to generate the analytics report."
    }
    continue
}
