# SafeSync direct cloud API provider module. UTF-8 BOM for Windows PowerShell 5.1.

Add-Type -AssemblyName System.Security
. (Join-Path $PSScriptRoot 'SafeSync.Integrity.ps1')

$script:SafeSyncGoogleTokenContext = $null

function Get-SafeSyncFallbackKey {
    $keyPath = Join-Path $script:DataRoot 'secrets.key'
    if (Test-Path -LiteralPath $keyPath) { return [System.IO.File]::ReadAllBytes($keyPath) }
    $key = New-Object byte[] 64
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($key) } finally { $rng.Dispose() }
    [System.IO.File]::WriteAllBytes($keyPath, $key)
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetAccessRuleProtection($true,$false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')
        $security.AddAccessRule($rule)
        [System.IO.File]::SetAccessControl($keyPath,$security)
    } catch {}
    return $key
}

function Protect-SafeSyncSecret([string]$PlainText) {
    if ([string]::IsNullOrWhiteSpace($PlainText)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return 'dpapi:' + [Convert]::ToBase64String($protected)
    } catch {
        $key = Get-SafeSyncFallbackKey
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = $key[0..31]; $aes.GenerateIV()
            $encryptor = $aes.CreateEncryptor()
            try { $cipher = $encryptor.TransformFinalBlock($bytes,0,$bytes.Length) } finally { $encryptor.Dispose() }
            $payload = New-Object byte[] ($aes.IV.Length + $cipher.Length)
            [Array]::Copy($aes.IV,0,$payload,0,$aes.IV.Length); [Array]::Copy($cipher,0,$payload,$aes.IV.Length,$cipher.Length)
            $hmac = New-Object System.Security.Cryptography.HMACSHA256(,$key[32..63])
            try { $tag = $hmac.ComputeHash($payload) } finally { $hmac.Dispose() }
            return 'aes:' + [Convert]::ToBase64String($payload + $tag)
        } finally { $aes.Dispose() }
    }
}

function Unprotect-SafeSyncSecret([string]$ProtectedText) {
    if ([string]::IsNullOrWhiteSpace($ProtectedText)) { return '' }
    if ($ProtectedText.StartsWith('aes:')) {
        $all = [Convert]::FromBase64String($ProtectedText.Substring(4)); if($all.Length -lt 49){throw 'Encrypted secret is invalid.'}
        $payload=$all[0..($all.Length-33)];$storedTag=$all[($all.Length-32)..($all.Length-1)];$key=Get-SafeSyncFallbackKey
        $hmac=New-Object System.Security.Cryptography.HMACSHA256(,$key[32..63]);try{$tag=$hmac.ComputeHash($payload)}finally{$hmac.Dispose()}
        $valid=$true;for($i=0;$i -lt 32;$i++){if($tag[$i] -ne $storedTag[$i]){$valid=$false}};if(-not $valid){throw 'Encrypted secret integrity check failed.'}
        $iv=$payload[0..15];$cipher=$payload[16..($payload.Length-1)];$aes=[System.Security.Cryptography.Aes]::Create()
        try{$aes.Key=$key[0..31];$aes.IV=$iv;$decryptor=$aes.CreateDecryptor();try{$plain=$decryptor.TransformFinalBlock($cipher,0,$cipher.Length)}finally{$decryptor.Dispose()}}finally{$aes.Dispose()}
        return [System.Text.Encoding]::UTF8.GetString($plain)
    }
    $encoded = if($ProtectedText.StartsWith('dpapi:')){$ProtectedText.Substring(6)}else{$ProtectedText}
    $bytes = [Convert]::FromBase64String($encoded)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function ConvertTo-SafeSyncBase64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-SafeSyncPkce {
    $random = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $verifier = ConvertTo-SafeSyncBase64Url $random
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $challenge = ConvertTo-SafeSyncBase64Url ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))) } finally { $sha.Dispose() }
    return [pscustomobject]@{ Verifier=$verifier; Challenge=$challenge }
}

function ConvertTo-SafeSyncQuery([hashtable]$Values) {
    $parts = foreach ($key in $Values.Keys) {
        if ($null -ne $Values[$key] -and [string]$Values[$key] -ne '') {
            '{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$Values[$key])
        }
    }
    return $parts -join '&'
}

function Receive-SafeSyncOAuthCode([string]$AuthorizationUrl, [string]$ExpectedState, [int]$Port = 53682) {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    try {
        Start-Process $AuthorizationUrl
        $acceptTask = $listener.AcceptTcpClientAsync()
        if (-not $acceptTask.Wait(180000)) { throw 'OAuth sign-in timed out.' }
        $client = $acceptTask.Result
        try {
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
            $requestLine = $reader.ReadLine()
            while (-not [string]::IsNullOrEmpty($reader.ReadLine())) {}
            if ($requestLine -notmatch '^GET\s+([^\s]+)\s+HTTP/') { throw 'Invalid OAuth response.' }
            $requestUri = New-Object System.Uri("http://127.0.0.1:$Port$($matches[1])")
            $query = [System.Web.HttpUtility]::ParseQueryString($requestUri.Query)
            $state = $query['state']
            $code = $query['code']
            $oauthError = $query['error']
            if (-not [string]::IsNullOrWhiteSpace($oauthError)) { throw "Authorization was denied: $oauthError" }
            if ($state -ne $ExpectedState) { throw 'OAuth state validation failed.' }
            if ([string]::IsNullOrWhiteSpace($code)) { throw 'OAuth authorization code was not returned.' }
            $html = '<!doctype html><html><head><meta charset="utf-8"><title>SafeSync</title></head><body style="font-family:Segoe UI;padding:40px"><h2>SafeSync account connected</h2><p>You may close this browser tab and return to SafeSync.</p></body></html>'
            $body = [System.Text.Encoding]::UTF8.GetBytes($html)
            $header = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header,0,$header.Length); $stream.Write($body,0,$body.Length); $stream.Flush()
            return $code
        }
        finally { if ($null -ne $client) { $client.Dispose() } }
    }
    finally { $listener.Stop() }
}

function Connect-SafeSyncDropbox([object]$Account) {
    if ([string]::IsNullOrWhiteSpace([string]$Account.AppKey)) { throw 'Dropbox App Key is required.' }
    Add-Type -AssemblyName System.Web
    $pkce = New-SafeSyncPkce
    $state = [guid]::NewGuid().ToString('N')
    $redirect = 'http://127.0.0.1:53682/'
    $query = ConvertTo-SafeSyncQuery @{
        client_id=[string]$Account.AppKey; response_type='code'; redirect_uri=$redirect; state=$state
        token_access_type='offline'; code_challenge=$pkce.Challenge; code_challenge_method='S256'
    }
    $code = Receive-SafeSyncOAuthCode -AuthorizationUrl "https://www.dropbox.com/oauth2/authorize?$query" -ExpectedState $state
    $token = Invoke-RestMethod -Method Post -Uri 'https://api.dropboxapi.com/oauth2/token' -ContentType 'application/x-www-form-urlencoded' -Body @{
        code=$code; grant_type='authorization_code'; client_id=[string]$Account.AppKey; redirect_uri=$redirect; code_verifier=$pkce.Verifier
    }
    if ([string]::IsNullOrWhiteSpace([string]$token.refresh_token)) { throw 'Dropbox did not return a refresh token.' }
    $headers = @{ Authorization="Bearer $($token.access_token)" }
    $profile = Invoke-RestMethod -Method Post -Uri 'https://api.dropboxapi.com/2/users/get_current_account' -Headers $headers -ContentType 'application/json' -Body 'null'
    $Account.RefreshTokenProtected = Protect-SafeSyncSecret ([string]$token.refresh_token)
    $Account.AccountName = if (-not [string]::IsNullOrWhiteSpace([string]$profile.email)) { [string]$profile.email } else { [string]$profile.name.display_name }
    $Account.AccountId = [string]$profile.account_id
    return $Account
}

function Connect-SafeSyncGoogleDrive([object]$Account) {
    if ([string]::IsNullOrWhiteSpace([string]$Account.ClientId)) { throw 'Google OAuth Client ID is required.' }
    Add-Type -AssemblyName System.Web
    $pkce = New-SafeSyncPkce
    $state = [guid]::NewGuid().ToString('N')
    $redirect = 'http://127.0.0.1:53682/'
    $query = ConvertTo-SafeSyncQuery @{
        client_id=[string]$Account.ClientId; response_type='code'; redirect_uri=$redirect; state=$state
        scope='https://www.googleapis.com/auth/drive'; access_type='offline'; prompt='consent'
        code_challenge=$pkce.Challenge; code_challenge_method='S256'
    }
    $code = Receive-SafeSyncOAuthCode -AuthorizationUrl "https://accounts.google.com/o/oauth2/v2/auth?$query" -ExpectedState $state
    $body = @{
        code=$code; grant_type='authorization_code'; client_id=[string]$Account.ClientId; redirect_uri=$redirect; code_verifier=$pkce.Verifier
    }
    $clientSecret = Unprotect-SafeSyncSecret ([string]$Account.ClientSecretProtected)
    if (-not [string]::IsNullOrWhiteSpace($clientSecret)) { $body.client_secret = $clientSecret }
    $token = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -ContentType 'application/x-www-form-urlencoded' -Body $body
    if ([string]::IsNullOrWhiteSpace([string]$token.refresh_token)) { throw 'Google did not return a refresh token.' }
    $headers = @{ Authorization="Bearer $($token.access_token)" }
    $profile = Invoke-RestMethod -Method Get -Uri 'https://www.googleapis.com/drive/v3/about?fields=user' -Headers $headers
    $Account.RefreshTokenProtected = Protect-SafeSyncSecret ([string]$token.refresh_token)
    $Account.AccountName = [string]$profile.user.emailAddress
    $Account.AccountId = [string]$profile.user.permissionId
    return $Account
}

function Request-SafeSyncGoogleAccessToken([object]$Config) {
    $account = $Config.CloudAccounts.GoogleDrive
    $refreshToken = Unprotect-SafeSyncSecret ([string]$account.RefreshTokenProtected)
    if ([string]::IsNullOrWhiteSpace($refreshToken)) { throw 'Google Drive account is not connected.' }
    $body = @{ grant_type='refresh_token'; refresh_token=$refreshToken; client_id=[string]$account.ClientId }
    $clientSecret = Unprotect-SafeSyncSecret ([string]$account.ClientSecretProtected)
    if (-not [string]::IsNullOrWhiteSpace($clientSecret)) { $body.client_secret = $clientSecret }
    $response = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -ContentType 'application/x-www-form-urlencoded' -Body $body
    $expiresIn = 3600
    if ($null -ne $response.PSObject.Properties['expires_in']) { [void][int]::TryParse([string]$response.expires_in, [ref]$expiresIn) }
    $script:SafeSyncGoogleTokenContext = [pscustomobject]@{
        Token = [string]$response.access_token
        ExpiresUtc = [datetime]::UtcNow.AddSeconds([Math]::Max(60, $expiresIn - 120))
        Config = $Config
    }
    return [string]$response.access_token
}

function Get-SafeSyncGoogleActiveToken([string]$FallbackToken) {
    if ($null -eq $script:SafeSyncGoogleTokenContext) { return $FallbackToken }
    if ([datetime]::UtcNow -ge [datetime]$script:SafeSyncGoogleTokenContext.ExpiresUtc) {
        return Request-SafeSyncGoogleAccessToken $script:SafeSyncGoogleTokenContext.Config
    }
    return [string]$script:SafeSyncGoogleTokenContext.Token
}

function Test-SafeSyncGoogleUnauthorized([object]$ErrorRecord) {
    try {
        if ($null -ne $ErrorRecord.Exception.Response -and [int]$ErrorRecord.Exception.Response.StatusCode -eq 401) { return $true }
    } catch {}
    $details = if ($null -ne $ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { '' }
    return (($ErrorRecord.Exception.Message + ' ' + $details) -match '(^|\D)401(\D|$)|Unauthorized')
}

function Invoke-SafeSyncGoogleRequest([string]$Token, [scriptblock]$Request) {
    $activeToken = Get-SafeSyncGoogleActiveToken $Token
    try { return & $Request $activeToken }
    catch {
        if (-not (Test-SafeSyncGoogleUnauthorized $_) -or $null -eq $script:SafeSyncGoogleTokenContext) { throw }
        $activeToken = Request-SafeSyncGoogleAccessToken $script:SafeSyncGoogleTokenContext.Config
        return & $Request $activeToken
    }
}

function Get-SafeSyncCloudAccessToken([string]$Provider, [object]$Config) {
    if ($Provider -eq 'Dropbox') {
        $account = $Config.CloudAccounts.Dropbox
        $refreshToken = Unprotect-SafeSyncSecret ([string]$account.RefreshTokenProtected)
        if ([string]::IsNullOrWhiteSpace($refreshToken)) { throw 'Dropbox account is not connected.' }
        $token = Invoke-RestMethod -Method Post -Uri 'https://api.dropboxapi.com/oauth2/token' -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type='refresh_token'; refresh_token=$refreshToken; client_id=[string]$account.AppKey
        }
        return [string]$token.access_token
    }
    return Request-SafeSyncGoogleAccessToken $Config
}

function Invoke-SafeSyncDropboxRpc([string]$Token, [string]$Endpoint, [object]$Body) {
    return Invoke-RestMethod -Method Post -Uri "https://api.dropboxapi.com/2/$Endpoint" -Headers @{ Authorization="Bearer $Token" } -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 12 -Compress)
}

function Join-SafeSyncDropboxPath([string]$Root, [string]$Relative) {
    $rootPath = if ($Root -eq '/') { '' } else { $Root.TrimEnd('/') }
    $relativePath = $Relative.Replace('\','/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return $rootPath }
    return "$rootPath/$relativePath"
}

function Get-SafeSyncDropboxEntries([string]$Token, [string]$Root, [bool]$Recursive = $true) {
    $path = if ($Root -eq '/') { '' } else { $Root }
    $response = Invoke-SafeSyncDropboxRpc $Token 'files/list_folder' @{ path=$path; recursive=$Recursive; include_deleted=$false; include_non_downloadable_files=$true }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($response.entries)) { $entries.Add($entry) }
    while ([bool]$response.has_more) {
        $response = Invoke-SafeSyncDropboxRpc $Token 'files/list_folder/continue' @{ cursor=[string]$response.cursor }
        foreach ($entry in @($response.entries)) { $entries.Add($entry) }
    }
    return $entries.ToArray()
}

function Get-SafeSyncDropboxLatestCursor([string]$Token, [string]$Root) {
    $path = if ($Root -eq '/') { '' } else { $Root }
    $response = Invoke-SafeSyncDropboxRpc $Token 'files/list_folder/get_latest_cursor' @{ path=$path; recursive=$true; include_deleted=$true; include_non_downloadable_files=$true }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['cursor']) { return '' }
    return [string]$response.cursor
}

function Get-SafeSyncDropboxChanges([string]$Token, [string]$Cursor) {
    $entries = New-Object System.Collections.Generic.List[object]
    $response = Invoke-SafeSyncDropboxRpc $Token 'files/list_folder/continue' @{ cursor=$Cursor }
    foreach ($entry in @($response.entries)) { $entries.Add($entry) }
    while ([bool]$response.has_more) {
        $response = Invoke-SafeSyncDropboxRpc $Token 'files/list_folder/continue' @{ cursor=[string]$response.cursor }
        foreach ($entry in @($response.entries)) { $entries.Add($entry) }
    }
    return [pscustomobject]@{ Entries=$entries.ToArray(); Cursor=[string]$response.cursor }
}

function Ensure-SafeSyncDropboxFolder([string]$Token, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') { return }
    $current = ''
    foreach ($part in $Path.Trim('/').Split('/')) {
        $current += "/$part"
        try { [void](Invoke-SafeSyncDropboxRpc $Token 'files/create_folder_v2' @{ path=$current; autorename=$false }) } catch {
            if ($_.Exception.Message -notmatch 'conflict') { throw }
        }
    }
}

function Move-SafeSyncDropboxItem([string]$Token, [string]$FromPath, [string]$ToPath, [bool]$AutoRename = $true) {
    Ensure-SafeSyncDropboxFolder $Token ($ToPath.Substring(0, $ToPath.LastIndexOf('/')))
    [void](Invoke-SafeSyncDropboxRpc $Token 'files/move_v2' @{ from_path=$FromPath; to_path=$ToPath; autorename=$AutoRename; allow_shared_folder=$false })
}

function Get-SafeSyncConflictCopyName([string]$Name) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    return "$baseName.SafeSync-conflict-$(Get-Date -Format 'yyyyMMdd-HHmmssfff')-$([guid]::NewGuid().ToString('N').Substring(0,6))$extension"
}

function Get-SafeSyncDropboxConflictPath([string]$RemotePath) {
    $slash = $RemotePath.LastIndexOf('/')
    $parent = if ($slash -le 0) { '' } else { $RemotePath.Substring(0, $slash) }
    $name = if ($slash -lt 0) { $RemotePath } else { $RemotePath.Substring($slash + 1) }
    return "$parent/$(Get-SafeSyncConflictCopyName $name)"
}

function ConvertTo-SafeSyncDropboxHeaderJson([object]$Body) {
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return [regex]::Replace($json, '[^\x20-\x7e]', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) '\u{0:x4}' -f [int][char]$match.Value })
}

function Send-SafeSyncDropboxFile([string]$Token, [System.IO.FileInfo]$File, [string]$RemotePath) {
    # Only unique staging paths are uploaded. Never overwrite a live remote file.
    $commit = @{ path=$RemotePath; mode='add'; autorename=$false; client_modified=$File.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); mute=$true; strict_conflict=$true }
    if ($File.Length -le 140MB) {
        $headers = @{ Authorization="Bearer $Token"; 'Dropbox-API-Arg'=(ConvertTo-SafeSyncDropboxHeaderJson $commit) }
        return Invoke-RestMethod -Method Post -Uri 'https://content.dropboxapi.com/2/files/upload' -Headers $headers -ContentType 'application/octet-stream' -InFile $File.FullName
    }
    $chunkSize = 8MB
    $stream = [System.IO.File]::OpenRead($File.FullName)
    try {
        $buffer = New-Object byte[] $chunkSize
        $read = $stream.Read($buffer,0,$buffer.Length)
        [byte[]]$first = $buffer
        if ($read -ne $buffer.Length) { $first = New-Object byte[] $read; [Buffer]::BlockCopy($buffer,0,$first,0,$read) }
        $start = Invoke-RestMethod -Method Post -Uri 'https://content.dropboxapi.com/2/files/upload_session/start' -Headers @{Authorization="Bearer $Token";'Dropbox-API-Arg'='{"close":false}'} -ContentType 'application/octet-stream' -Body $first
        [long]$offset = $read
        while ($offset -lt $File.Length) {
            $read = $stream.Read($buffer,0,$buffer.Length)
            if ($read -le 0) { throw 'Unexpected end of upload snapshot. The previous backup was preserved.' }
            [byte[]]$bytes = $buffer
            if ($read -ne $buffer.Length) { $bytes = New-Object byte[] $read; [Buffer]::BlockCopy($buffer,0,$bytes,0,$read) }
            $isLast = ($offset + $read) -ge $File.Length
            if ($isLast) {
                $arg = ConvertTo-SafeSyncDropboxHeaderJson @{ cursor=@{ session_id=[string]$start.session_id; offset=$offset }; commit=$commit }
                return Invoke-RestMethod -Method Post -Uri 'https://content.dropboxapi.com/2/files/upload_session/finish' -Headers @{Authorization="Bearer $Token";'Dropbox-API-Arg'=$arg} -ContentType 'application/octet-stream' -Body $bytes
            }
            $arg = @{ cursor=@{ session_id=[string]$start.session_id; offset=$offset }; close=$false } | ConvertTo-Json -Depth 6 -Compress
            [void](Invoke-RestMethod -Method Post -Uri 'https://content.dropboxapi.com/2/files/upload_session/append_v2' -Headers @{Authorization="Bearer $Token";'Dropbox-API-Arg'=$arg} -ContentType 'application/octet-stream' -Body $bytes)
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
}

function Get-SafeSyncGoogleChildren([string]$Token, [string]$ParentId) {
    $items = New-Object System.Collections.Generic.List[object]
    $pageToken = ''
    do {
        $query = "'$($ParentId.Replace("'","\\'"))' in parents and trashed = false"
        $values = @{ q=$query; spaces='drive'; pageSize='1000'; fields='nextPageToken,files(id,name,mimeType,parents,modifiedTime,createdTime,size,md5Checksum,sha256Checksum,version)' }
        if (-not [string]::IsNullOrWhiteSpace($pageToken)) { $values.pageToken = $pageToken }
        $uri = 'https://www.googleapis.com/drive/v3/files?' + (ConvertTo-SafeSyncQuery $values)
        $response = Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Get -Uri $uri -Headers @{Authorization="Bearer $activeToken"} }
        foreach ($item in @($response.files)) { $items.Add($item) }
        $pageToken = if ($null -ne $response.PSObject.Properties['nextPageToken']) { [string]$response.nextPageToken } else { '' }
    } while (-not [string]::IsNullOrWhiteSpace($pageToken))
    return $items.ToArray()
}

function Get-SafeSyncGoogleStartPageToken([string]$Token) {
    $response = Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Get -Uri 'https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=true' -Headers @{Authorization="Bearer $activeToken"} }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['startPageToken']) { return '' }
    return [string]$response.startPageToken
}

function Get-SafeSyncGoogleChanges([string]$Token, [string]$PageToken) {
    $changes = New-Object System.Collections.Generic.List[object]
    $next = $PageToken
    $newStart = ''
    do {
        $values = @{ pageToken=$next; spaces='drive'; includeRemoved='true'; supportsAllDrives='true'; includeItemsFromAllDrives='true'; fields='nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,trashed,parents,modifiedTime,createdTime,size,md5Checksum,sha256Checksum,version))' }
        $uri = 'https://www.googleapis.com/drive/v3/changes?' + (ConvertTo-SafeSyncQuery $values)
        $response = Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Get -Uri $uri -Headers @{Authorization="Bearer $activeToken"} }
        foreach ($change in @($response.changes)) { $changes.Add($change) }
        $next = if ($null -ne $response.PSObject.Properties['nextPageToken']) { [string]$response.nextPageToken } else { '' }
        if ($null -ne $response.PSObject.Properties['newStartPageToken']) { $newStart = [string]$response.newStartPageToken }
    } while (-not [string]::IsNullOrWhiteSpace($next))
    if ([string]::IsNullOrWhiteSpace($newStart)) { $newStart = $PageToken }
    return [pscustomobject]@{ Changes=$changes.ToArray(); Token=$newStart }
}

function Get-SafeSyncGoogleTree([string]$Token, [string]$RootId) {
    $files = @{}
    $folders = @{'_'=$RootId}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Id=$RootId; Relative='' })
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($item in @(Get-SafeSyncGoogleChildren $Token ([string]$current.Id))) {
            $relative = if ([string]::IsNullOrWhiteSpace([string]$current.Relative)) { [string]$item.name } else { "$($current.Relative)/$($item.name)" }
            if (Test-SafeSyncInternalPath $relative) { continue }
            if ([string]$item.mimeType -eq 'application/vnd.google-apps.folder') {
                $folders[$relative.ToLowerInvariant()] = [string]$item.id
                $queue.Enqueue([pscustomobject]@{ Id=[string]$item.id; Relative=$relative })
            } else { $files[$relative.ToLowerInvariant()] = [pscustomobject]@{ Relative=$relative; Item=$item; ParentId=[string]$current.Id } }
        }
    }
    return [pscustomobject]@{ Files=$files; Folders=$folders }
}

function New-SafeSyncGoogleFolder([string]$Token, [string]$Name, [string]$ParentId) {
    $body = @{ name=$Name; mimeType='application/vnd.google-apps.folder'; parents=@($ParentId) } | ConvertTo-Json -Depth 5 -Compress
    return Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Post -Uri 'https://www.googleapis.com/drive/v3/files?fields=id,name' -Headers @{Authorization="Bearer $activeToken"} -ContentType 'application/json; charset=UTF-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) }
}

function Ensure-SafeSyncGoogleFolderPath([string]$Token, [string]$RootId, [string]$RelativePath, [hashtable]$FolderMap) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $RootId }
    $parentId = $RootId
    $partial = ''
    foreach ($part in $RelativePath.Replace('\','/').Trim('/').Split('/')) {
        $partial = if ($partial) { "$partial/$part" } else { $part }
        $key = $partial.ToLowerInvariant()
        if ($FolderMap.ContainsKey($key)) { $parentId = [string]$FolderMap[$key] }
        else {
            $existing = @(Get-SafeSyncGoogleChildren $Token $parentId | Where-Object { [string]$_.name -eq $part -and [string]$_.mimeType -eq 'application/vnd.google-apps.folder' } | Select-Object -First 1)
            if ($existing.Count -gt 0) { $parentId = [string]$existing[0].id }
            else { $created = New-SafeSyncGoogleFolder $Token $part $parentId; $parentId = [string]$created.id }
            $FolderMap[$key] = $parentId
        }
    }
    return $parentId
}

function Get-SafeSyncGoogleSessionPath([string]$ResumeKey) {
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $name = [BitConverter]::ToString($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ResumeKey))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    return Join-Path (Join-Path $script:DataRoot 'upload-sessions') ($name + '.json')
}

function Wait-SafeSyncGoogleResumableUpload([System.IO.FileInfo]$File, [string]$Url, [long]$Offset, [object]$Job, [string]$RelativePath) {
    $operation = [SafeSyncGoogleTransfer]::BeginResume($File.FullName, $Url, $Offset)
    try {
        while (-not $operation.Completed) {
            if ($null -ne $Job) {
                $detail = '현재 파일 {0:N1} / {1:N1} MB 전송 중' -f ($operation.BytesSent / 1MB), ($File.Length / 1MB)
                if ($Offset -gt 0) { $detail += ' · 중단된 지점에서 이어 보내고 있습니다.' }
                Write-SafeSyncProgress -Job $Job -Stage 'Uploading to Google Drive staging' -Detail $detail -CurrentFile $RelativePath -CurrentFileSize $File.Length
            }
            Start-Sleep -Milliseconds 200
        }
        if ($null -ne $operation.Error) { throw $operation.Error }
        return $operation.Json | ConvertFrom-Json
    } finally { $operation.Dispose() }
}

function Send-SafeSyncGoogleFile([string]$Token, [System.IO.FileInfo]$File, [string]$ParentId, [string]$RemoteName, [string]$ResumeKey = '', [object]$Job = $null, [string]$RelativePath = '') {
    if ([string]::IsNullOrWhiteSpace($RemoteName)) { $RemoteName = $File.Name }
    $metadata = @{ name=$RemoteName; mimeType='application/octet-stream'; parents=@($ParentId); modifiedTime=$File.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } | ConvertTo-Json -Depth 5 -Compress
    if ($File.Length -le 5MB) {
        $endpoint = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,parents,modifiedTime,size,md5Checksum,sha256Checksum,version,trashed'
        $json = Invoke-SafeSyncGoogleRequest $Token { param($activeToken) [SafeSyncGoogleTransfer]::UploadFile($File.FullName, $metadata, $activeToken, $endpoint) }
        return $json | ConvertFrom-Json
    }
    $sessionPath = if ([string]::IsNullOrWhiteSpace($ResumeKey)) { '' } else { Get-SafeSyncGoogleSessionPath $ResumeKey }
    if ($sessionPath -and (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
        $savedSession = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([long]$savedSession.Length -eq $File.Length -and [string]$savedSession.ParentId -eq $ParentId -and ([datetime]::UtcNow - [datetime]::Parse([string]$savedSession.CreatedUtc).ToUniversalTime()).TotalDays -lt 7) {
            $savedUrl = Unprotect-SafeSyncSecret ([string]$savedSession.SessionUrlProtected)
            $savedUri = [Uri]$savedUrl
            if ($savedUri.Scheme -ne 'https' -or -not $savedUri.Host.EndsWith('.googleapis.com', [StringComparison]::OrdinalIgnoreCase)) { throw 'The saved Google Drive upload URL is invalid.' }
            $state = [SafeSyncGoogleTransfer]::QuerySession($savedUrl, $File.Length)
            if ($state.Complete) { return $state.Json | ConvertFrom-Json }
            if (-not $state.Expired) { return Wait-SafeSyncGoogleResumableUpload $File $savedUrl $state.Offset $Job $RelativePath }
        }
    }
    $session = Invoke-SafeSyncGoogleRequest $Token { param($activeToken)
        $headers = @{ Authorization="Bearer $activeToken"; 'X-Upload-Content-Type'='application/octet-stream'; 'X-Upload-Content-Length'=[string]$File.Length }
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name,modifiedTime,size,md5Checksum,sha256Checksum' -Headers $headers -ContentType 'application/json; charset=UTF-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($metadata))
    }
    $uploadUri = [string]$session.Headers['Location']
    if ([string]::IsNullOrWhiteSpace($uploadUri)) { throw 'Google Drive did not return a resumable upload URL.' }
    $parsedUri = [Uri]$uploadUri
    if ($parsedUri.Scheme -ne 'https' -or -not $parsedUri.Host.EndsWith('.googleapis.com', [StringComparison]::OrdinalIgnoreCase)) { throw 'Google Drive returned an invalid upload URL.' }
    if ($sessionPath) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($sessionPath))
        $record = [pscustomobject]@{Length=$File.Length;ParentId=$ParentId;CreatedUtc=[datetime]::UtcNow.ToString('o');SessionUrlProtected=(Protect-SafeSyncSecret $uploadUri)}
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))
        $stream = [System.IO.File]::Open("$sessionPath.tmp", 'Create', 'Write', 'None')
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-Item -LiteralPath "$sessionPath.tmp" -Destination $sessionPath -Force
    }
    return Wait-SafeSyncGoogleResumableUpload $File $uploadUri 0 $Job $RelativePath
}

function New-SafeSyncGoogleUploadPipeline([object]$Job, [object[]]$Files, [object]$Tree, [object]$Forced) {
    if ($null -eq $script:SafeSyncGoogleTokenContext) { return $null }
    $sourceRoot = [System.IO.Path]::GetFullPath([string]$Job.Source).TrimEnd('\')
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Files) {
        if ($file.Length -gt 5MB) { continue }
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\','/')
        $key = $relative.ToLowerInvariant()
        $copy = -not $Tree.Files.ContainsKey($key) -or $Forced.ContainsKey($relative)
        if (-not $copy) {
            try { $copy = $file.LastWriteTimeUtc -gt ([datetime]::Parse([string]$Tree.Files[$key].Item.modifiedTime).ToUniversalTime().AddSeconds(2)) } catch { continue }
        }
        if ($copy) { $candidates.Add([pscustomobject]@{File=$file;Relative=$relative;Key=$key}) }
    }
    if ($candidates.Count -eq 0) { return $null }
    $stageParent = Ensure-SafeSyncGoogleFolderPath (Get-SafeSyncGoogleActiveToken '') ([string]$Job.CloudFolderId) '.safesync-staging' $Tree.Folders
    $folder = Join-Path $script:DataRoot 'staging'
    [void][System.IO.Directory]::CreateDirectory($folder)
    # PowerShell 5.1 unwraps a one-element pipeline result into a scalar.  Keep
    # Candidates as a real array so the incremental one-file path can safely
    # use Count and indexing under StrictMode.
    return [pscustomobject]@{Candidates=[object[]]@($candidates.ToArray());Next=0;Active=@{};StageParent=$stageParent;Folder=$folder}
}

function Fill-SafeSyncGoogleUploadPipeline([object]$Pipeline) {
    if ($null -eq $Pipeline) { return }
    while ($Pipeline.Active.Count -lt 2 -and $Pipeline.Next -lt $Pipeline.Candidates.Count) {
        $candidate = $Pipeline.Candidates[$Pipeline.Next]
        $Pipeline.Next++
        $file = $candidate.File
        $staged = Join-Path $Pipeline.Folder ([guid]::NewGuid().ToString('N') + '.safesync-part')
        $name = $file.Name + '.safesync-part-' + [guid]::NewGuid().ToString('N')
        $metadata = @{name=$name;mimeType='application/octet-stream';parents=@([string]$Pipeline.StageParent);modifiedTime=$file.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')} | ConvertTo-Json -Depth 5 -Compress
        $endpoint = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,parents,modifiedTime,size,md5Checksum,sha256Checksum,version,trashed'
        $Pipeline.Active[[string]$candidate.Key] = [SafeSyncGoogleTransfer]::Begin($file.FullName, $staged, $file.Length, $file.LastWriteTimeUtc, $metadata, (Get-SafeSyncGoogleActiveToken ''), $endpoint)
    }
}

function Close-SafeSyncGoogleUploadPipeline([object]$Pipeline) {
    if ($null -eq $Pipeline) { return }
    foreach ($operation in @($Pipeline.Active.Values)) { $operation.Dispose() }
    $Pipeline.Active.Clear()
}

function Move-SafeSyncGoogleItem([string]$Token, [string]$FileId, [string]$OldParentId, [string]$NewParentId) {
    $query = ConvertTo-SafeSyncQuery @{ addParents=$NewParentId; removeParents=$OldParentId; fields='id,parents' }
    [void](Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Patch -Uri "https://www.googleapis.com/drive/v3/files/$FileId`?$query" -Headers @{Authorization="Bearer $activeToken"} -ContentType 'application/json' -Body '{}' })
}

function Rename-SafeSyncGoogleItem([string]$Token, [string]$FileId, [string]$NewName) {
    $body = @{name=$NewName} | ConvertTo-Json -Compress
    return Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Patch -Uri "https://www.googleapis.com/drive/v3/files/$FileId`?fields=id,name,parents,size,modifiedTime,version,trashed" -Headers @{Authorization="Bearer $activeToken"} -ContentType 'application/json; charset=UTF-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) }
}

function Get-SafeSyncDropboxMetadata([string]$Token, [string]$Path) {
    try { return Invoke-SafeSyncDropboxRpc $Token 'files/get_metadata' @{ path=$Path; include_deleted=$false } }
    catch {
        $details = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
        if (($_.Exception.Message + ' ' + $details) -match 'path/not_found|"\.tag"\s*:\s*"not_found"') { return $null }
        throw
    }
}

function Get-SafeSyncGoogleMetadata([string]$Token, [string]$FileId) {
    $query = ConvertTo-SafeSyncQuery @{ fields='id,name,parents,size,modifiedTime,createdTime,md5Checksum,sha256Checksum,version,trashed' }
    return Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Get -Uri "https://www.googleapis.com/drive/v3/files/$FileId`?$query" -Headers @{Authorization="Bearer $activeToken"} }
}

function Get-SafeSyncGoogleMetadataOrNull([string]$Token, [string]$FileId) {
    try { return Get-SafeSyncGoogleMetadata $Token $FileId }
    catch {
        $details = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
        if (($_.Exception.Message + ' ' + $details) -match '404|notFound|File not found') { return $null }
        throw
    }
}

function Get-SafeSyncGoogleMetadataBatch([string]$Token, [object[]]$Requests, [object]$Job = $null) {
    $results = @{}
    $all = @($Requests)
    if ($all.Count -eq 0) { return $results }
    $fields = [Uri]::EscapeDataString('id,name,parents,size,modifiedTime,createdTime,md5Checksum,sha256Checksum,version,trashed')
    $batchSize = 100
    for ($offset = 0; $offset -lt $all.Count; $offset += $batchSize) {
        $last = [Math]::Min($offset + $batchSize - 1, $all.Count - 1)
        $chunk = @($all[$offset..$last])
        if ($null -ne $Job -and $null -ne (Get-Command Write-SafeSyncProgress -ErrorAction SilentlyContinue)) {
            Write-SafeSyncProgress -Job $Job -Stage 'Preparing changed Google Drive files' -Detail '변경된 파일의 Google Drive 정보를 묶음으로 확인하고 있습니다.' -CompletedFiles $offset -TotalFiles $all.Count
        }
        $boundary = 'batch_' + [guid]::NewGuid().ToString('N')
        $builder = New-Object System.Text.StringBuilder
        for ($index = 0; $index -lt $chunk.Count; $index++) {
            $fileId = [Uri]::EscapeDataString([string]$chunk[$index].RemoteId)
            [void]$builder.Append("--$boundary`r`n")
            [void]$builder.Append("Content-Type: application/http`r`n")
            [void]$builder.Append("Content-ID: item-$index`r`n`r`n")
            [void]$builder.Append("GET /drive/v3/files/$fileId`?fields=$fields HTTP/1.1`r`n")
            [void]$builder.Append("Accept: application/json`r`n`r`n")
        }
        [void]$builder.Append("--$boundary--`r`n")
        $payload = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
        $response = Invoke-SafeSyncGoogleRequest $Token { param($activeToken)
            Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://www.googleapis.com/batch/drive/v3' -Headers @{Authorization="Bearer $activeToken"} -ContentType "multipart/mixed; boundary=$boundary" -Body $payload
        }
        $contentType = [string]$response.Headers['Content-Type']
        if ($contentType -notmatch 'boundary="?([^";]+)') { throw 'Google Drive batch response did not include a boundary.' }
        $responseBoundary = $matches[1]
        $content = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        $parts = [regex]::Split($content, "(?m)^--$([regex]::Escape($responseBoundary.Trim()))(?:--)?[ \t]*\r?$" )
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($part in @($parts)) {
            # Google prefixes the supplied ID with response-. Depending on the
            # server, the angle brackets can enclose the whole ID or its suffix.
            if ($part -notmatch '(?im)^Content-ID:[ \t]*(?:<)?(?:response-)?(?:<)?item-(\d+)(?:>)?[ \t]*\r?$') { continue }
            $index = [int]$matches[1]
            if ($index -lt 0 -or $index -ge $chunk.Count) { continue }
            if ($part -notmatch '(?im)HTTP/\d(?:\.\d)?\s+(\d{3})') { throw 'Google Drive batch item did not include an HTTP status.' }
            $status = [int]$matches[1]
            $request = $chunk[$index]
            if (-not $seen.Add($index)) { throw 'Google Drive batch response contained a duplicate item ID.' }
            if ($status -eq 404) { $results[[string]$request.Key] = $null; continue }
            if ($status -eq 401) { throw 'Google Drive metadata batch returned 401 Unauthorized.' }
            if ($status -lt 200 -or $status -ge 300) { throw "Google Drive metadata batch item failed with HTTP $status." }
            $httpIndex = $part.IndexOf('HTTP/')
            $bodyIndex = $part.IndexOf("`r`n`r`n", $httpIndex)
            $separatorLength = 4
            if ($bodyIndex -lt 0) { $bodyIndex = $part.IndexOf("`n`n", $httpIndex); $separatorLength = 2 }
            if ($bodyIndex -lt 0) { throw 'Google Drive batch item did not include a response body.' }
            $json = $part.Substring($bodyIndex + $separatorLength).Trim()
            $results[[string]$request.Key] = $json | ConvertFrom-Json
        }
        foreach ($index in 0..($chunk.Count - 1)) {
            # A parser/network anomaly must never make an existing backup look
            # missing. Recheck only unmatched IDs individually before proceeding.
            if (-not $seen.Contains($index)) { $results[[string]$chunk[$index].Key] = Get-SafeSyncGoogleMetadataOrNull $Token ([string]$chunk[$index].RemoteId) }
        }
    }
    if ($null -ne $Job -and $null -ne (Get-Command Write-SafeSyncProgress -ErrorAction SilentlyContinue)) {
        Write-SafeSyncProgress -Job $Job -Stage 'Preparing changed Google Drive files' -Detail '변경된 파일의 Google Drive 정보를 묶음으로 확인했습니다.' -CompletedFiles $all.Count -TotalFiles $all.Count -Force
    }
    return $results
}

function Assert-SafeSyncCloudContent([object]$Metadata, [object]$Record) {
    if ($null -eq $Metadata -or $null -eq $Metadata.PSObject.Properties['size'] -or [long]$Metadata.size -ne [long]$Record.Length) {
        throw 'Cloud verification failed: uploaded file size is missing or differs. The previous backup was preserved.'
    }
    $property = $Metadata.PSObject.Properties[[string]$Record.HashField]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value) -or [string]$property.Value -ne [string]$Record.Hash) {
        throw 'Cloud verification failed: uploaded content checksum is missing or differs. The previous backup was preserved.'
    }
}

function Save-SafeSyncCloudCheckpoint([object]$State, [string[]]$CompletedPaths, [object]$Pending) {
    if ($null -eq $State.PSObject.Properties['CheckpointSegmentCount']) { $State | Add-Member -NotePropertyName CheckpointSegmentCount -NotePropertyValue 0 }
    if ($State.CheckpointSegmentCount -ge 100 -or $null -eq (Get-Command Save-SafeSyncCheckpoint -ErrorAction SilentlyContinue)) {
        $State.PendingPaths = @($Pending.Values)
        Save-SafeSyncState $State
        $State.CheckpointSegmentCount = 0
    } else {
        Save-SafeSyncCheckpoint $State $CompletedPaths
        $State.CheckpointSegmentCount++
    }
}

function Restore-SafeSyncDropboxTransaction([string]$Token, [object]$Record) {
    $uploaded = Get-SafeSyncDropboxMetadata $Token ([string]$Record.UploadedId)
    if ($null -ne $uploaded -and [string]$uploaded.path_display -ieq [string]$Record.Target) {
        try { Assert-SafeSyncCloudContent $uploaded $Record; return $true }
        catch {
            # Only move our own uploaded ID. Preserve the rejected data in staging.
            Move-SafeSyncDropboxItem $Token ([string]$Record.UploadedId) ([string]$Record.StagePath) $false
        }
    }
    $current = Get-SafeSyncDropboxMetadata $Token ([string]$Record.Target)
    if ([string]::IsNullOrWhiteSpace([string]$Record.PreviousId)) {
        if ($null -ne $current) { throw 'The target path changed during upload. Review the pending transfer.' }
        return $false
    }
    $previous = Get-SafeSyncDropboxMetadata $Token ([string]$Record.PreviousId)
    if ($null -eq $previous) { throw 'The previous Dropbox backup cannot be located. Recovery remains pending.' }
    if ($null -eq $current) {
        if ([string]$previous.path_display -ine [string]$Record.TrashPath) { throw 'The previous Dropbox backup moved unexpectedly. Recovery needs review.' }
        Move-SafeSyncDropboxItem $Token ([string]$previous.id) ([string]$Record.Target) $false
        $current = Get-SafeSyncDropboxMetadata $Token ([string]$Record.Target)
    }
    if ($null -eq $current -or [string]$current.id -ne [string]$Record.PreviousId) { throw 'The Dropbox target is occupied by another file. Recovery remains pending.' }
    return $false
}

function Restore-SafeSyncGoogleTransaction([string]$Token, [object]$Record) {
    $uploaded = Get-SafeSyncGoogleMetadata $Token ([string]$Record.UploadedId)
    if ([bool]$uploaded.trashed) { throw 'The staged Google Drive file was removed. Recovery needs review.' }
    if ([string]$uploaded.name -eq [string]$Record.TargetName -and @($uploaded.parents) -contains [string]$Record.TargetParent) {
        try { Assert-SafeSyncCloudContent $uploaded $Record }
        catch {
            Move-SafeSyncGoogleItem $Token ([string]$Record.UploadedId) ([string]$Record.TargetParent) ([string]$Record.StageParent)
            if ($Record.PreviousId) {
                $previous = Get-SafeSyncGoogleMetadata $Token ([string]$Record.PreviousId)
                if (@($previous.parents) -contains [string]$Record.TrashParent) {
                    Move-SafeSyncGoogleItem $Token ([string]$Record.PreviousId) ([string]$Record.TrashParent) ([string]$Record.TargetParent)
                }
            }
            return $false
        }
        if ($Record.PreviousId) {
            $previous = Get-SafeSyncGoogleMetadata $Token ([string]$Record.PreviousId)
            if (@($previous.parents) -contains [string]$Record.TargetParent) {
                if ([string]$previous.version -ne [string]$Record.PreviousVersion) { throw 'The previous Google Drive file was edited during transfer. Both copies were preserved for review.' }
                Move-SafeSyncGoogleItem $Token ([string]$Record.PreviousId) ([string]$Record.TargetParent) ([string]$Record.TrashParent)
                $previous = Get-SafeSyncGoogleMetadata $Token ([string]$Record.PreviousId)
            }
            if (-not (@($previous.parents) -contains [string]$Record.TrashParent)) { throw 'Previous Google Drive backup is not yet in SafeSync trash. Recovery remains pending.' }
        }
        return $true
    }
    if (-not (@($uploaded.parents) -contains [string]$Record.StageParent)) { throw 'Staged Google Drive file moved unexpectedly. Recovery needs review.' }
    return $false
}

function Repair-SafeSyncCloudTransactions([string]$Provider, [string]$Token, [object]$Job) {
    $folder = Join-Path $script:DataRoot 'transactions'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
    foreach ($journal in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File)) {
        $record = Get-Content -LiteralPath $journal.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$record.Provider -ne $Provider -or [string]$record.JobId -ne [string]$Job.Id) { continue }
        if ([string]$record.Root -ne [string]$Job.CloudFolderId) { throw 'A pending transfer belongs to the previous backup folder. Restore that job folder before continuing.' }
        if ($Provider -eq 'Dropbox') { [void](Restore-SafeSyncDropboxTransaction $Token $record) }
        else { [void](Restore-SafeSyncGoogleTransaction $Token $record) }
        Remove-Item -LiteralPath $journal.FullName -Force
    }
}

function Publish-SafeSyncDropboxFile([string]$Token, [System.IO.FileInfo]$File, [string]$RemotePath, [object]$Previous, [object]$Job) {
    $relativeProgressPath = $RemotePath
    $rootPrefixForProgress = ([string]$Job.CloudFolderId).TrimEnd('/')
    if (-not [string]::IsNullOrWhiteSpace($rootPrefixForProgress) -and $relativeProgressPath.StartsWith($rootPrefixForProgress, [StringComparison]::OrdinalIgnoreCase)) { $relativeProgressPath = $relativeProgressPath.Substring($rootPrefixForProgress.Length).TrimStart('/') }
    Write-SafeSyncProgress -Job $Job -Stage 'Preparing Dropbox upload' -CurrentFolder ([string][System.IO.Path]::GetDirectoryName($relativeProgressPath)) -CurrentFile $relativeProgressPath -CurrentFileSize $File.Length -Force
    $snapshot = New-SafeSyncSnapshot $File ''
    $journal = Get-SafeSyncCloudTransactionPath
    try {
        # Windows PowerShell opens -InFile uploads with an exclusive handle.  The
        # private snapshot is already immutable from the source and each upload is
        # verified against its saved checksum, so a second holding handle is both
        # unnecessary and incompatible with the transport.
        $hash = [SafeSyncFileIntegrity]::DropboxHash([string]$snapshot.Path)
        $stagePath = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) ('.safesync-staging/' + [guid]::NewGuid().ToString('N'))
        Ensure-SafeSyncDropboxFolder $Token ($stagePath.Substring(0, $stagePath.LastIndexOf('/')))
        Write-SafeSyncProgress -Job $Job -Stage 'Uploading to Dropbox staging' -CurrentFile $relativeProgressPath -CurrentFileSize $File.Length -Force
        $uploaded = Send-SafeSyncDropboxFile $Token (Get-Item -LiteralPath $snapshot.Path) $stagePath
        $record = [pscustomobject]@{
            Provider='Dropbox'; JobId=[string]$Job.Id; Root=[string]$Job.CloudFolderId
            UploadedId=[string]$uploaded.id; Target=$RemotePath; StagePath=$stagePath; Hash=$hash; HashField='content_hash'; Length=$snapshot.Length
            PreviousId=''; TrashPath=''
        }
        Write-SafeSyncProgress -Job $Job -Stage 'Verifying Dropbox upload' -CurrentFile $relativeProgressPath -CurrentFileSize $File.Length -Force
        Assert-SafeSyncCloudContent $uploaded $record
        Assert-SafeSyncCloudContent (Get-SafeSyncDropboxMetadata $Token ([string]$uploaded.id)) $record
        if ($null -ne $Previous) {
            $current = Get-SafeSyncDropboxMetadata $Token $RemotePath
            if ($null -eq $current -or [string]$current.id -ne [string]$Previous.id -or [string]$current.rev -ne [string]$Previous.rev) {
                throw 'The Dropbox backup changed during transfer. The existing backup was preserved.'
            }
            $record.PreviousId = [string]$current.id
            $rootPrefix = ([string]$Job.CloudFolderId).TrimEnd('/')
            $relativePath = $RemotePath.Substring($rootPrefix.Length).TrimStart('/')
            $record.TrashPath = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) ('.safesync-trash/' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-replaced-' + [guid]::NewGuid().ToString('N') + '/' + $relativePath)
        }
        Write-SafeSyncProgress -Job $Job -Stage 'Publishing Dropbox file' -CurrentFile $relativeProgressPath -CurrentFileSize $File.Length -Force
        Write-SafeSyncTransaction $journal $record
        if ($record.PreviousId) { Move-SafeSyncDropboxItem $Token $record.PreviousId $record.TrashPath $false }
        Move-SafeSyncDropboxItem $Token ([string]$uploaded.id) $RemotePath $false
        if (-not (Restore-SafeSyncDropboxTransaction $Token $record)) { throw 'Dropbox publish did not finish.' }
        Remove-Item -LiteralPath $journal -Force
        return Get-SafeSyncDropboxMetadata $Token $RemotePath
    }
    catch {
        $failure = $_
        if (Test-Path -LiteralPath $journal) {
            try {
                $committed = Restore-SafeSyncDropboxTransaction $Token $record
                Remove-Item -LiteralPath $journal -Force
                if ($committed) { return Get-SafeSyncDropboxMetadata $Token $RemotePath }
            } catch { throw "$($failure.Exception.Message) Recovery pending: $($_.Exception.Message)" }
        }
        throw $failure
    }
    finally {
        Remove-Item -LiteralPath $snapshot.Path -Force -ErrorAction SilentlyContinue
    }
}

function Publish-SafeSyncGoogleFile([string]$Token, [System.IO.FileInfo]$File, [string]$ParentId, [object]$Previous, [object]$Job, [hashtable]$FolderMap, [string]$RelativePath = '', [object]$PreparedUpload = $null) {
    $progressFolder=if([string]::IsNullOrWhiteSpace($RelativePath)){''}else{[string][System.IO.Path]::GetDirectoryName($RelativePath)}
    Write-SafeSyncProgress -Job $Job -Stage 'Preparing Google Drive upload' -CurrentFolder $progressFolder -CurrentFile $RelativePath -CurrentFileSize $File.Length -Force
    $snapshot = $null
    if ($null -ne $PreparedUpload) {
        while (-not $PreparedUpload.Completed) {
            $stage = if ($PreparedUpload.Stage -eq 'Preparing') { 'Preparing Google Drive upload' } else { 'Uploading to Google Drive staging' }
            $detail = if ($PreparedUpload.Stage -eq 'Preparing') { '전송할 안전한 사본을 준비하고 있습니다.' } else { '작은 파일을 최대 2개씩 동시에 전송합니다. 현재 파일 {0:N1} / {1:N1} MB 전송' -f ($PreparedUpload.BytesSent / 1MB), ($File.Length / 1MB) }
            Write-SafeSyncProgress -Job $Job -Stage $stage -Detail $detail -CurrentFile $RelativePath -CurrentFileSize $File.Length
            Start-Sleep -Milliseconds 200
        }
        if ($null -ne $PreparedUpload.Error -and $PreparedUpload.Error.Message -notmatch '(^|\D)401(\D|$)|Unauthorized') { throw $PreparedUpload.Error }
        if ($null -eq $PreparedUpload.Error) { $snapshot = $PreparedUpload.Snapshot }
    }
    if ($null -eq $snapshot) { $snapshot = New-SafeSyncSnapshot $File '' }
    $resumeKey = "$([string]$Job.Id)|$([string]$Job.CloudFolderId)|$RelativePath|$($snapshot.Sha256)"
    $publishedSuccessfully = $false
    $journal = Get-SafeSyncCloudTransactionPath
    try {
        # See Dropbox above.  SafeSync validates the completed Drive object against
        # this snapshot checksum before publishing, without blocking -InFile.
        $hash = [string]$snapshot.Sha256
        $stageParent = Ensure-SafeSyncGoogleFolderPath $Token ([string]$Job.CloudFolderId) '.safesync-staging' $FolderMap
        $stageName = $File.Name + '.safesync-part-' + [guid]::NewGuid().ToString('N')
        Write-SafeSyncProgress -Job $Job -Stage 'Uploading to Google Drive staging' -CurrentFile $RelativePath -CurrentFileSize $File.Length -Force
        $uploaded = if ($null -ne $PreparedUpload -and $null -eq $PreparedUpload.Error) { $PreparedUpload.Json | ConvertFrom-Json } else { Send-SafeSyncGoogleFile $Token (Get-Item -LiteralPath $snapshot.Path) $stageParent $stageName $resumeKey $Job $RelativePath }
        $record = [pscustomobject]@{
            Provider='GoogleDrive'; JobId=[string]$Job.Id; Root=[string]$Job.CloudFolderId
            UploadedId=[string]$uploaded.id; TargetName=$File.Name; TargetParent=$ParentId; StageParent=$stageParent
            Hash=$hash; HashField='sha256Checksum'; Length=$snapshot.Length
            PreviousId=''; PreviousVersion=''; TrashParent=''
        }
        # SHA-256 may be unavailable on Drive; binary uploads always support MD5.
        $fresh = Get-SafeSyncGoogleMetadata $Token ([string]$uploaded.id)
        if ($null -eq $fresh.PSObject.Properties['sha256Checksum'] -or [string]::IsNullOrWhiteSpace([string]$fresh.sha256Checksum)) {
            $record.Hash = [SafeSyncFileIntegrity]::Hash([string]$snapshot.Path, 'MD5')
            $record.HashField = 'md5Checksum'
        }
        Write-SafeSyncProgress -Job $Job -Stage 'Verifying Google Drive upload' -CurrentFile $RelativePath -CurrentFileSize $File.Length -Force
        Assert-SafeSyncCloudContent $fresh $record
        if ($null -ne $Previous) {
            $current = Get-SafeSyncGoogleMetadata $Token ([string]$Previous.id)
            if ([string]$current.version -ne [string]$Previous.version -or -not (@($current.parents) -contains $ParentId)) {
                throw 'The Google Drive backup changed during transfer. Both copies were preserved.'
            }
            $record.PreviousId = [string]$current.id
            $record.PreviousVersion = [string]$current.version
            $trashRelative = '.safesync-trash/' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-replaced-' + [guid]::NewGuid().ToString('N')
            $originalParent = if ($RelativePath) { [string][System.IO.Path]::GetDirectoryName($RelativePath) } else { '' }
            if ($originalParent) { $trashRelative += '/' + $originalParent.Replace('\','/') }
            $record.TrashParent = Ensure-SafeSyncGoogleFolderPath $Token ([string]$Job.CloudFolderId) $trashRelative $FolderMap
        }
        Write-SafeSyncProgress -Job $Job -Stage 'Publishing Google Drive file' -CurrentFile $RelativePath -CurrentFileSize $File.Length -Force
        Write-SafeSyncTransaction $journal $record
        # Publish the verified new ID first. The old ID stays live until this is confirmed.
        $query = ConvertTo-SafeSyncQuery @{ addParents=$ParentId; removeParents=$stageParent; fields='id,name,parents,size,md5Checksum,sha256Checksum' }
        $body = @{ name=$File.Name; modifiedTime=$snapshot.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } | ConvertTo-Json -Compress
        $publishUri = "https://www.googleapis.com/drive/v3/files/$($uploaded.id)`?$query"
        [void](Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Patch -Uri $publishUri -Headers @{Authorization="Bearer $activeToken"} -ContentType 'application/json; charset=UTF-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) })
        if (-not (Restore-SafeSyncGoogleTransaction $Token $record)) { throw 'Google Drive publish did not finish.' }
        Remove-Item -LiteralPath $journal -Force
        $publishedSuccessfully = $true
        return Get-SafeSyncGoogleMetadata $Token ([string]$uploaded.id)
    }
    catch {
        $failure = $_
        if (Test-Path -LiteralPath $journal) {
            try {
                $committed = Restore-SafeSyncGoogleTransaction $Token $record
                Remove-Item -LiteralPath $journal -Force
                if ($committed) { $publishedSuccessfully = $true; return Get-SafeSyncGoogleMetadata $Token ([string]$record.UploadedId) }
            } catch { throw "$($failure.Exception.Message) Recovery pending: $($_.Exception.Message)" }
        }
        throw $failure
    }
    finally {
        Remove-Item -LiteralPath $snapshot.Path -Force -ErrorAction SilentlyContinue
        if ($publishedSuccessfully) { Remove-Item -LiteralPath (Get-SafeSyncGoogleSessionPath $resumeKey) -Force -ErrorAction SilentlyContinue }
    }
}

function New-SafeSyncCloudResult([object]$Job) {
    return [ordered]@{ JobId=[string]$Job.Id; JobName=[string]$Job.Name; StartedAt=(Get-Date).ToString('o'); FinishedAt=$null; Status='Running'; Copied=0; Skipped=0; Trashed=0; RenamedBackups=0; ExpiredTrashRemoved=0; Conflicts=@(); Errors=@(); LockedFiles=@(); ScanMode='' }
}

function Add-SafeSyncCloudConflict([System.Collections.IDictionary]$Result, [string]$Relative, [string]$Reason, [long]$SourceSize, [long]$RemoteSize, [datetime]$SourceModified, [datetime]$RemoteModified) {
    $Result.Conflicts += [pscustomobject]@{ File=$Relative; Reason=$Reason; SourceSize=$SourceSize; BackupSize=$RemoteSize; SourceModified=$SourceModified.ToString('yyyy-MM-dd HH:mm:ss'); BackupModified=$RemoteModified.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
}

function Complete-SafeSyncCloudResult([System.Collections.IDictionary]$Result) {
    if (@($Result.Errors).Count -gt 0) { $Result.Status='CompletedWithErrors' }
    elseif (@($Result.Conflicts).Count -gt 0) { $Result.Status='CompletedWithConflicts' }
    elseif (@($Result.LockedFiles).Count -gt 0) { $Result.Status='CompletedWithLockedFiles' }
    else { $Result.Status='Completed' }
    $Result.FinishedAt=(Get-Date).ToString('o')
    return [pscustomobject]$Result
}

function Get-SafeSyncCloudSourceFiles([object]$Job,[string]$SourceRoot,[string]$Stage) {
    if($null -ne (Get-Command Get-SafeSyncFilesWithProgress -ErrorAction SilentlyContinue)){
        return @(Get-SafeSyncFilesWithProgress -Job $Job -Root $SourceRoot -Stage $Stage)
    }
    return @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force -ErrorAction Stop | Where-Object { -not (Test-SafeSyncInternalPath $_.FullName) })
}

function Invoke-SafeSyncDropboxBackup([object]$Job, [object]$Config, [int]$TrashRetentionDays, [switch]$ForceFull, [string[]]$ForceOverwritePaths=@(), [string[]]$RenameExistingPaths=@()) {
    $result = New-SafeSyncCloudResult $Job
    $plan = $null
    try {
        $sourceRoot = [System.IO.Path]::GetFullPath([string]$Job.Source).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Source is unavailable: $sourceRoot" }
        $root = [string]$Job.CloudFolderId
        Write-SafeSyncProgress -Job $Job -Stage 'Connecting to Dropbox' -CurrentFolder $root -Force
        $token = Get-SafeSyncCloudAccessToken 'Dropbox' $Config
        Write-SafeSyncProgress -Job $Job -Stage 'Checking Dropbox recovery' -CurrentFolder $root -Force
        Repair-SafeSyncCloudTransactions 'Dropbox' $token $Job
        $stateEnabled = $null -ne (Get-Command Get-SafeSyncBackupPlan -ErrorAction SilentlyContinue)
        $plan = if ($stateEnabled) { Get-SafeSyncBackupPlan -Job $Job -SourceRoot $sourceRoot -ForceFull:$ForceFull } else { [pscustomobject]@{State=$null;FullScan=$true;Paths=@()} }
        $forced = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($forcedPath in @($ForceOverwritePaths)){$normalized=ConvertTo-SafeSyncRelativePath ([string]$forcedPath);if(-not [string]::IsNullOrWhiteSpace($normalized)){$forced[$normalized]=$normalized}}
        $renameExisting = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($renamePath in @($RenameExistingPaths)){$normalized=ConvertTo-SafeSyncRelativePath ([string]$renamePath);if(-not [string]::IsNullOrWhiteSpace($normalized)){$renameExisting[$normalized]=$normalized;$forced[$normalized]=$normalized}}
        $requestedPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @($plan.Paths)){$requestedPaths[[string]$path]=[string]$path}
        foreach($path in @($forced.Values)){$requestedPaths[[string]$path]=[string]$path}
        $nextDropboxCursor = if ($stateEnabled) { [string]$plan.State.DropboxCursor } else { '' }
        if ($plan.FullScan -or ($stateEnabled -and [bool]$plan.State.CheckpointFullScan)) {
            try { $nextDropboxCursor = Get-SafeSyncDropboxLatestCursor $token $root } catch { $nextDropboxCursor = '' }
        }
        elseif ($stateEnabled -and -not [string]::IsNullOrWhiteSpace($nextDropboxCursor)) {
            try {
                Write-SafeSyncProgress -Job $Job -Stage 'Reading Dropbox change feed' -Detail '마지막 확인 이후 바뀐 클라우드 항목만 불러옵니다.' -CurrentFolder $root -Force
                $delta = Get-SafeSyncDropboxChanges $token $nextDropboxCursor
                $remoteIds = @{}
                foreach ($saved in @($plan.State.Entries.Values)) {
                    if ($null -ne $saved.PSObject.Properties['RemoteId'] -and -not [string]::IsNullOrWhiteSpace([string]$saved.RemoteId)) { $remoteIds[[string]$saved.RemoteId] = [string]$saved.RelativePath }
                }
                foreach ($entry in @($delta.Entries)) {
                    $pathValue = if ($null -ne $entry.PSObject.Properties['path_display']) { [string]$entry.path_display } else { '' }
                    if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
                    $rootLength = if ($root -eq '/') { 0 } else { $root.Length }
                    if ($rootLength -gt 0 -and -not $pathValue.StartsWith($root.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $relative = $pathValue.Substring($rootLength).TrimStart('/')
                    if (Test-SafeSyncInternalPath $relative) { continue }
                    $entryId = if ($null -ne $entry.PSObject.Properties['id']) { [string]$entry.id } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($entryId) -and $remoteIds.ContainsKey($entryId)) { $relative = [string]$remoteIds[$entryId] }
                    if (-not [string]::IsNullOrWhiteSpace($relative)) { $requestedPaths[$relative] = $relative }
                }
                $nextDropboxCursor = [string]$delta.Cursor
                # Checkpoint the provider cursor as soon as the change feed has been
                # read.  A restart during metadata lookup or file transfer must not
                # replay the whole feed from the old cursor.  The requested paths are
                # kept as pending work, so advancing the cursor cannot lose changes.
                if ($stateEnabled -and -not [string]::IsNullOrWhiteSpace($nextDropboxCursor)) {
                    $checkpointPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
                    foreach ($pending in @($plan.State.PendingPaths)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$pending); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPaths[$normalized] = $normalized } }
                    foreach ($requested in @($requestedPaths.Values)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$requested); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPaths[$normalized] = $normalized } }
                    $plan.State.PendingPaths = @($checkpointPaths.Values)
                    $plan.State.DropboxCursor = $nextDropboxCursor
                    Save-SafeSyncState $plan.State
                }
            }
            catch {
                Write-SafeSyncProgress -Job $Job -Stage 'Dropbox change feed reset' -Detail '변경 커서를 이어갈 수 없어 이번 한 번 전체 검사를 실행합니다.' -CurrentFolder $root -Force
                $plan.FullScan = $true
                try { $nextDropboxCursor = Get-SafeSyncDropboxLatestCursor $token $root } catch { $nextDropboxCursor = '' }
            }
        }
        elseif ($stateEnabled) {
            try { $nextDropboxCursor = Get-SafeSyncDropboxLatestCursor $token $root } catch { $nextDropboxCursor = '' }
        }
        $result.ScanMode = if ($plan.FullScan) { 'Full' } else { 'Incremental' }
        Write-SafeSyncProgress -Job $Job -Stage $(if($plan.FullScan){'Scanning Dropbox files'}else{'Preparing changed Dropbox files'}) -CurrentFolder $root -Force
        $remote = @{}
        if ($plan.FullScan -or ($stateEnabled -and [bool]$plan.State.CheckpointFullScan)) {
            foreach ($entry in @(Get-SafeSyncDropboxEntries $token $root $true)) {
                $tag = [string]$entry.PSObject.Properties['.tag'].Value
                if ($tag -ne 'file') { continue }
                $full = [string]$entry.path_display
                $rootLength = if ($root -eq '/') { 0 } else { $root.Length }
                $relative = $full.Substring($rootLength).TrimStart('/')
                if (Test-SafeSyncInternalPath $relative) { continue }
                $remote[$relative.ToLowerInvariant()] = [pscustomobject]@{ Relative=$relative; Item=$entry }
            }
        } else {
            foreach ($relative in @($requestedPaths.Values)) {
                $remotePath = Join-SafeSyncDropboxPath $root ([string]$relative)
                $entry = Get-SafeSyncDropboxMetadata $token $remotePath
                if ($null -ne $entry) { $remote[([string]$relative).ToLowerInvariant()] = [pscustomobject]@{Relative=[string]$relative;Item=$entry} }
            }
        }
        $sourceMap = @{}
        Write-SafeSyncProgress -Job $Job -Stage 'Scanning source for Dropbox' -CurrentFolder $sourceRoot -Force
        $sourceFiles = @(if ($plan.FullScan) { @(Get-SafeSyncCloudSourceFiles -Job $Job -SourceRoot $sourceRoot -Stage 'Scanning source for Dropbox') } else {
            @($requestedPaths.Values | ForEach-Object { $candidate=Join-Path $sourceRoot ([string]$_).Replace('/','\'); if(Test-Path -LiteralPath $candidate -PathType Leaf){Get-Item -LiteralPath $candidate -Force} })
        })
        $checkpointPending = $null
        if ($stateEnabled) {
            $checkpointPending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
            # Keep paths whose source file has disappeared as pending too. They
            # still need the mirror-delete decision; dropping them here would
            # make a restart after the token checkpoint forget that decision.
            foreach ($requested in @($requestedPaths.Values)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$requested); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPending[$normalized] = $normalized } }
            foreach ($pendingFile in @($sourceFiles)) {
                $pendingRelative = $pendingFile.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\','/')
                $checkpointPending[$pendingRelative] = $pendingRelative
            }
            $plan.State.PendingPaths = @($checkpointPending.Values)
            $plan.State.CheckpointActive = $true
            $plan.State.CheckpointFullScan = [bool]$plan.FullScan
            Save-SafeSyncState $plan.State
        }
        $progressIndex = 0
        $completedCheckpointPaths = New-Object System.Collections.Generic.List[string]
        foreach ($file in $sourceFiles) {
            $progressIndex++
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\','/')
            $currentFolder=[string][System.IO.Path]::GetDirectoryName($relative);if([string]::IsNullOrWhiteSpace($currentFolder)){$currentFolder='(root)'}
            Write-SafeSyncProgress -Job $Job -Stage 'Comparing Dropbox files' -CurrentFolder $currentFolder -CurrentFile $relative -CurrentFileSize $file.Length -CompletedFiles ($progressIndex - 1) -TotalFiles $sourceFiles.Count
            $key = $relative.ToLowerInvariant(); $sourceMap[$key]=$true
            try {
                $remotePath = Join-SafeSyncDropboxPath $root $relative
                $parent = $remotePath.Substring(0,$remotePath.LastIndexOf('/'))
                Ensure-SafeSyncDropboxFolder $token $parent
                if (-not $remote.ContainsKey($key)) { $published=Publish-SafeSyncDropboxFile $token $file $remotePath $null $Job; $result.Copied++; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id)}; continue }
                $item = $remote[$key].Item
                $remoteModified = [datetime]::Parse([string]$item.client_modified).ToUniversalTime()
                [long]$remoteSize = [long]$item.size
                $sameModified = [Math]::Abs(($file.LastWriteTimeUtc-$remoteModified).TotalSeconds) -le 2
                if ($forced.ContainsKey($relative)) {
                    $renamedPath = ''
                    if ($renameExisting.ContainsKey($relative)) {
                        $current = Get-SafeSyncDropboxMetadata $token $remotePath
                        if ($null -eq $current -or [string]$current.id -ne [string]$item.id -or [string]$current.rev -ne [string]$item.rev) { throw 'The Dropbox backup changed before conflict handling. Nothing was overwritten.' }
                        $renamedPath = Get-SafeSyncDropboxConflictPath $remotePath
                        Move-SafeSyncDropboxItem $token ([string]$current.id) $renamedPath $false
                    }
                    try { $published=Publish-SafeSyncDropboxFile $token $file $remotePath $null $Job }
                    catch {
                        if (-not [string]::IsNullOrWhiteSpace($renamedPath) -and $null -eq (Get-SafeSyncDropboxMetadata $token $remotePath)) { try { Move-SafeSyncDropboxItem $token $renamedPath $remotePath $false } catch {} }
                        throw
                    }
                    $result.Copied++; if(-not [string]::IsNullOrWhiteSpace($renamedPath)){$result.RenamedBackups++}; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id)}; continue
                }
                if ($sameModified -and $file.Length -eq $remoteSize) { $result.Skipped++; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$item.id)}; continue }
                if ($file.LastWriteTimeUtc -gt $remoteModified.AddSeconds(2)) {
                    $published=Publish-SafeSyncDropboxFile $token $file $remotePath $item $Job; $result.Copied++; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id)}; continue
                }
                if ($sameModified -and $file.Length -ne $remoteSize) { Add-SafeSyncCloudConflict $result $relative 'Modified time matches but cloud file size differs.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                elseif ($remoteModified -gt $file.LastWriteTimeUtc.AddSeconds(2)) { Add-SafeSyncCloudConflict $result $relative 'Cloud file is newer than the source.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                else { Add-SafeSyncCloudConflict $result $relative 'Source and cloud file metadata differs.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Conflict -RemoteId ([string]$item.id)}
             } catch {
                 if (Test-SafeSyncFileInUseError $_) { Add-SafeSyncLockedFile $result $relative $_; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Locked -ErrorMessage $_.Exception.Message} }
                 else { $result.Errors += "$relative : $($_.Exception.Message)"; if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Failed -ErrorMessage $_.Exception.Message} }
             }
             finally {
                 if ($stateEnabled) {
                     [void]$checkpointPending.Remove([string]$relative)
                     $completedCheckpointPaths.Add([string]$relative)
                     if (($progressIndex % 5) -eq 0 -or $checkpointPending.Count -eq 0) { Save-SafeSyncCloudCheckpoint $plan.State $completedCheckpointPaths.ToArray() $checkpointPending; $completedCheckpointPaths.Clear() }
                 }
             }
        }
        $deleteKeys = @()
        if ([bool]$Job.MirrorDeletes) { $deleteKeys = @($remote.Keys | Where-Object { -not $sourceMap.ContainsKey([string]$_) }) }
        $trashBatchName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-deleted'
        Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Dropbox trash' -Detail "삭제된 백업 파일 $($deleteKeys.Count)개를 SafeSync 휴지통으로 옮길 준비를 하고 있습니다." -CurrentFolder $root -CompletedFiles 0 -TotalFiles $deleteKeys.Count -Force
        $deleteIndex = 0
        foreach ($key in $deleteKeys) {
            $entry = $remote[$key]
            $relative = [string]$entry.Relative
            $currentFolder = [string][System.IO.Path]::GetDirectoryName($relative)
            if ([string]::IsNullOrWhiteSpace($currentFolder)) { $currentFolder = '(root)' }
            Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Dropbox trash' -Detail "삭제된 백업 파일을 SafeSync 휴지통으로 옮기고 있습니다. ($deleteIndex / $($deleteKeys.Count))" -CurrentFolder $currentFolder -CurrentFile $relative -CompletedFiles $deleteIndex -TotalFiles $deleteKeys.Count -Force
            try {
                $trashPath=Join-SafeSyncDropboxPath $root ".safesync-trash/$trashBatchName/$relative"
                Move-SafeSyncDropboxItem $token ([string]$entry.Item.path_display) $trashPath
                $result.Trashed++
                if($stateEnabled){Remove-SafeSyncStateEntry $plan.State $relative}
            } catch {
                $result.Errors += "$relative : trash move failed - $($_.Exception.Message)"
                if($stateEnabled){Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -Status Failed -ErrorMessage $_.Exception.Message}
            }
            finally {
                $deleteIndex++
                if ($stateEnabled) {
                    [void]$checkpointPending.Remove($relative)
                    $completedCheckpointPaths.Add($relative)
                    if (($deleteIndex % 5) -eq 0 -or $deleteIndex -eq $deleteKeys.Count) { Save-SafeSyncCloudCheckpoint $plan.State $completedCheckpointPaths.ToArray() $checkpointPending; $completedCheckpointPaths.Clear() }
                }
                Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Dropbox trash' -Detail "삭제된 백업 파일을 SafeSync 휴지통으로 옮기고 있습니다. ($deleteIndex / $($deleteKeys.Count))" -CurrentFolder $currentFolder -CurrentFile $relative -CompletedFiles $deleteIndex -TotalFiles $deleteKeys.Count -Force
            }
        }
        if($stateEnabled){
            $reviewPaths=if($plan.FullScan){@($plan.State.Entries.Values|ForEach-Object{[string]$_.RelativePath})}else{@($plan.Paths)}
            foreach($relative in $reviewPaths){$key=([string]$relative).ToLowerInvariant();if(-not $sourceMap.ContainsKey($key) -and (-not [bool]$Job.MirrorDeletes -or -not $remote.ContainsKey($key))){Remove-SafeSyncStateEntry $plan.State ([string]$relative)}}
        }
        $trashRoot=Join-SafeSyncDropboxPath $root '.safesync-trash'
        try {
            $cutoff=(Get-Date).AddDays(-[Math]::Max(1,$TrashRetentionDays))
            foreach($entry in @(Get-SafeSyncDropboxEntries $token $trashRoot $false)) {
                if ([string]$entry.PSObject.Properties['.tag'].Value -ne 'folder' -or [string]$entry.name -notmatch '^(\d{8})') { continue }
                $date=[datetime]::ParseExact($matches[1],'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture)
                if($date -lt $cutoff.Date){ [void](Invoke-SafeSyncDropboxRpc $token 'files/delete_v2' @{path=[string]$entry.path_display}); $result.ExpiredTrashRemoved++ }
            }
        } catch {}
        if($stateEnabled){
            if($plan.FullScan -or [bool]$plan.State.CheckpointFullScan){$plan.State.LastFullScanUtc=[datetime]::UtcNow.ToString('o');$plan.State.FullScanRequired=$false}
            if(-not [string]::IsNullOrWhiteSpace($nextDropboxCursor)){$plan.State.DropboxCursor=$nextDropboxCursor}
             $plan.State.PendingPaths=@();$plan.State.CheckpointActive=$false;$plan.State.CheckpointFullScan=$false;$plan.State.LastRunUtc=[datetime]::UtcNow.ToString('o');if($null -ne (Get-Command Set-SafeSyncUsnCursor -ErrorAction SilentlyContinue)){[void](Set-SafeSyncUsnCursor $Job $plan.State)};Save-SafeSyncState $plan.State
        }
        return Complete-SafeSyncCloudResult $result
    } catch { $result.Status='Failed'; $result.Errors+=$_.Exception.Message; if($null -ne $plan -and $null -ne $plan.State){try{if($null -ne (Get-Variable checkpointPending -ErrorAction SilentlyContinue) -and $null -ne $checkpointPending){$plan.State.PendingPaths=@($checkpointPending.Values)};Save-SafeSyncState $plan.State}catch{}}; $result.FinishedAt=(Get-Date).ToString('o'); return [pscustomobject]$result }
}

function Invoke-SafeSyncGoogleBackup([object]$Job, [object]$Config, [int]$TrashRetentionDays, [switch]$ForceFull, [string[]]$ForceOverwritePaths=@(), [string[]]$RenameExistingPaths=@()) {
    $result = New-SafeSyncCloudResult $Job
    $plan = $null
    $uploadPipeline = $null
    try {
        $sourceRoot = [System.IO.Path]::GetFullPath([string]$Job.Source).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Source is unavailable: $sourceRoot" }
        $rootId = [string]$Job.CloudFolderId
        Write-SafeSyncProgress -Job $Job -Stage 'Connecting to Google Drive' -CurrentFolder $rootId -Force
        $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $Config
        Write-SafeSyncProgress -Job $Job -Stage 'Checking Google Drive recovery' -CurrentFolder $rootId -Force
        Repair-SafeSyncCloudTransactions 'GoogleDrive' $token $Job
        $stateEnabled = $null -ne (Get-Command Get-SafeSyncBackupPlan -ErrorAction SilentlyContinue)
        Write-SafeSyncProgress -Job $Job -Stage 'Preparing saved changes' -Detail '스냅샷에서 변경되었거나 이전에 실패한 파일을 모으고 있습니다.' -CurrentFolder $sourceRoot -Force
        $plan = if ($stateEnabled) { Get-SafeSyncBackupPlan -Job $Job -SourceRoot $sourceRoot -ForceFull:$ForceFull } else { [pscustomobject]@{State=$null;FullScan=$true;Paths=@()} }
        $forced = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($forcedPath in @($ForceOverwritePaths)){$normalized=ConvertTo-SafeSyncRelativePath ([string]$forcedPath);if(-not [string]::IsNullOrWhiteSpace($normalized)){$forced[$normalized]=$normalized}}
        $renameExisting = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($renamePath in @($RenameExistingPaths)){$normalized=ConvertTo-SafeSyncRelativePath ([string]$renamePath);if(-not [string]::IsNullOrWhiteSpace($normalized)){$renameExisting[$normalized]=$normalized;$forced[$normalized]=$normalized}}
        $requestedPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @($plan.Paths)){$requestedPaths[[string]$path]=[string]$path}
        foreach($path in @($forced.Values)){$requestedPaths[[string]$path]=[string]$path}
        $deltaMetadata = @{}
        $nextGoogleToken = if ($stateEnabled) { [string]$plan.State.GoogleChangeToken } else { '' }
        if ($plan.FullScan) {
            try { $nextGoogleToken = Get-SafeSyncGoogleStartPageToken $token } catch { if (Test-SafeSyncGoogleUnauthorized $_) { throw }; $nextGoogleToken = '' }
        }
        elseif ($stateEnabled -and -not [string]::IsNullOrWhiteSpace($nextGoogleToken)) {
            try {
                Write-SafeSyncProgress -Job $Job -Stage 'Reading Google Drive change feed' -Detail '마지막 확인 이후 바뀐 클라우드 항목만 불러옵니다.' -CurrentFolder $rootId -Force
                $delta = Get-SafeSyncGoogleChanges $token $nextGoogleToken
                $remoteIds = @{}
                foreach ($saved in @($plan.State.Entries.Values)) {
                    if ($null -ne $saved.PSObject.Properties['RemoteId'] -and -not [string]::IsNullOrWhiteSpace([string]$saved.RemoteId)) { $remoteIds[[string]$saved.RemoteId] = [string]$saved.RelativePath }
                }
                foreach ($change in @($delta.Changes)) {
                    $fileId = if ($null -ne $change.PSObject.Properties['fileId']) { [string]$change.fileId } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($fileId) -and $remoteIds.ContainsKey($fileId)) {
                        $relative = [string]$remoteIds[$fileId]
                        $requestedPaths[$relative] = $relative
                        if ($null -ne $change.PSObject.Properties['file'] -and $null -ne $change.file -and -not [bool]$change.file.trashed -and [string]$change.file.mimeType -ne 'application/vnd.google-apps.folder') {
                            $saved = $plan.State.Entries[$relative.ToLowerInvariant()]
                            $parentId = if (@($change.file.parents).Count -gt 0) { [string]$change.file.parents[0] } else { [string]$saved.RemoteParentId }
                            $deltaMetadata[$relative.ToLowerInvariant()] = [pscustomobject]@{Relative=$relative;Item=$change.file;ParentId=$parentId}
                        }
                        continue
                    }
                    if ($null -ne $change.PSObject.Properties['file'] -and $null -ne $change.file -and @($change.file.parents) -contains $rootId -and -not [bool]$change.file.trashed) {
                        $relative = ConvertTo-SafeSyncRelativePath ([string]$change.file.name)
                        if (-not (Test-SafeSyncInternalPath $relative)) {
                            $requestedPaths[$relative] = $relative
                            if ([string]$change.file.mimeType -ne 'application/vnd.google-apps.folder') { $deltaMetadata[$relative.ToLowerInvariant()] = [pscustomobject]@{Relative=$relative;Item=$change.file;ParentId=$rootId} }
                        }
                    }
                }
                $nextGoogleToken = [string]$delta.Token
                # Persist the change token before any remote metadata lookup or
                # upload.  If Windows or SafeSync is restarted mid-run, the next
                # run resumes the requested paths instead of downloading the same
                # Google change history again from the previous token.
                if ($stateEnabled -and -not [string]::IsNullOrWhiteSpace($nextGoogleToken)) {
                    $checkpointPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
                    foreach ($pending in @($plan.State.PendingPaths)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$pending); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPaths[$normalized] = $normalized } }
                    foreach ($requested in @($requestedPaths.Values)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$requested); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPaths[$normalized] = $normalized } }
                    $plan.State.PendingPaths = @($checkpointPaths.Values)
                    $plan.State.GoogleChangeToken = $nextGoogleToken
                    Save-SafeSyncState $plan.State
                }
            }
            catch {
                if (Test-SafeSyncGoogleUnauthorized $_) { throw }
                Write-SafeSyncProgress -Job $Job -Stage 'Google Drive change feed reset' -Detail '변경 토큰을 이어갈 수 없어 이번 한 번 전체 검사를 실행합니다.' -CurrentFolder $rootId -Force
                $plan.FullScan = $true
                try { $nextGoogleToken = Get-SafeSyncGoogleStartPageToken $token } catch { if (Test-SafeSyncGoogleUnauthorized $_) { throw }; $nextGoogleToken = '' }
            }
        }
        elseif ($stateEnabled) {
            try { $nextGoogleToken = Get-SafeSyncGoogleStartPageToken $token } catch { if (Test-SafeSyncGoogleUnauthorized $_) { throw }; $nextGoogleToken = '' }
        }
        $result.ScanMode = if ($plan.FullScan) { 'Full' } else { 'Incremental' }
        Write-SafeSyncProgress -Job $Job -Stage $(if($plan.FullScan){'Scanning Google Drive files'}else{'Preparing changed Google Drive files'}) -CurrentFolder $rootId -Force
        $tree = if ($plan.FullScan -or ($stateEnabled -and [bool]$plan.State.CheckpointFullScan)) { Get-SafeSyncGoogleTree $token $rootId } else { [pscustomobject]@{Files=@{};Folders=@{'_'=$rootId}} }
        if (-not $plan.FullScan -and $stateEnabled) {
            foreach ($key in @($deltaMetadata.Keys)) { $tree.Files[$key] = $deltaMetadata[$key] }
            $metadataRequests = New-Object System.Collections.Generic.List[object]
            foreach ($relative in @($requestedPaths.Values)) {
                $key = ([string]$relative).ToLowerInvariant()
                if ($tree.Files.ContainsKey($key)) { continue }
                if (-not $plan.State.Entries.ContainsKey($key)) { continue }
                $saved = $plan.State.Entries[$key]
                if ($null -eq $saved.PSObject.Properties['RemoteId'] -or [string]::IsNullOrWhiteSpace([string]$saved.RemoteId)) { continue }
                $metadataRequests.Add([pscustomobject]@{Key=$key;Relative=[string]$relative;RemoteId=[string]$saved.RemoteId;RemoteParentId=[string]$saved.RemoteParentId})
            }
            $metadataArray = [object[]]@($metadataRequests.ToArray())
            $metadataByKey = Get-SafeSyncGoogleMetadataBatch -Token $token -Requests $metadataArray -Job $Job
            foreach ($request in $metadataArray) {
                $key = [string]$request.Key
                if (-not $metadataByKey.ContainsKey($key)) { throw "Google Drive metadata was not returned for $($request.Relative)." }
                $item = $metadataByKey[$key]
                if ($null -ne $item -and -not [bool]$item.trashed) {
                    $parentId = if (@($item.parents).Count -gt 0) { [string]$item.parents[0] } else { [string]$request.RemoteParentId }
                    $tree.Files[$key] = [pscustomobject]@{Relative=[string]$request.Relative;Item=$item;ParentId=$parentId}
                }
            }
        }
        $sourceMap = @{}
        Write-SafeSyncProgress -Job $Job -Stage 'Scanning source for Google Drive' -CurrentFolder $sourceRoot -Force
        $sourceFiles = @(if ($plan.FullScan) { @(Get-SafeSyncCloudSourceFiles -Job $Job -SourceRoot $sourceRoot -Stage 'Scanning source for Google Drive') } else {
            @($requestedPaths.Values | ForEach-Object { $candidate=Join-Path $sourceRoot ([string]$_).Replace('/','\'); if(Test-Path -LiteralPath $candidate -PathType Leaf){Get-Item -LiteralPath $candidate -Force} })
        })
        $checkpointPending = $null
        if ($stateEnabled) {
            $checkpointPending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
            # Keep paths whose source file has disappeared as pending too. They
            # still need the mirror-delete decision; dropping them here would
            # make a restart after the token checkpoint forget that decision.
            foreach ($requested in @($requestedPaths.Values)) { $normalized = ConvertTo-SafeSyncRelativePath ([string]$requested); if (-not [string]::IsNullOrWhiteSpace($normalized)) { $checkpointPending[$normalized] = $normalized } }
            foreach ($pendingFile in @($sourceFiles)) {
                $pendingRelative = $pendingFile.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\','/')
                $checkpointPending[$pendingRelative] = $pendingRelative
            }
            $plan.State.PendingPaths = @($checkpointPending.Values)
            $plan.State.CheckpointActive = $true
            $plan.State.CheckpointFullScan = [bool]$plan.FullScan
            Save-SafeSyncState $plan.State
        }
        $uploadPipeline = New-SafeSyncGoogleUploadPipeline $Job $sourceFiles $tree $forced
        Fill-SafeSyncGoogleUploadPipeline $uploadPipeline
        $progressIndex = 0
        $completedCheckpointPaths = New-Object System.Collections.Generic.List[string]
        foreach ($file in $sourceFiles) {
            $progressIndex++
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\','/')
            $key = $relative.ToLowerInvariant()
            $sourceMap[$key] = $true
            $currentFolder=[string][System.IO.Path]::GetDirectoryName($relative);if([string]::IsNullOrWhiteSpace($currentFolder)){$currentFolder='(root)'}
            Write-SafeSyncProgress -Job $Job -Stage 'Comparing Google Drive files' -CurrentFolder $currentFolder -CurrentFile $relative -CurrentFileSize $file.Length -CompletedFiles ($progressIndex-1) -TotalFiles $sourceFiles.Count
            $removeCheckpoint = $true
            $preparedUpload = if ($null -ne $uploadPipeline -and $uploadPipeline.Active.ContainsKey($key)) { $uploadPipeline.Active[$key] } else { $null }
            try {
                $parentRel = [string][System.IO.Path]::GetDirectoryName($relative)
                $parentRel = $parentRel.Replace('\','/')
                $parentId = Ensure-SafeSyncGoogleFolderPath $token $rootId $parentRel $tree.Folders
                if (-not $tree.Files.ContainsKey($key)) {
                    $published = Publish-SafeSyncGoogleFile $token $file $parentId $null $Job $tree.Folders $relative $preparedUpload
                    $result.Copied++
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id) -RemoteParentId $parentId }
                    continue
                }
                $remote = $tree.Files[$key]
                $item = $remote.Item
                $remoteModified = [datetime]::Parse([string]$item.modifiedTime).ToUniversalTime()
                [long]$remoteSize = if ($null -eq $item.size) { -1 } else { [long]$item.size }
                $sameModified = [Math]::Abs(($file.LastWriteTimeUtc-$remoteModified).TotalSeconds) -le 2
                if ($forced.ContainsKey($relative)) {
                    $originalName = [string]$item.name
                    $renamedName = ''
                    if ($renameExisting.ContainsKey($relative)) {
                        $current = Get-SafeSyncGoogleMetadata $token ([string]$item.id)
                        if ([string]$current.version -ne [string]$item.version -or -not (@($current.parents) -contains $parentId)) { throw 'The Google Drive backup changed before conflict handling. Nothing was overwritten.' }
                        $renamedName = Get-SafeSyncConflictCopyName $originalName
                        [void](Rename-SafeSyncGoogleItem $token ([string]$item.id) $renamedName)
                    }
                    try { $published = Publish-SafeSyncGoogleFile $token $file $parentId $(if([string]::IsNullOrWhiteSpace($renamedName)){$item}else{$null}) $Job $tree.Folders $relative $preparedUpload }
                    catch {
                        if (-not [string]::IsNullOrWhiteSpace($renamedName)) { try { [void](Rename-SafeSyncGoogleItem $token ([string]$item.id) $originalName) } catch {} }
                        throw
                    }
                    $result.Copied++
                    if (-not [string]::IsNullOrWhiteSpace($renamedName)) { $result.RenamedBackups++ }
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id) -RemoteParentId $parentId }
                    continue
                }
                if ($sameModified -and $file.Length -eq $remoteSize) {
                    $result.Skipped++
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$item.id) -RemoteParentId ([string]$remote.ParentId) }
                    continue
                }
                if ($file.LastWriteTimeUtc -gt $remoteModified.AddSeconds(2)) {
                    $published = Publish-SafeSyncGoogleFile $token $file $parentId $item $Job $tree.Folders $relative $preparedUpload
                    $result.Copied++
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status BackedUp -RemoteId ([string]$published.id) -RemoteParentId $parentId }
                    continue
                }
                if ($sameModified -and $file.Length -ne $remoteSize) { Add-SafeSyncCloudConflict $result $relative 'Modified time matches but cloud file size differs.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                elseif ($remoteModified -gt $file.LastWriteTimeUtc.AddSeconds(2)) { Add-SafeSyncCloudConflict $result $relative 'Cloud file is newer than the source.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                else { Add-SafeSyncCloudConflict $result $relative 'Source and cloud file metadata differs.' $file.Length $remoteSize $file.LastWriteTimeUtc $remoteModified }
                if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Conflict -RemoteId ([string]$item.id) -RemoteParentId ([string]$remote.ParentId) }
            } catch {
                if (Test-SafeSyncGoogleUnauthorized $_) { $removeCheckpoint = $false; throw }
                if (Test-SafeSyncFileInUseError $_) {
                    Add-SafeSyncLockedFile $result $relative $_
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Locked -ErrorMessage $_.Exception.Message }
                }
                else {
                    $result.Errors += "$relative : $($_.Exception.Message)"
                    if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -File $file -Status Failed -ErrorMessage $_.Exception.Message }
                }
            }
            finally {
                if ($null -ne $preparedUpload) {
                    $preparedUpload.Dispose()
                    [void]$uploadPipeline.Active.Remove($key)
                    if ($removeCheckpoint) { Fill-SafeSyncGoogleUploadPipeline $uploadPipeline }
                }
                if ($stateEnabled -and $removeCheckpoint) {
                    [void]$checkpointPending.Remove([string]$relative)
                    $completedCheckpointPaths.Add([string]$relative)
                    if (($progressIndex % 5) -eq 0 -or $checkpointPending.Count -eq 0) { Save-SafeSyncCloudCheckpoint $plan.State $completedCheckpointPaths.ToArray() $checkpointPending; $completedCheckpointPaths.Clear() }
                }
            }
        }
        $deleteKeys = @()
        if ([bool]$Job.MirrorDeletes) { $deleteKeys = @($tree.Files.Keys | Where-Object { -not $sourceMap.ContainsKey([string]$_) }) }
        # Use one stable bundle name for the entire run. Recomputing the second-
        # based name for every file created many near-identical folder trees and
        # multiplied Google Drive API calls during a large deletion batch.
        $trashBatchName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-deleted'
        Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Google Drive trash' -Detail "삭제된 백업 파일 $($deleteKeys.Count)개를 SafeSync 휴지통으로 옮길 준비를 하고 있습니다." -CurrentFolder $rootId -CompletedFiles 0 -TotalFiles $deleteKeys.Count -Force
        $deleteIndex = 0
        foreach ($key in $deleteKeys) {
            $remote = $tree.Files[$key]
            $relative = [string]$remote.Relative
            $removeDeleteCheckpoint = $true
            $parentRel = [string][System.IO.Path]::GetDirectoryName($relative)
            $parentRel = $parentRel.Replace('\','/')
            $displayFolder = if ([string]::IsNullOrWhiteSpace($parentRel)) { '(root)' } else { $parentRel }
            Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Google Drive trash' -Detail "삭제된 백업 파일을 SafeSync 휴지통으로 옮기고 있습니다. ($deleteIndex / $($deleteKeys.Count))" -CurrentFolder $displayFolder -CurrentFile $relative -CompletedFiles $deleteIndex -TotalFiles $deleteKeys.Count -Force
            try {
                $trashRel = ".safesync-trash/$trashBatchName/$parentRel".TrimEnd('/')
                $trashParent = Ensure-SafeSyncGoogleFolderPath $token $rootId $trashRel $tree.Folders
                Move-SafeSyncGoogleItem $token ([string]$remote.Item.id) ([string]$remote.ParentId) $trashParent
                $result.Trashed++
                if ($stateEnabled) { Remove-SafeSyncStateEntry $plan.State $relative }
            } catch {
                if (Test-SafeSyncGoogleUnauthorized $_) { $removeDeleteCheckpoint = $false; throw }
                $result.Errors += "$relative : trash move failed - $($_.Exception.Message)"
                if ($stateEnabled) { Set-SafeSyncStateEntry -State $plan.State -RelativePath $relative -Status Failed -ErrorMessage $_.Exception.Message }
            }
            finally {
                $deleteIndex++
                if ($stateEnabled -and $removeDeleteCheckpoint) {
                    [void]$checkpointPending.Remove($relative)
                    $completedCheckpointPaths.Add($relative)
                    if (($deleteIndex % 5) -eq 0 -or $deleteIndex -eq $deleteKeys.Count) { Save-SafeSyncCloudCheckpoint $plan.State $completedCheckpointPaths.ToArray() $checkpointPending; $completedCheckpointPaths.Clear() }
                }
                Write-SafeSyncProgress -Job $Job -Stage 'Cleaning Google Drive trash' -Detail "삭제된 백업 파일을 SafeSync 휴지통으로 옮기고 있습니다. ($deleteIndex / $($deleteKeys.Count))" -CurrentFolder $displayFolder -CurrentFile $relative -CompletedFiles $deleteIndex -TotalFiles $deleteKeys.Count -Force
            }
        }
        if ($stateEnabled) {
            $reviewPaths = if ($plan.FullScan) { @($plan.State.Entries.Values | ForEach-Object {[string]$_.RelativePath}) } else { @($plan.Paths) }
            foreach ($relative in $reviewPaths) {
                $key = ([string]$relative).ToLowerInvariant()
                if (-not $sourceMap.ContainsKey($key) -and (-not [bool]$Job.MirrorDeletes -or -not $tree.Files.ContainsKey($key))) { Remove-SafeSyncStateEntry $plan.State ([string]$relative) }
            }
        }
        try {
            $trash = @(Get-SafeSyncGoogleChildren $token $rootId) | Where-Object { $_.name -eq '.safesync-trash' -and $_.mimeType -eq 'application/vnd.google-apps.folder' } | Select-Object -First 1
            if ($null -ne $trash) {
                $cutoff = (Get-Date).AddDays(-[Math]::Max(1,$TrashRetentionDays))
                foreach ($entry in @(Get-SafeSyncGoogleChildren $token ([string]$trash.id))) {
                    if ([string]$entry.name -match '^(\d{8})') {
                        $date = [datetime]::ParseExact($matches[1],'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture)
                        if ($date -lt $cutoff.Date) {
                            $deleteUri = "https://www.googleapis.com/drive/v3/files/$($entry.id)"
                            [void](Invoke-SafeSyncGoogleRequest $token { param($activeToken) Invoke-RestMethod -Method Delete -Uri $deleteUri -Headers @{Authorization="Bearer $activeToken"} })
                            $result.ExpiredTrashRemoved++
                        }
                    }
                }
            }
        } catch {}
        if ($stateEnabled) {
            if ($plan.FullScan -or [bool]$plan.State.CheckpointFullScan) { $plan.State.LastFullScanUtc=[datetime]::UtcNow.ToString('o'); $plan.State.FullScanRequired=$false }
            if (-not [string]::IsNullOrWhiteSpace($nextGoogleToken)) { $plan.State.GoogleChangeToken=$nextGoogleToken }
            $plan.State.PendingPaths=@(); $plan.State.CheckpointActive=$false; $plan.State.CheckpointFullScan=$false; $plan.State.LastRunUtc=[datetime]::UtcNow.ToString('o'); if($null -ne (Get-Command Set-SafeSyncUsnCursor -ErrorAction SilentlyContinue)){[void](Set-SafeSyncUsnCursor $Job $plan.State)}; Save-SafeSyncState $plan.State
        }
        return Complete-SafeSyncCloudResult $result
    } catch {
        $result.Status='Failed'; $result.Errors+=$_.Exception.Message
        try { Write-AppLog ("Google Drive 백업 내부 오류: {0}`r`n{1}" -f $_.Exception.Message,$_.ScriptStackTrace) 'ERROR' } catch {}
        if ($null -ne $plan -and $null -ne $plan.State) { try { if ($null -ne (Get-Variable checkpointPending -ErrorAction SilentlyContinue) -and $null -ne $checkpointPending) { $plan.State.PendingPaths = @($checkpointPending.Values) }; Save-SafeSyncState $plan.State } catch {} }
        $result.FinishedAt=(Get-Date).ToString('o'); return [pscustomobject]$result
    }
    finally { Close-SafeSyncGoogleUploadPipeline $uploadPipeline }
}

function Invoke-SafeSyncCloudBackup {
    param([object]$Job,[object]$Config,[int]$TrashRetentionDays=100,[switch]$ForceFull,[string[]]$ForceOverwritePaths=@(),[string[]]$RenameExistingPaths=@())
    if([string]$Job.DestinationType -eq 'Dropbox'){return Invoke-SafeSyncDropboxBackup $Job $Config $TrashRetentionDays -ForceFull:$ForceFull -ForceOverwritePaths $ForceOverwritePaths -RenameExistingPaths $RenameExistingPaths}
    if([string]$Job.DestinationType -eq 'GoogleDrive'){return Invoke-SafeSyncGoogleBackup $Job $Config $TrashRetentionDays -ForceFull:$ForceFull -ForceOverwritePaths $ForceOverwritePaths -RenameExistingPaths $RenameExistingPaths}
    throw "Unsupported cloud provider: $($Job.DestinationType)"
}

function Get-SafeSyncCloudFolders([string]$Provider,[object]$Config,[string]$ParentId){
    $token=Get-SafeSyncCloudAccessToken $Provider $Config
    if($Provider -eq 'Dropbox'){
        $items=@(Get-SafeSyncDropboxEntries $token $ParentId $false)|Where-Object{[string]$_.PSObject.Properties['.tag'].Value -eq 'folder'}|ForEach-Object{[pscustomobject]@{Id=[string]$_.path_display;Name=[string]$_.name}}
        return @($items|Sort-Object Name)
    }
    $items=@(Get-SafeSyncGoogleChildren $token $ParentId)|Where-Object{$_.mimeType -eq 'application/vnd.google-apps.folder'}|ForEach-Object{[pscustomobject]@{Id=[string]$_.id;Name=[string]$_.name}}
    return @($items|Sort-Object Name)
}
