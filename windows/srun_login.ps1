[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateRange(5, 600)]
    [int]$ReadinessTimeoutSeconds = 90,
    [ValidateRange(1, 30)]
    [int]$ReadinessPollSeconds = 1,
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 5,
    [ValidateRange(2, 60)]
    [int]$RequestTimeoutSeconds = 10,
    [ValidateRange(1, 10)]
    [int]$StatusTimeoutSeconds = 2
)

$ErrorActionPreference = 'Stop'
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $SCRIPT_DIR 'config.ini'
}

$LOG_DIR = Join-Path $SCRIPT_DIR 'logs'
$LOG_FILE = Join-Path $LOG_DIR 'srun.log'
$ENC_VER = 'srun_bx1'
$N = '200'
$TYPE = '1'
$STD_ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/='
$SRUN_ALPHA = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA='

$script:USERNAME = $null
$script:PASSWORD = $null
$script:AC_ID = $null
$script:SERVER = $null
$script:SERVER_URI = $null
$script:LogUnavailable = $false

function Protect-LogText {
    param([AllowNull()][object]$Text)

    $value = [string]$Text
    if (-not [string]::IsNullOrEmpty($script:PASSWORD)) {
        $value = $value.Replace($script:PASSWORD, '<redacted>')
    }
    $value = $value -replace '(?i)(password=)[^&\s]+', '$1<redacted>'
    $value = $value -replace '[\r\n]+', ' '
    if ($value.Length -gt 500) {
        $value = $value.Substring(0, 500) + '...'
    }
    return $value
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $safeMessage = Protect-LogText $Message
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $safeMessage
    Write-Host $line

    if ($script:LogUnavailable) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::AppendAllText($LOG_FILE, $line + [Environment]::NewLine, $utf8Bom)
    }
    catch {
        $script:LogUnavailable = $true
        Write-Warning 'Persistent logging is unavailable; continuing with console output only.'
    }
}

function Read-SrunConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    $config = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith('#') -or
            $trimmed.StartsWith(';') -or
            ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $config[$key] = $value
        }
    }
    return $config
}

function Initialize-Configuration {
    $config = Read-SrunConfig -Path $ConfigPath

    $script:USERNAME = [string]$config['username']
    $script:PASSWORD = [string]$config['password']
    $script:AC_ID = if ($config.ContainsKey('ac_id')) { [string]$config['ac_id'] } else { '1' }
    $script:SERVER = if ($config.ContainsKey('server')) { [string]$config['server'] } else { 'http://192.168.75.252' }

    if ([string]::IsNullOrWhiteSpace($script:USERNAME)) {
        throw 'username is missing from config.ini.'
    }
    if ([string]::IsNullOrWhiteSpace($script:PASSWORD)) {
        throw 'password is missing from config.ini.'
    }
    if ($script:AC_ID -notmatch '^\d+$') {
        throw 'ac_id must contain digits only.'
    }

    $script:SERVER = $script:SERVER.Trim().TrimEnd('/')
    $parsedUri = $null
    if (-not [Uri]::TryCreate($script:SERVER, [UriKind]::Absolute, [ref]$parsedUri) -or
        $parsedUri.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($parsedUri.Host)) {
        throw 'server must be an absolute http:// or https:// URL.'
    }
    $script:SERVER_URI = $parsedUri
}

# The protocol helpers below intentionally retain the repository's existing
# Srun XXTEA/SRBX1 implementation.
function ordat($s, $i) {
    if ($i -lt $s.Length) { [int][char]$s[$i] } else { 0 }
}

function sencode($msg, [bool]$appendLen) {
    $l = $msg.Length
    $v = [System.Collections.Generic.List[long]]::new()
    for ($i = 0; $i -lt $l; $i += 4) {
        $val = [long](ordat $msg $i) -bor
            ([long](ordat $msg ($i + 1)) -shl 8) -bor
            ([long](ordat $msg ($i + 2)) -shl 16) -bor
            ([long](ordat $msg ($i + 3)) -shl 24)
        $v.Add($val)
    }
    if ($appendLen) { $v.Add([long]$l) }
    return $v
}

function lencode($v) {
    $builder = [System.Text.StringBuilder]::new()
    foreach ($val in $v) {
        [void]$builder.Append([char]($val -band 0xFF))
        [void]$builder.Append([char](($val -shr 8) -band 0xFF))
        [void]$builder.Append([char](($val -shr 16) -band 0xFF))
        [void]$builder.Append([char](($val -shr 24) -band 0xFF))
    }
    return $builder.ToString()
}

function xxtea_encode($msg, $key) {
    if ($msg -eq '') { return '' }
    $v = sencode $msg $true
    $k = sencode $key $false
    while ($k.Count -lt 4) { $k.Add(0L) }
    $n = $v.Count - 1
    $z = $v[$n]
    $q = 6 + [math]::Floor(52 / ($n + 1))
    $d = 0L
    while ($q -gt 0) {
        $d = ($d + 0x9E3779B9L) -band 0xFFFFFFFFL
        $e = ($d -shr 2) -band 3
        for ($p = 0; $p -lt $n; $p++) {
            $y = $v[$p + 1]
            $m = (($z -shr 5) -bxor (($y -shl 2) -band 0xFFFFFFFFL))
            $m = $m + ((($y -shr 3) -bxor (($z -shl 4) -band 0xFFFFFFFFL)) -bxor ($d -bxor $y))
            $m = $m + ($k[($p -band 3) -bxor $e] -bxor $z)
            $v[$p] = ($v[$p] + $m) -band 0xFFFFFFFFL
            $z = $v[$p]
        }
        $y = $v[0]
        $m = (($z -shr 5) -bxor (($y -shl 2) -band 0xFFFFFFFFL))
        $m = $m + ((($y -shr 3) -bxor (($z -shl 4) -band 0xFFFFFFFFL)) -bxor ($d -bxor $y))
        $m = $m + ($k[($n -band 3) -bxor $e] -bxor $z)
        $v[$n] = ($v[$n] + $m) -band 0xFFFFFFFFL
        $z = $v[$n]
        $q--
    }
    return (lencode $v)
}

function srun_base64($s) {
    $bytes = [byte[]]($s.ToCharArray() | ForEach-Object { [byte]([int][char]$_ -band 0xFF) })
    $base64 = [Convert]::ToBase64String($bytes)
    $output = [System.Text.StringBuilder]::new($base64.Length)
    foreach ($character in $base64.ToCharArray()) {
        $index = $STD_ALPHA.IndexOf($character)
        if ($index -ge 0) {
            [void]$output.Append($SRUN_ALPHA[$index])
        }
        else {
            [void]$output.Append($character)
        }
    }
    return $output.ToString()
}

function hmac_md5($key, $msg) {
    $hmac = [System.Security.Cryptography.HMACMD5]::new([System.Text.Encoding]::UTF8.GetBytes($key))
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($msg))
        return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $hmac.Dispose()
    }
}

function sha1_hex($s) {
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
        return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $sha1.Dispose()
    }
}

function Parse-Jsonp {
    param([Parameter(Mandatory = $true)][string]$Text)

    $trimmed = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'The Srun server returned an empty response.'
    }

    if ($trimmed.StartsWith('{')) {
        return $trimmed | ConvertFrom-Json
    }

    $match = [regex]::Match(
        $trimmed,
        '^[^(]+\((?<json>.*)\)\s*;?$',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['json'].Value)) {
        throw 'The Srun server returned invalid JSONP.'
    }
    return $match.Groups['json'].Value | ConvertFrom-Json
}

function Get-ResponseField {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    return [string]$property.Value
}

function ConvertTo-QueryString {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values)

    $pairs = foreach ($key in $Values.Keys) {
        $encodedKey = [Uri]::EscapeDataString([string]$key)
        $encodedValue = [Uri]::EscapeDataString([string]$Values[$key])
        '{0}={1}' -f $encodedKey, $encodedValue
    }
    return $pairs -join '&'
}

function Invoke-SrunJsonpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Parameters,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = $RequestTimeoutSeconds
    )

    $query = [ordered]@{}
    foreach ($key in $Parameters.Keys) {
        $query[$key] = $Parameters[$key]
    }
    if (-not $query.Contains('callback')) { $query['callback'] = 'srun_callback' }
    if (-not $query.Contains('_')) {
        $query['_'] = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }

    $uri = '{0}{1}?{2}' -f $script:SERVER, $Path, (ConvertTo-QueryString -Values $query)
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSeconds
    if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        throw 'The Srun server returned no content.'
    }
    return Parse-Jsonp -Text ([string]$response.Content)
}

function Get-NetworkErrorSummary {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    if ($exception -is [System.Net.WebException]) {
        $status = [string]$exception.Status
        if ($null -ne $exception.Response) {
            try {
                $statusCode = [int]$exception.Response.StatusCode
                return "HTTP/network error ($status, status $statusCode)"
            }
            catch { }
        }
        return "Network error ($status)"
    }
    return 'Request failed (' + $exception.GetType().Name + ')'
}

function Test-IsLikelyVirtualNetworkInterface {
    param([Parameter(Mandatory = $true)][System.Net.NetworkInformation.NetworkInterface]$Adapter)

    $identity = '{0} {1}' -f $Adapter.Name, $Adapter.Description
    return $identity -match '(?i)virtual|vmware|hyper-v|vethernet|loopback|bluetooth|\bvpn\b|\btap\b|\btun\b|docker|\bwsl\b|npcap|pseudo|teredo'
}

function Get-ReadyWiredIPv4 {
    $results = @()
    $ethernetTypes = @('Ethernet', 'GigabitEthernet', 'FastEthernetFx', 'FastEthernetT', 'Ethernet3Megabit')
    $adapters = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
        $ethernetTypes -contains ([string]$_.NetworkInterfaceType) -and
        -not (Test-IsLikelyVirtualNetworkInterface -Adapter $_)
    })

    foreach ($adapter in $adapters) {
        try {
            $properties = $adapter.GetIPProperties()
            $ipv4Properties = $properties.GetIPv4Properties()
            $interfaceIndex = if ($null -ne $ipv4Properties) { [int]$ipv4Properties.Index } else { -1 }
            $addresses = @($properties.UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not [System.Net.IPAddress]::IsLoopback($_.Address) -and
                ([string]$_.Address) -ne '0.0.0.0' -and
                ([string]$_.Address) -notlike '169.254.*'
            })
            foreach ($address in $addresses) {
                $results += [pscustomobject]@{
                    InterfaceAlias = [string]$adapter.Name
                    InterfaceIndex = $interfaceIndex
                    IPAddress      = [string]$address.Address
                }
            }
        }
        catch {
            continue
        }
    }
    return $results
}

function Test-ActiveWirelessAdapter {
    try {
        $wireless = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
            $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
            $_.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211
        })
        return $wireless.Count -gt 0
    }
    catch {
        return $true
    }
}

function Test-SrunServerReachable {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $port = if ($script:SERVER_URI.IsDefaultPort) {
            if ($script:SERVER_URI.Scheme -eq 'https') { 443 } else { 80 }
        }
        else {
            $script:SERVER_URI.Port
        }
        $connectTask = $client.ConnectAsync($script:SERVER_URI.Host, $port)
        if (-not $connectTask.Wait([Math]::Min(2000, $RequestTimeoutSeconds * 1000))) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Wait-WiredNetworkReady {
    Write-Log "Waiting up to $ReadinessTimeoutSeconds seconds for wired Ethernet, DHCP, and the Srun server."
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastState = ''

    while ($stopwatch.Elapsed.TotalSeconds -lt $ReadinessTimeoutSeconds) {
        $inspectionFailed = $false
        try {
            $wired = @(Get-ReadyWiredIPv4)
        }
        catch {
            $wired = @()
            $inspectionFailed = $true
        }

        if ($inspectionFailed) {
            $state = 'Waiting for the Windows network-adapter service to become available.'
        }
        elseif ($wired.Count -eq 0) {
            $state = 'Waiting for an active wired adapter with a usable IPv4 address.'
        }
        elseif (-not (Test-SrunServerReachable)) {
            $state = 'Wired IPv4 is ready; waiting for the Srun server to become reachable.'
        }
        else {
            $summary = ($wired | ForEach-Object { '{0} ({1})' -f $_.InterfaceAlias, $_.IPAddress }) -join ', '
            Write-Log "Wired network is ready: $summary."
            return $true
        }

        if ($state -ne $lastState) {
            Write-Log $state
            $lastState = $state
        }
        Start-Sleep -Seconds $ReadinessPollSeconds
    }

    Write-Log 'The wired network or Srun server did not become ready before the timeout.' 'ERROR'
    return $false
}

function Get-SrunOnlineStatus {
    try {
        $status = Invoke-SrunJsonpRequest -Path '/cgi-bin/rad_user_info' -Parameters ([ordered]@{}) -TimeoutSeconds $StatusTimeoutSeconds
        $errorCode = Get-ResponseField -Object $status -Name 'error'
        $errorMessage = Get-ResponseField -Object $status -Name 'error_msg'

        if ($errorCode -in @('ok', 'up_pwd_alert')) {
            return [pscustomobject]@{ Known = $true; Online = $true; Source = 'Srun status endpoint' }
        }

        $combined = "$errorCode $errorMessage"
        if ($combined -match '(?i)not[_ -]?online|offline|未上线|不在线') {
            return [pscustomobject]@{ Known = $true; Online = $false; Source = 'Srun status endpoint' }
        }
    }
    catch {
        Write-Log ('Srun online-status endpoint was unavailable: ' + (Get-NetworkErrorSummary -ErrorRecord $_)) 'WARN'
    }

    return [pscustomobject]@{ Known = $false; Online = $false; Source = 'Srun status endpoint' }
}

function Test-ControlledExternalConnectivity {
    if (Test-ActiveWirelessAdapter) {
        Write-Log 'Skipping the external connectivity fallback because an active wireless adapter could cause a false positive.' 'WARN'
        return $false
    }

    try {
        $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec $StatusTimeoutSeconds
        return ($response.StatusCode -eq 200 -and ([string]$response.Content).Trim() -eq 'Microsoft Connect Test')
    }
    catch {
        return $false
    }
}

function Test-PermanentAuthenticationError {
    param([AllowNull()][string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $false }
    return $ErrorText -match '(?i)password[_ -]?error|username[_ -]?error|invalid (user|password|credential)|user[_ -]?not[_ -]?found|account[_ -]?not[_ -]?found|用户不存在|账号不存在|密码错误|用户名错误'
}

function Invoke-SrunLoginAttempt {
    try {
        $challengeResponse = Invoke-SrunJsonpRequest -Path '/cgi-bin/get_challenge' -Parameters ([ordered]@{
            username = $script:USERNAME
            ip       = ''
        })
    }
    catch {
        return [pscustomobject]@{
            Success   = $false
            Permanent = $false
            Message   = 'Challenge request failed: ' + (Get-NetworkErrorSummary -ErrorRecord $_)
        }
    }

    $token = Get-ResponseField -Object $challengeResponse -Name 'challenge'
    $ip = Get-ResponseField -Object $challengeResponse -Name 'client_ip'
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($ip)) {
        return [pscustomobject]@{
            Success   = $false
            Permanent = $false
            Message   = 'Challenge response did not contain both challenge and client_ip.'
        }
    }

    $parsedIp = $null
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return [pscustomobject]@{
            Success   = $false
            Permanent = $false
            Message   = 'Challenge response contained an invalid IPv4 address.'
        }
    }

    try {
        $infoJson = [ordered]@{
            username = $script:USERNAME
            password = $script:PASSWORD
            ip       = $ip
            acid     = $script:AC_ID
            enc_ver  = $ENC_VER
        } | ConvertTo-Json -Compress

        $encrypted = xxtea_encode $infoJson $token
        $info = '{SRBX1}' + (srun_base64 $encrypted)
        $hmacMd5 = hmac_md5 $token $script:PASSWORD
        $encodedPassword = '{MD5}' + $hmacMd5
        $checksum = sha1_hex (
            $token + $script:USERNAME +
            $token + $hmacMd5 +
            $token + $script:AC_ID +
            $token + $ip +
            $token + $N +
            $token + $TYPE +
            $token + $info
        )

        $loginResponse = Invoke-SrunJsonpRequest -Path '/cgi-bin/srun_portal' -Parameters ([ordered]@{
            action       = 'login'
            username     = $script:USERNAME
            password     = $encodedPassword
            os           = 'Windows'
            name         = 'Windows'
            double_stack = '0'
            chksum       = $checksum
            info         = $info
            ac_id        = $script:AC_ID
            ip           = $ip
            n            = $N
            type         = $TYPE
        })
    }
    catch {
        return [pscustomobject]@{
            Success   = $false
            Permanent = $false
            Message   = 'Login request failed: ' + (Get-NetworkErrorSummary -ErrorRecord $_)
        }
    }

    $errorCode = Get-ResponseField -Object $loginResponse -Name 'error'
    $errorMessage = Get-ResponseField -Object $loginResponse -Name 'error_msg'
    if ($errorCode -in @('ok', 'up_pwd_alert')) {
        return [pscustomobject]@{
            Success   = $true
            Permanent = $false
            Message   = "Login succeeded for $($script:USERNAME) at $ip."
        }
    }

    $message = if (-not [string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage } elseif (-not [string]::IsNullOrWhiteSpace($errorCode)) { $errorCode } else { 'Unknown Srun response.' }
    return [pscustomobject]@{
        Success   = $false
        Permanent = (Test-PermanentAuthenticationError -ErrorText "$errorCode $errorMessage")
        Message   = "Srun rejected the login: $message"
    }
}

function Invoke-Main {
    Write-Log 'Task started.'

    try {
        Initialize-Configuration
    }
    catch {
        Write-Log ('Invalid configuration: ' + $_.Exception.Message) 'ERROR'
        return 2
    }

    if (-not (Wait-WiredNetworkReady)) {
        return 3
    }

    $onlineStatus = Get-SrunOnlineStatus
    if ($onlineStatus.Known -and $onlineStatus.Online) {
        Write-Log 'The wired campus connection is already authenticated; no login is needed.'
        return 0
    }

    if (-not $onlineStatus.Known -and (Test-ControlledExternalConnectivity)) {
        Write-Log 'The Srun status endpoint was inconclusive, but the controlled wired connectivity check succeeded.'
        return 0
    }

    if (-not $onlineStatus.Known) {
        Write-Log 'Online status remained inconclusive; proceeding directly to Srun authentication.' 'WARN'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Authentication attempt $attempt of $MaxAttempts."
        $result = Invoke-SrunLoginAttempt
        if ($result.Success) {
            Write-Log $result.Message
            return 0
        }

        Write-Log $result.Message 'ERROR'
        if ($result.Permanent) {
            Write-Log 'The server reported a permanent credential/configuration error; retries stopped.' 'ERROR'
            return 1
        }

        if ($attempt -lt $MaxAttempts) {
            $delay = 5 * $attempt
            Write-Log "Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }

    Write-Log "Authentication failed after $MaxAttempts attempts." 'ERROR'
    return 1
}

try {
    $exitCode = Invoke-Main
}
catch {
    Write-Log ('Unexpected fatal error: ' + $_.Exception.GetType().Name) 'ERROR'
    $exitCode = 1
}

Write-Log "Exiting with code $exitCode."
exit $exitCode
