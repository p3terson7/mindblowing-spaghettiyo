        if ($request.HttpMethod -eq "GET") {
            $absolutePath = [string]$request.Url.AbsolutePath
            $isFrontendRequest = $absolutePath -eq "/" `
                -or $absolutePath -eq "/index.html" `
                -or $absolutePath -match "^/assets/" `
                -or $absolutePath -match "^/scripts/"

            if ($isFrontendRequest) {
                $relativePath = if ($absolutePath -eq "/") { "index.html" } else { $absolutePath.TrimStart("/") }
                $frontendFile = Resolve-FrontendFilePath -FrontendRoot $frontendRoot -RelativePath $relativePath
                if (-not $frontendFile) {
                    respondWithError $response 404 "Frontend asset not found."
                    continue
                }

                respondWithFile $response $frontendFile
                continue
            }
        }
