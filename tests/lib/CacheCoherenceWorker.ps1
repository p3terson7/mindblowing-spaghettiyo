param([string]$FixtureFolder, [string]$Operation, [string]$Code = "000710001", [switch]$WithoutPublication)
. (Join-Path $PSScriptRoot "CacheCoherenceFixture.ps1") -FixtureFolder $FixtureFolder
Invoke-CoherenceFixtureMutation -Code $Code -Operation $Operation -WithoutPublication:$WithoutPublication
