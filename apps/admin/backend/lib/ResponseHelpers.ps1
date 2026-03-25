# Function to handle errors
function respondWithError($response, $statusCode, $message) {
    $response.StatusCode = $statusCode
    $errorMsg = "{ `"error`": `"$message`" }"
    $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($errorMsg), 0, ([System.Text.Encoding]::UTF8.GetBytes($errorMsg)).Length)
    $response.Close()
}

# Function to send success responses
function respondWithSuccess($response, $message) {
    $response.ContentType = "application/json"
    $response.StatusCode = 200
    $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($message), 0, ([System.Text.Encoding]::UTF8.GetBytes($message)).Length)
    $response.Close()
}
