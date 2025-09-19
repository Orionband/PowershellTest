

param(
  [int]$ListenPort = 3000,
  [string]$ListenAddress = '127.0.0.1',
  [int]$ConnectTunnelTimeoutMinutes = 10,
  [int]$HttpRelayTimeoutMinutes = 5
)

# Resolve listen address
try {
  $ip = [System.Net.IPAddress]::Parse($ListenAddress)
} catch {
  try {
    $ip = ([System.Net.Dns]::GetHostEntry($ListenAddress)).AddressList |
          Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
          Select-Object -First 1
  } catch {
    Write-Error "Could not resolve ListenAddress '$ListenAddress'"
    return
  }
}

$listener = [System.Net.Sockets.TcpListener]::new($ip, $ListenPort)
$listener.Start()

# Create a runspace pool for per-connection workers
$minThreads = 1
$maxThreads = [Math]::Max(16, [Environment]::ProcessorCount * 8)
$pool = [RunspaceFactory]::CreateRunspacePool($minThreads, $maxThreads)
$pool.ApartmentState = 'MTA'
$pool.Open()

# Track worker pipelines so we can clean up completed ones
$workers = New-Object System.Collections.ArrayList

# Per-client handler script (runs inside a worker runspace)
$handleClientScript = @'
param(
  [System.Net.Sockets.TcpClient]$client,
  [int]$ConnectTunnelTimeoutMinutes,
  [int]$HttpRelayTimeoutMinutes
)

function WriteAscii([System.IO.Stream]$s, [string]$text) {
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
  $s.Write($bytes,0,$bytes.Length)
  $s.Flush()
}

function ReadHeaders([System.IO.Stream]$s) {
  $sb = [System.Text.StringBuilder]::new()
  $buf = New-Object byte[] 1
  while ($true) {
    $read = $s.Read($buf, 0, 1)
    if ($read -le 0) { return $null }
    $sb.Append([System.Text.Encoding]::ASCII.GetString($buf,0,1)) | Out-Null
    if ($sb.Length -ge 4) {
      $str = $sb.ToString()
      if ($str.EndsWith("`r`n`r`n")) { return $str }
    }
  }
}

function CopyDuplex([System.IO.Stream]$a, [System.IO.Stream]$b, [TimeSpan]$timeout) {
  $ctsTimeout = [System.Threading.CancellationTokenSource]::new($timeout)
  $ctsManual  = [System.Threading.CancellationTokenSource]::new()
  $linked = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($ctsTimeout.Token, $ctsManual.Token)

  $t1 = $a.CopyToAsync($b, 81920, $linked.Token)
  $t2 = $b.CopyToAsync($a, 81920, $linked.Token)

  [System.Threading.Tasks.Task]::WaitAny(@($t1,$t2)) | Out-Null
  $ctsManual.Cancel()

  try { [System.Threading.Tasks.Task]::WaitAll(@($t1,$t2), 500) } catch {}
  $ctsTimeout.Dispose(); $ctsManual.Dispose(); $linked.Dispose()
}

try {
  $clientEndPoint = $client.Client.RemoteEndPoint
  Write-Host "`nAccepted connection from $clientEndPoint"

  $client.NoDelay = $true
  $client.ReceiveTimeout = 300000
  $client.SendTimeout    = 300000
  $clientStream = $client.GetStream()
  $clientStream.ReadTimeout  = 300000
  $clientStream.WriteTimeout = 300000

  $requestText = ReadHeaders $clientStream
  if (-not $requestText) { Write-Host "Client closed before sending request headers"; return }

  $lines = $requestText -split "`r`n"
  $requestLine = $lines[0]
  if ([string]::IsNullOrWhiteSpace($requestLine)) { Write-Host "Empty request line"; return }

  Write-Host "Request line: $requestLine"
  $parts = $requestLine.Split(' ')
  if ($parts.Length -ne 3) { Write-Host "Invalid request line"; return }

  $method  = $parts[0]
  $target  = $parts[1]
  $version = $parts[2]

  if ($method -eq 'CONNECT') {
    # CONNECT: create HTTPS tunnel
    $hp = $target.Split(':')
    $targetHost = $hp[0]
    $targetPort = if ($hp.Length -ge 2 -and $hp[1]) { [int]$hp[1] } else { 443 }

    Write-Host "CONNECT to $targetHost`:$targetPort"

    $server = [System.Net.Sockets.TcpClient]::new()
    $server.NoDelay = $true
    $server.ReceiveTimeout = 300000
    $server.SendTimeout    = 300000
    try {
      $server.Connect($targetHost, $targetPort)
    } catch {
      Write-Host "Failed to connect to $targetHost`:$targetPort - $($_.Exception.Message)"
      WriteAscii $clientStream "HTTP/1.1 502 Bad Gateway`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
      return
    }

    $serverStream = $server.GetStream()
    WriteAscii $clientStream "HTTP/1.1 200 Connection Established`r`nProxy-Agent: ps-proxy`r`n`r`n"
    Write-Host "Sent 200 Connection Established; tunneling..."

    CopyDuplex -a $clientStream -b $serverStream -timeout ([TimeSpan]::FromMinutes($ConnectTunnelTimeoutMinutes))

    Write-Host "CONNECT tunnel finished"
    try { $server.Close() } catch {}
    return
  }
  else {
    # Regular HTTP request
    $targetHost = $null
    $targetPort = 80
    $pathAndQuery = $target

    if ($target.StartsWith('http://', [StringComparison]::OrdinalIgnoreCase)) {
      try {
        $uri = [System.Uri]::new($target)
      } catch {
        Write-Host "Invalid URI in request target: $target"
        WriteAscii $clientStream "HTTP/1.1 400 Bad Request`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        return
      }
      $targetHost = $uri.Host
      $targetPort = if ($uri.IsDefaultPort) { 80 } else { $uri.Port }
      $pathAndQuery = $uri.PathAndQuery
    }
    else {
      # Relative form, get Host from headers
      $hostHeader = $lines | Where-Object { $_ -match '^(?i)Host:\s' } | Select-Object -First 1
      if ($null -eq $hostHeader) {
        Write-Host "No Host header; cannot determine target"
        WriteAscii $clientStream "HTTP/1.1 400 Bad Request`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        return
      }
      $hostValue = ($hostHeader -replace '^(?i)Host:\s*','').Trim()
      if ($hostValue.Contains(':')) {
        $hp = $hostValue.Split(':',2)
        $targetHost = $hp[0]
        $targetPort = [int]$hp[1]
      } else {
        $targetHost = $hostValue
        $targetPort = 80
      }
    }

    Write-Host "HTTP request to $targetHost`:$targetPort$pathAndQuery"

    $server = [System.Net.Sockets.TcpClient]::new()
    $server.NoDelay = $true
    $server.ReceiveTimeout = 300000
    $server.SendTimeout    = 300000
    try {
      $server.Connect($targetHost, $targetPort)
    } catch {
      Write-Host "Failed to connect to $targetHost`:$targetPort - $($_.Exception.Message)"
      WriteAscii $clientStream "HTTP/1.1 502 Bad Gateway`r`nContent-Type: text/plain`r`nConnection: close`r`n`r`nFailed to connect to target server"
      return
    }

    $serverStream = $server.GetStream()
    $serverStream.ReadTimeout  = 300000
    $serverStream.WriteTimeout = 300000

    # Gather original headers (up to blank line)
    $headerLines = @()
    for ($i = 1; $i -lt $lines.Length; $i++) {
      if ($lines[$i] -eq '') { break }
      $headerLines += $lines[$i]
    }

    # Filter hop-by-hop headers and proxy-only headers
    $filtered = foreach ($h in $headerLines) {
      if ($h -match '^(?i)Proxy-Connection:')      { continue }
      if ($h -match '^(?i)Connection:')            { continue }
      if ($h -match '^(?i)Keep-Alive:')            { continue }
      if ($h -match '^(?i)Proxy-Authorization:')   { continue }
      $h
    }

    # Ensure Host is present
    if (-not ($filtered | Where-Object { $_ -match '^(?i)Host:\s' })) {
      $hostHeaderValue = if ($targetPort -ne 80) { "$targetHost`:$targetPort" } else { "$targetHost" }
      $filtered += "Host: $hostHeaderValue"
    }

    # Force close (server will close the connection after response)
    $filtered += "Connection: close"

    $modifiedRequestLine = "$method $pathAndQuery $version"
    $outHeader = $modifiedRequestLine + "`r`n" + ($filtered -join "`r`n") + "`r`n`r`n"
    WriteAscii $serverStream $outHeader

    # Full-duplex copy so request bodies (incl. chunked) and interim responses (100-continue) work
    CopyDuplex -a $clientStream -b $serverStream -timeout ([TimeSpan]::FromMinutes($HttpRelayTimeoutMinutes))

    Write-Host "HTTP relay finished"
    try { $server.Close() } catch {}
    return
  }
}
catch {
  Write-Host "Error handling client: $($_.Exception.Message)"
}
finally {
  if ($client) { try { $client.Close() } catch {} }
  Write-Host "Connection closed`n"
}
'@

# Accept loop: dispatch each client to a worker runspace
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($handleClientScript).
                 AddArgument($client).
                 AddArgument($ConnectTunnelTimeoutMinutes).
                 AddArgument($HttpRelayTimeoutMinutes)

    $ar = $ps.BeginInvoke()
    [void]$workers.Add([pscustomobject]@{ PS = $ps; AR = $ar })

    # Opportunistic cleanup of completed workers
    for ($i = $workers.Count - 1; $i -ge 0; $i--) {
      $w = $workers[$i]
      if ($w.AR.IsCompleted) {
        try { $w.PS.EndInvoke($w.AR) } catch {}
        $w.PS.Dispose()
        $workers.RemoveAt($i)
      }
    }
  }
}
finally {
  try { $listener.Stop() } catch {}
  foreach ($w in $workers) {
    try { $w.PS.EndInvoke($w.AR) } catch {}
    try { $w.PS.Dispose() } catch {}
  }
  try { $pool.Close(); $pool.Dispose() } catch {}
}
