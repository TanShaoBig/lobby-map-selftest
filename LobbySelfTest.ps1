# Upload protocol based on NeLobbyAutoKit (BSD-3-Clause); see THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt.
# Functions only. No network requests are made when this file is loaded.
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-LobbyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function ConvertTo-LobbyPlainData {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-LobbyPlainData $Value[$key] }
        return $result
    }
    if ($Value -is [array]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-LobbyPlainData $item) }
        return ,$items
    }
    if ($Value -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-LobbyPlainData $property.Value
        }
        return $result
    }
    return $Value
}

function Assert-LobbyPackage {
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -ine '.zip' -or $file.Length -eq 0) {
        throw '自测包必须是非空 ZIP 文件。'
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        foreach ($name in $names) {
            if ($name.Contains('\') -or $name.StartsWith('/') -or $name.Contains(':') -or
                @($name.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' }).Count -gt 0) {
                throw 'ZIP 中存在不安全的路径。'
            }
        }
        $roots = @($names | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique)
        if ($roots.Count -ne 1 -or [string]::IsNullOrWhiteSpace($roots[0])) {
            throw '联机大厅 ZIP 必须只有一个顶级文件夹。'
        }
        $root = $roots[0]
        foreach ($required in @('level.dat', 'levelname.txt', 'world_behavior_packs.json', 'world_resource_packs.json')) {
            if ($names -notcontains "$root/$required") { throw "ZIP 缺少地图文件：$required" }
        }
        foreach ($required in @('behavior_packs', 'resource_packs', 'db')) {
            if (@($names | Where-Object { $_.StartsWith("$root/$required/", [StringComparison]::Ordinal) }).Count -eq 0) {
                throw "ZIP 缺少地图目录：$required"
            }
        }
        if (@($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'ZIP 中存在重复路径。' }
        $buffer = New-Object byte[] 81920
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $stream = $entry.Open()
            try { while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) {} }
            finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    return [pscustomobject]@{ Path = $file.FullName; Length = $file.Length; Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
}

function Read-LobbyUploadReply {
    param([string]$Body, [string]$Signature)
    if ([string]::IsNullOrWhiteSpace($Signature) -or $Signature -match '[\r\n]') {
        throw '上传响应缺少有效的 x-ntes-signature，未更新项目。'
    }
    $match = [regex]::Match($Body, '<textarea\b[^>]*>([\s\S]*?)</textarea\s*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { throw '上传响应缺少 textarea，未更新项目。' }
    $originalBody = $match.Groups[1].Value
    try {
        $parsed = ConvertFrom-Json -InputObject $originalBody -ErrorAction Stop
        if ($null -eq $parsed -or $parsed.GetType() -ne [System.Management.Automation.PSCustomObject]) { throw 'Invalid upload object' }
    }
    catch { throw '上传响应中的资源数据不是有效 JSON 对象，未更新项目。' }
    return [pscustomobject]@{ Body = $originalBody; Sign = $Signature }
}

function Get-LobbyResourceIndex {
    param($Data, [int]$ResourceIndex = -1)
    $resources = Get-LobbyValue $Data 'res'
    if ($resources -isnot [array] -or $resources.Count -eq 0) { throw '平台项目没有可替换的资源列表。' }
    if ($ResourceIndex -eq -1) {
        if ($resources.Count -ne 1) { throw '平台项目包含多个资源，请用 -ResourceIndex 明确选择资源下标（从 0 开始）。' }
        return 0
    }
    if ($ResourceIndex -lt 0 -or $ResourceIndex -ge $resources.Count) { throw 'ResourceIndex 超出平台项目资源范围。' }
    return $ResourceIndex
}

function New-LobbyUpdateData {
    param($Data, [string]$UploadBody, [string]$UploadSign, [string]$PackageName, [int]$ResourceIndex = -1)
    $index = Get-LobbyResourceIndex -Data $Data -ResourceIndex $ResourceIndex
    $result = ConvertTo-LobbyPlainData $Data
    if ($result -isnot [System.Collections.IDictionary]) { throw '平台项目数据格式错误。' }
    $result.Remove('author_info')
    foreach ($key in @('subject_id', 'commercial_time', 'openbeta_time')) {
        if (-not $result.ContainsKey($key) -or [string]::IsNullOrEmpty([string]$result[$key])) { $result[$key] = $null }
    }
    foreach ($key in @('pri_effect_type', 'sub_effect_type')) {
        if ($result.ContainsKey($key) -and [string]::IsNullOrEmpty([string]$result[$key])) { $result.Remove($key) }
    }
    if ($result.ContainsKey('dlc_info')) {
        if ($result.dlc_info -isnot [System.Collections.IDictionary]) { $result.dlc_info = @{} }
        if ((Get-LobbyValue $result.dlc_info 'master') -isnot [System.Collections.IDictionary]) { $result.dlc_info['master'] = @{} }
        if ((Get-LobbyValue $result.dlc_info 'slave_list') -isnot [array]) { $result.dlc_info['slave_list'] = @() }
    }
    $resource = $result.res[$index]
    if ($resource -isnot [System.Collections.IDictionary]) { throw '选中的平台资源不是对象。' }
    $resource.res_url = @{ body = $UploadBody; file_type = 'zip_package'; sign = $UploadSign }
    $resource.res_name = $PackageName
    foreach ($key in @('res_info', 'res_id', 'cdn_info', 'cdn_url')) { $resource.Remove($key) }
    return $result
}

function Invoke-LobbyHttpRequest {
    param(
        [string]$Method, [string]$Uri, [string]$Cookie = '', [string]$JsonBody = '',
        [string]$PackagePath = '', [string]$UploadToken = '', [int]$TimeoutSeconds = 90,
        [System.Net.Http.HttpMessageHandler]$MessageHandler = $null,
        [string]$UploadFileName = ''
    )
    $target = [uri]$Uri
    $isPlatform = $target.Scheme -eq 'https' -and $target.Host -eq 'mc-launcher.webapp.163.com'
    $isUpload = $Uri -eq 'https://pfp.ps.netease.com/x19s/file/new/'
    if (-not ($isPlatform -or $isUpload)) { throw '拒绝向未指定的平台地址发送请求。' }
    if (($Cookie -and -not $isPlatform) -or $Cookie -match '[\r\n]' -or $UploadToken -match '[\r\n]') {
        throw '认证请求参数不合法。'
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $handler = $MessageHandler
    if ($null -eq $handler) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Uri)
    $response = $null
    $fileStream = $null
    try {
        if ($Cookie) { $null = $request.Headers.TryAddWithoutValidation('Cookie', $Cookie) }
        $null = $request.Headers.TryAddWithoutValidation('User-Agent', 'LobbyMapSelfTest/1.0')
        if ($PackagePath) {
            if (-not $isUpload -or [string]::IsNullOrWhiteSpace($UploadToken)) { throw '上传目标或上传凭证不合法。' }
            $multipart = New-Object System.Net.Http.MultipartFormDataContent
            $request.Content = $multipart
            $multipart.Add((New-Object System.Net.Http.StringContent($UploadToken)), 'Authorization')
            $fileStream = [System.IO.File]::Open($PackagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
            $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/x-zip-compressed')
            if (-not $UploadFileName) { $UploadFileName = [System.IO.Path]::GetFileName($PackagePath) }
            if ($UploadFileName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*\.zip$') { throw '远程上传文件名必须是安全的 ASCII ZIP 文件名。' }
            $multipart.Add($fileContent, 'fpfile', $UploadFileName)
        }
        elseif ($JsonBody) {
            $request.Content = New-Object System.Net.Http.StringContent($JsonBody, [System.Text.Encoding]::UTF8, 'application/json')
        }
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch { throw '网络请求失败或超时；写入请求未自动重试，请先在开发者平台核对当前状态。' }
        $sign = ''
        if ($response.Headers.Contains('x-ntes-signature')) { $sign = @($response.Headers.GetValues('x-ntes-signature'))[0] }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $body; Signature = $sign }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-LobbyApiRequest {
    param([string]$Method, [string]$Path, [string]$Cookie, $Data = $null)
    $body = ''
    if ($null -ne $Data) { $body = ConvertTo-Json -InputObject $Data -Depth 100 -Compress }
    $reply = Invoke-LobbyHttpRequest -Method $Method -Uri ('https://mc-launcher.webapp.163.com' + $Path) -Cookie $Cookie -JsonBody $body
    if ($reply.StatusCode -eq 401 -or $reply.StatusCode -eq 403) { throw '开发者平台登录失效或无权访问项目，请重新配置 Cookie 和项目 ID。' }
    if ($reply.StatusCode -ne 200) { throw "开发者平台请求失败（HTTP $($reply.StatusCode)），请到平台检查项目。" }
    try { $parsed = ConvertFrom-Json -InputObject $reply.Body -ErrorAction Stop }
    catch { throw '开发者平台未返回有效 JSON，可能需要重新登录。' }
    $status = Get-LobbyValue $parsed 'status'
    if (($null -ne $status -and $status -ne 'ok') -or ($Method -ne 'GET' -and $status -ne 'ok')) {
        throw '开发者平台拒绝了请求，请检查登录、项目权限及平台项目状态。'
    }
    return $parsed
}

function Get-LobbyProject {
    param([string]$ModId, [string]$Cookie)
    if ([string]::IsNullOrWhiteSpace($ModId)) { throw '项目 ID 不能为空。' }
    $reply = Invoke-LobbyApiRequest -Method GET -Path ('/items/categories/pe/' + [uri]::EscapeDataString($ModId)) -Cookie $Cookie
    $data = Get-LobbyValue $reply 'data'
    if ($null -eq $data -or $data.GetType() -ne [System.Management.Automation.PSCustomObject]) { throw '平台项目详情缺少 data 对象，请检查项目 ID 和登录状态。' }
    return $data
}

function Write-LobbySelfTestState {
    param([string]$Path, [System.Collections.IDictionary]$State)
    $State['updatedAt'] = [datetime]::UtcNow.ToString('o')
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 8
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Assert-LobbyProjectIdentity {
    param($Data, [string]$ModId)
    # Display names can change. Only the exact platform ID identifies the project.
    if ([string]::IsNullOrWhiteSpace($ModId) -or [string](Get-LobbyValue $Data 'item_id') -cne $ModId) {
        throw '平台返回的项目 ID 与目标不一致，已停止。'
    }
}

function Resolve-LobbyPreviousUpload {
    param(
        [string]$ModId, [string]$Cookie, [string]$StatePath, $PreviousState, $InitialProject,
        [string]$ExpectedProjectName = '',
        [ValidateRange(0, 86400)][int]$WaitTimeoutSeconds = 900,
        [ValidateRange(0, 60)][int]$PollIntervalSeconds = 3
    )
    # Called under the entry lock. Reconcile by the original unique remote package,
    # never by an error message and never by silently enabling StartNew.
    if ([string](Get-LobbyValue $PreviousState 'modId') -cne $ModId) { throw '原任务项目不匹配，无法自动核对。' }
    $packageName = [string](Get-LobbyValue $PreviousState 'packageName')
    $index = -1
    if ([string]::IsNullOrWhiteSpace($packageName) -or
        -not [int]::TryParse([string](Get-LobbyValue $PreviousState 'resourceIndex'), [ref]$index) -or $index -lt 0) {
        throw '原任务缺少有效的资源名或资源下标，无法自动核对，未继续上传。'
    }
    $project = $InitialProject
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastReportAt = -30.0
    while ($true) {
        if ($null -eq $project) { $project = Get-LobbyProject -ModId $ModId -Cookie $Cookie }
        Assert-LobbyProjectIdentity -Data $project -ModId $ModId
        $resources = Get-LobbyValue $project 'res'
        if ($resources -isnot [array] -or $index -ge $resources.Count -or
            [string](Get-LobbyValue $resources[$index] 'res_name') -cne $packageName) {
            throw '平台资源与上次任务的唯一资源名不匹配，无法自动确认旧任务，未取消或重新上传。'
        }
        $status = [string](Get-LobbyValue $project 'status')
        if ($status -in @('self_test', 'init')) {
            $state = @{}
            foreach ($property in $PreviousState.PSObject.Properties) { $state[$property.Name] = $property.Value }
            $state['phase'] = if ($status -eq 'self_test') { 'ready' } else { 'rejected' }
            $state['status'] = $status
            $state.Remove('failedAtPhase')
            Write-LobbySelfTestState -Path $StatePath -State $state
            if ($status -eq 'self_test') { Write-Host '自动查询确认上次版本已就绪，继续本次上传流程。' }
            else { Write-Host '自动查询确认旧资源已回到待提交状态，继续本次上传流程。' }
            return [pscustomobject]@{ Project = $project; State = [pscustomobject]$state }
        }
        if ($status -ne 'self_test_prepare') {
            throw '原任务处于非预期平台状态，自动查询未确认完成，未继续上传。'
        }
        if ($timer.Elapsed.TotalSeconds - $lastReportAt -ge 30) {
            Write-Host ('上次版本仍在准备自测，自动等待并查询（已等待 {0:N0} 秒）……' -f $timer.Elapsed.TotalSeconds)
            $lastReportAt = $timer.Elapsed.TotalSeconds
        }
        if ($timer.Elapsed.TotalSeconds -ge $WaitTimeoutSeconds) {
            throw '自动查询旧任务超时，原记录已保留；未取消或重新上传。下次启动会继续自动核对。'
        }
        $remaining = [Math]::Max(0, $WaitTimeoutSeconds - $timer.Elapsed.TotalSeconds)
        if ($PollIntervalSeconds -gt 0) { Start-Sleep -Milliseconds ([int]([Math]::Min($PollIntervalSeconds, $remaining) * 1000)) }
        $project = $null
    }
}

function Get-LobbyCancelTarget {
    param($Data, [string]$ModId, [string]$ExpectedProjectName = '')
    Assert-LobbyProjectIdentity -Data $Data -ModId $ModId
    $resources = Get-LobbyValue $Data 'res'
    if ($resources -isnot [array] -or $resources.Count -eq 0) { throw '取消目标缺少资源列表，已停止。' }
    $names = @()
    foreach ($resource in $resources) {
        $name = [string](Get-LobbyValue $resource 'res_name')
        if ([string]::IsNullOrWhiteSpace($name)) { throw '取消目标资源名缺失，已停止。' }
        $names += $name
    }
    $json = ConvertTo-Json -InputObject $names -Compress
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Stop-LobbySelfTest {
    param(
        [string]$ModId, [string]$Cookie, [string]$StatePath, $PreviousState = $null,
        [string]$ExpectedProjectName = '',
        [ValidateRange(0, 300)][int]$WaitTimeoutSeconds = 60,
        [ValidateRange(0, 60)][int]$PollIntervalSeconds = 3
    )
    # Caller holds the official entry's exclusive lock and has reconciled previous uploads.
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw '取消自测必须提供任务记录路径。' }
    if ($null -ne $PreviousState -and [string](Get-LobbyValue $PreviousState 'modId') -cne $ModId) {
        throw '原任务不属于取消目标，已停止。'
    }
    $data = Get-LobbyProject -ModId $ModId -Cookie $Cookie
    $target = Get-LobbyCancelTarget -Data $data -ModId $ModId -ExpectedProjectName $ExpectedProjectName
    $status = [string](Get-LobbyValue $data 'status')
    if ($status -eq 'init') {
        return [pscustomobject]@{ ModId = $ModId; Status = $status; CancellationStatus = 'not_needed'; PreviousStatus = $status }
    }
    if ($status -notin @('self_test', 'self_test_prepare')) { throw '平台当前不是可取消的自测状态，未取消、未上传；请先核对平台。' }
    $state = @{}
    if ($null -ne $PreviousState) {
        foreach ($property in $PreviousState.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    $state['schemaVersion'] = 1
    $state['modId'] = $ModId
    $state['phase'] = 'cancelling'
    $state['cancelPreviousStatus'] = $status
    $state['cancelTargetFingerprint'] = $target
    $state['cancelStartedAt'] = [datetime]::UtcNow.ToString('o')
    $state.Remove('failedAtPhase')
    $state.Remove('cancelledAt')
    # Journal before sending the single write; unknown results must be queried, never replayed.
    Write-LobbySelfTestState -Path $StatePath -State $state
    try {
        Write-Host '正在取消旧版自测……'
        $null = Invoke-LobbyApiRequest -Method PUT -Path ('/items/categories/pe/' + [uri]::EscapeDataString($ModId) + '/cancel_self_test') -Cookie $Cookie
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            $current = Get-LobbyProject -ModId $ModId -Cookie $Cookie
            if ((Get-LobbyCancelTarget -Data $current -ModId $ModId -ExpectedProjectName $ExpectedProjectName) -cne $target) {
                throw '取消期间平台资源已变化，未继续上传；请核对目标版本。'
            }
            $currentStatus = [string](Get-LobbyValue $current 'status')
            if ($currentStatus -eq 'init') {
                $state['phase'] = 'cancelled'
                $state['status'] = $currentStatus
                $state['cancelledAt'] = [datetime]::UtcNow.ToString('o')
                Write-LobbySelfTestState -Path $StatePath -State $state
                Write-Host '旧版自测已取消并回查确认。'
                return [pscustomobject]@{ ModId = $ModId; Status = $currentStatus; CancellationStatus = 'cancelled'; PreviousStatus = $status }
            }
            if ($currentStatus -notin @('self_test', 'self_test_prepare')) { throw '取消后出现非预期状态，未继续上传；请核对平台。' }
            if ($timer.Elapsed.TotalSeconds -ge $WaitTimeoutSeconds) { break }
            if ($PollIntervalSeconds -gt 0) {
                Start-Sleep -Milliseconds ([int]([Math]::Min($PollIntervalSeconds, $WaitTimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000))
            }
        } while ($true)
        throw '取消自测尚未回查确认，未继续上传；请查询原任务，不要重复取消。'
    }
    catch {
        $state['phase'] = 'needs_check'
        $state['failedAtPhase'] = 'cancelling'
        try { Write-LobbySelfTestState -Path $StatePath -State $state } catch { Write-Warning '取消结果未知，且任务记录保存失败；请先在平台核对。' }
        throw
    }
}

function Wait-LobbySelfTest {
    param(
        [string]$ModId, [string]$Cookie, [string]$ExpectedPackageName, [string]$ExpectedSign = '',
        [int]$ResourceIndex = 0, [int]$WaitTimeoutSeconds = 900, [int]$PollIntervalSeconds = 3
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = ''
    do {
        $data = Get-LobbyProject -ModId $ModId -Cookie $Cookie
        $status = [string](Get-LobbyValue $data 'status')
        if ($status -ne $lastStatus) {
            $safeStatus = $status -replace '[^a-zA-Z0-9_\-]', '?'
            Write-Host "平台状态：$safeStatus"
            $lastStatus = $status
        }
        $resources = Get-LobbyValue $data 'res'
        if ($resources -isnot [array]) { $resources = @() }
        $matches = $false
        if ($ResourceIndex -lt $resources.Count) {
            $resource = $resources[$ResourceIndex]
            $matches = (Get-LobbyValue $resource 'res_name') -ceq $ExpectedPackageName
            $remoteSign = Get-LobbyValue (Get-LobbyValue $resource 'res_url') 'sign'
            if ($ExpectedSign -and $remoteSign -and $remoteSign -cne $ExpectedSign) { $matches = $false }
        }
        if ($status -eq 'self_test' -and $matches) { return 'self_test' }
        if ($status -eq 'init' -and $matches) { throw '平台报告本次资源自测未通过，请到开发者平台查看具体原因。' }
        if ($timer.Elapsed.TotalSeconds -ge $WaitTimeoutSeconds) { break }
        $remaining = $WaitTimeoutSeconds - $timer.Elapsed.TotalSeconds
        if ($PollIntervalSeconds -gt 0) { Start-Sleep -Milliseconds ([int]([Math]::Min($PollIntervalSeconds, $remaining) * 1000)) }
    } while ($true)
    throw '等待自测就绪超时；提交结果请到开发者平台核查，或使用“查询自测状态”入口。旧 online 状态不会算作本次自测成功。'
}

function Start-LobbySelfTest {
    param(
        [string]$PackagePath, [string]$ModId, [string]$Cookie, [int]$ResourceIndex = -1,
        [ValidateRange(0, 86400)][int]$WaitTimeoutSeconds = 900,
        [ValidateRange(0, 60)][int]$PollIntervalSeconds = 3, [string]$StatePath = '',
        [switch]$RequireInit,
        [string]$PackageSourceDigest = '', [string]$SourceDigestAlgorithm = '', [int]$RandomizedUuidCount = 0
    )
    $package = Assert-LobbyPackage -Path $PackagePath
    if (-not $StatePath) { $StatePath = $package.Path + '.selftest.json' }
    $localPackageName = [System.IO.Path]::GetFileName($package.Path)
    $packageName = 'lobby-map-{0}-{1}.zip' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
    $state = [ordered]@{
        schemaVersion = 1; modId = $ModId; packagePath = $package.Path; packageSha256 = $package.Sha256
        packageName = $packageName; localPackageName = $localPackageName; phase = 'preflight'; resourceIndex = $ResourceIndex
    }
    if ($PackageSourceDigest) {
        $state['sourceDigest'] = $PackageSourceDigest
        $state['sourceDigestAlgorithm'] = $SourceDigestAlgorithm
        $state['randomizedUuidCount'] = $RandomizedUuidCount
    }
    try {
        $data = Get-LobbyProject -ModId $ModId -Cookie $Cookie
        $index = Get-LobbyResourceIndex -Data $data -ResourceIndex $ResourceIndex
        if ($RequireInit -and (Get-LobbyValue $data 'status') -ne 'init') { throw '取消后平台状态已变化，未开始上传，请先核对。' }
        $initialTarget = if ($RequireInit) { Get-LobbyCancelTarget -Data $data -ModId $ModId } else { '' }
        $state.resourceIndex = $index
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host "申请上传凭证（项目 $ModId，资源下标 $index）……"
        $tokenReply = Invoke-LobbyApiRequest -Method GET -Path '/filepicker/file_token?file_type=zip_package&secure=true' -Cookie $Cookie
        $token = [string](Get-LobbyValue (Get-LobbyValue $tokenReply 'data') 'token')
        if ([string]::IsNullOrWhiteSpace($token)) { throw '平台没有返回上传凭证，未上传。' }
        $state.phase = 'uploading'
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host ('上传 ZIP：{0}（{1:N1} MiB）……' -f $localPackageName, ($package.Length / 1MB))
        $uploadReply = Invoke-LobbyHttpRequest -Method POST -Uri 'https://pfp.ps.netease.com/x19s/file/new/' -PackagePath $package.Path -UploadFileName $packageName -UploadToken $token -TimeoutSeconds 1800
        if ($uploadReply.StatusCode -ne 200) { throw "ZIP 上传失败（HTTP $($uploadReply.StatusCode)），未更新项目。" }
        $upload = Read-LobbyUploadReply -Body $uploadReply.Body -Signature $uploadReply.Signature
        # Re-read immediately before updating so unrelated metadata is not taken from the pre-upload snapshot.
        $data = Get-LobbyProject -ModId $ModId -Cookie $Cookie
        if ($RequireInit -and ((Get-LobbyValue $data 'status') -ne 'init' -or (Get-LobbyCancelTarget -Data $data -ModId $ModId) -cne $initialTarget)) {
            throw '上传期间平台状态或原资源已变化，未更新资源或申请自测，请先核对。'
        }
        $updateData = New-LobbyUpdateData -Data $data -UploadBody $upload.Body -UploadSign $upload.Sign -PackageName $packageName -ResourceIndex $index
        $state.phase = 'updating'
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host 'ZIP 已上传，正在更新项目测试资源……'
        $projectPath = '/items/categories/pe/' + [uri]::EscapeDataString($ModId)
        $null = Invoke-LobbyApiRequest -Method POST -Path ($projectPath + '/update') -Cookie $Cookie -Data $updateData
        $state.phase = 'submitting'
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host '正在申请自测……'
        $null = Invoke-LobbyApiRequest -Method PUT -Path ($projectPath + '/self-test-apply') -Cookie $Cookie -Data @{ self_test_pass_check = $true }
        $state.phase = 'submitted'
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host '平台已接受自测申请，等待本次资源就绪……'
        $status = Wait-LobbySelfTest -ModId $ModId -Cookie $Cookie -ExpectedPackageName $packageName -ExpectedSign $upload.Sign -ResourceIndex $index -WaitTimeoutSeconds $WaitTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
        $state.phase = 'ready'
        $state['status'] = $status
        Write-LobbySelfTestState -Path $StatePath -State $state
        Write-Host '本次自测版本已就绪，可以进入联机大厅测试。游戏功能仍需进服验收。' -ForegroundColor Green
        return [pscustomobject]@{ Status = $status; ModId = $ModId; PackagePath = $package.Path; Sha256 = $package.Sha256; StatePath = $StatePath }
    }
    catch {
        $state['failedAtPhase'] = $state.phase
        $state.phase = 'needs_check'
        try { Write-LobbySelfTestState -Path $StatePath -State $state } catch { Write-Warning '未能保存本次状态记录。' }
        Write-Host '流程已停止；成功生成的 ZIP 已保留。没有自动重放上传、资源更新或自测申请。' -ForegroundColor Yellow
        throw
    }
}
