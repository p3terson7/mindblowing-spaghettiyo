        # GET /employees: Return employee list
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees") {
            $employees = Get-EmployeeDirectoryList
            respondWithSuccess $response ($employees | ConvertTo-Json -Depth 3)
            continue
        }
