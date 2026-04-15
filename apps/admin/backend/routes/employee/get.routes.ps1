        # GET /employee/{employeeCode}: Return overtime data
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $entries = @((Read-JsonArrayFile -Path $dataFile) | ForEach-Object { Convert-ToNormalizedEntryObject -Entry $_ })
            respondWithSuccess $response ($entries | ConvertTo-Json -Depth 6)
            continue
        }
