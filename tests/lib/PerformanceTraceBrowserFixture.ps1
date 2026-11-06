param([string]$FixtureFolder, [string]$RuntimeFolder, [int]$Port)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
. (Join-Path $PSScriptRoot "CacheCoherenceFixture.ps1") -FixtureFolder $FixtureFolder -Create -EmployeeCount 40
$credential = New-PasswordCredential -Password ([string]$env:SAPHIR_TRACE_FIXTURE_PASSWORD)
$users = @([IO.File]::ReadAllText($usersFile) | ConvertFrom-Json)
$supervisor = @($users | Where-Object username -eq "audit-super")[0]
foreach ($property in $credential.PSObject.Properties) { $supervisor | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force }
$supervisor | Add-Member -NotePropertyName mustChangePassword -NotePropertyValue $false -Force
Write-CoherenceFixtureJson $usersFile $users
[IO.Directory]::CreateDirectory($RuntimeFolder) | Out-Null
Copy-Item -LiteralPath (Join-Path $repo "app") -Destination $RuntimeFolder -Recurse
$configuration = "@{ ListenerPrefix = 'http://localhost:$Port/'; DataFolderPath = '$($FixtureFolder.Replace("'", "''"))'; EnableDemoSeed = `$false; EnableGc179Import = `$false }"
[IO.File]::WriteAllText((Join-Path $RuntimeFolder "app/backend/saphir-config.psd1"), $configuration, (New-Object Text.UTF8Encoding($false)))
