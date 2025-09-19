# Prompt for URL
$url = Read-Host "Enter the URL"

try {
    # Download the webpage content
    $html = Invoke-WebRequest -Uri $url -UseBasicParsing

    # Create a temporary HTML file
    $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.html'
    Set-Content -Path $tempFile -Value $html.Content -Encoding UTF8

    # Open in Microsoft Edge
    Start-Process "msedge.exe" $tempFile

    Write-Host "Opened $url in Edge (from local temp file)." -ForegroundColor Green
}
catch {
    Write-Host "Error fetching or opening the URL: $_" -ForegroundColor Red
}
