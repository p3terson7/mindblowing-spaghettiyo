        # DELETE /employee/{employeeCode}: Delete an overtime entry.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $delDate = $query["date"]
            $delPunchIn = $query["punchIn"]

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }
            if (-not ($delDate -and $delPunchIn)) {
                respondWithError $response 400 "Missing query parameters: date and punchIn are required."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile
                $entryToDelete = $existingData | Where-Object { $_.date -eq $delDate -and $_.punchIn -eq $delPunchIn } | Select-Object -First 1

                $filteredData = $existingData | Where-Object { $_.date -ne $delDate -or $_.punchIn -ne $delPunchIn }
                if ($filteredData.Count -eq $existingData.Count) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }
                Write-JsonAtomic -Path $dataFile -Value $filteredData -Depth 6

                $formattedDate = (Get-Date $delDate).ToString("MMMM dd, yyyy")
                $employeeName = Get-EmployeeName $employeeCode

                $historyEntry = "Deleted an entry on $formattedDate starting at <strong>$(Format-TimeForHistory $entryToDelete.punchIn)</strong>."
                # Append deletion message if provided as a query parameter.
                $delMessage = $query["message"]
                if ($delMessage) {
                    $historyEntry += " Reason: $delMessage"
                }
                logHistory "Delete" $historyEntry $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode
                respondWithSuccess $response '{ "message": "Entry deleted successfully." }'
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
