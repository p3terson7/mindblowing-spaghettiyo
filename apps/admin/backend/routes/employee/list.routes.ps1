        # GET /employees: Return employee list
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees") {
            $employeesByCode = @{}

            $employeeNameMap = Get-EmployeeNameMap
            foreach ($property in $employeeNameMap.PSObject.Properties) {
                $employeesByCode[$property.Name] = [PSCustomObject]@{
                    code = [string]$property.Name
                    name = [string]$property.Value
                }
            }

            Get-ChildItem -Path $sharedFolder -Filter "*_data.json" | ForEach-Object {
                $code = $_.BaseName -replace "_data", ""
                if (-not $employeesByCode.ContainsKey($code)) {
                    $employeesByCode[$code] = [PSCustomObject]@{
                        code = $code
                        name = Get-EmployeeName $code
                    }
                }
            }

            $employees = $employeesByCode.Keys | Sort-Object | ForEach-Object { $employeesByCode[$_] }
            respondWithSuccess $response ($employees | ConvertTo-Json -Depth 3)
            continue
        }
