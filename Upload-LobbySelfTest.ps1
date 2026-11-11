[CmdletBinding()]
param(
    [string]$SourcePath = '',
    [string]$OutputDirectory = '',
    [string]$PackagePath = '',
    [string]$ConfigPath = '',
    [int]$ResourceIndex = -1,
    [ValidateRange(0, 86400)][int]$WaitTimeoutSeconds = 900,
    [ValidateRange(0, 60)][int]$PollIntervalSeconds = 3,
    [switch]$ConfigureOnly,
    [switch]$StatusOnly,
    [switch]$CancelOnly,
    [switch]$CancelPreviousSelfTest,
    [string]$ExpectedModId = '',
    [string]$ExpectedProjectName = '',
    [switch]$NonInteractive,
    [switch]$StartNew,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'lobby-test.local.json' }
. (Join-Path $PSScriptRoot 'LobbySelfTestConfig.ps1')
. (Join-Path $PSScriptRoot 'LobbySelfTest.ps1')
. (Join-Path $PSScriptRoot 'PackageIdentity.ps1')

$statePath = Join-Path $PSScriptRoot 'lobby-test.last.json'
$runLock = $null

function Get-UploadSettingValue {
    param([string]$Name)
    if ($null -eq $settings) { return $null }
    $property = $settings.PSObject.Properties[$Name]
    if ($null -ne $property) { return , $property.Value }
    return $null
}

try {
    if ($ConfigureOnly -and $StatusOnly) { throw '配置与查询状态不能同时执行。' }
    if (($CancelOnly -and ($ConfigureOnly -or $StatusOnly -or $CancelPreviousSelfTest -or $PackagePath)) -or
        ($CancelPreviousSelfTest -and ($ConfigureOnly -or $StatusOnly))) { throw '取消自测参数与当前操作冲突。' }
    try {
        $runLock = [System.IO.File]::Open((Join-Path $PSScriptRoot 'lobby-test.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch { throw '另一个配置、上传或查询进程正在运行，请等待其结束。' }
    $settings = Get-LobbySelfTestConfig -Path $ConfigPath -Configure:$ConfigureOnly -NonInteractive:$NonInteractive
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = [string](Get-UploadSettingValue 'SourcePath') }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = [string](Get-UploadSettingValue 'OutputDirectory') }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'packages' }
    if ($ExpectedModId -and $settings.ModId -cne $ExpectedModId) { throw '锁定配置后的项目 ID 与预期目标不一致，已停止。' }
    if ($ConfigureOnly) {
        Write-Host '上传自测配置已保存。Cookie 已使用当前 Windows 用户加密。' -ForegroundColor Green
        return
    }

    $previous = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $previous = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            if (-not $StartNew -and -not $StatusOnly) { throw '上次自测记录无法读取，请核对开发者平台后使用 -StartNew 开始新任务。' }
            if ($StatusOnly) { Write-Warning '上次记录无法读取，本次仅查询平台状态，无法关联之前的上传包。' }
        }
    }

    Write-Host "正在核对开发者平台项目：$($settings.ModId)……"
    $project = Get-LobbyProject -ModId $settings.ModId -Cookie $settings.Cookie
    Assert-LobbyProjectIdentity -Data $project -ModId $settings.ModId
    $currentProjectName = [string](Get-LobbyValue $project 'item_name')
    if ($ExpectedProjectName -and $currentProjectName -and $currentProjectName -cne $ExpectedProjectName) {
        Write-Host ('作品显示名称已变化：{0}；项目 ID 已核对一致，继续处理同一项目。' -f $currentProjectName)
    }
    if ($StatusOnly) {
        $status = [string](Get-LobbyValue $project 'status')
        $safeStatus = $status -replace '[^a-zA-Z0-9_\-]', '?'
        Write-Host "平台当前状态：$safeStatus"
        $previousPhase = [string](Get-LobbyValue $previous 'phase')
        $cancelRecord = $previousPhase -in @('cancelling', 'cancelled') -or
            ($previousPhase -eq 'needs_check' -and (Get-LobbyValue $previous 'failedAtPhase') -eq 'cancelling')
        if ($cancelRecord) {
            if ((Get-LobbyValue $previous 'modId') -cne $settings.ModId) { throw '取消记录不属于当前项目，已停止关联。' }
            $cancelMatches = (Get-LobbyCancelTarget -Data $project -ModId $settings.ModId -ExpectedProjectName $ExpectedProjectName) -ceq (Get-LobbyValue $previous 'cancelTargetFingerprint')
            $cancelStatus = if ($cancelMatches) { 'pending' } else { 'target_changed' }
            if ($cancelMatches -and $status -eq 'init') {
                $state = @{}
                foreach ($property in $previous.PSObject.Properties) { $state[$property.Name] = $property.Value }
                $state['phase'] = 'cancelled'
                $state['status'] = $status
                $state.Remove('failedAtPhase')
                if (-not (Get-LobbyValue $state 'cancelledAt')) { $state['cancelledAt'] = [datetime]::UtcNow.ToString('o') }
                Write-LobbySelfTestState -Path $statePath -State $state
                $cancelStatus = 'cancelled'
                Write-Host '已通过查询确认旧版自测取消。此次查询没有取消或上传操作。'
            }
            else { Write-Host '原取消结果尚未确认，请核对平台；此次查询没有重复取消。' }
            if ($PassThru) { [pscustomobject]@{ ModId = $settings.ModId; Status = $status; MatchesLastPackage = $false; CancellationStatus = $cancelStatus } }
            return
        }
        $matches = $false
        if ($null -ne $previous -and (Get-LobbyValue $previous 'modId') -eq $settings.ModId) {
            $resources = Get-LobbyValue $project 'res'
            $index = [int](Get-LobbyValue $previous 'resourceIndex')
            if ($resources -is [array] -and $index -ge 0 -and $index -lt $resources.Count) {
                $matches = (Get-LobbyValue $resources[$index] 'res_name') -ceq (Get-LobbyValue $previous 'packageName')
            }
            if ($matches -and $status -in @('self_test', 'init')) {
                $state = @{}
                foreach ($property in $previous.PSObject.Properties) { $state[$property.Name] = $property.Value }
                $state.phase = if ($status -eq 'self_test') { 'ready' } else { 'rejected' }
                $state['status'] = $status
                Write-LobbySelfTestState -Path $statePath -State $state
                if ($status -eq 'self_test') { Write-Host '上次上传的自测版本已就绪，可以进服验收。' -ForegroundColor Green }
                else { Write-Host '平台报告上次资源自测未通过，请到开发者平台查看原因。' -ForegroundColor Yellow }
            }
        }
        if (-not $matches -or $status -notin @('self_test', 'init')) {
            Write-Host '尚未确认上次上传的自测结果，请在开发者平台核对。此次查询没有上传或提交操作。'
        }
        if ($PassThru) { [pscustomobject]@{ ModId = $settings.ModId; Status = $status; MatchesLastPackage = $matches } }
        return
    }

    if ($null -ne $previous -and ($CancelOnly -or $CancelPreviousSelfTest) -and (Get-LobbyValue $previous 'modId') -cne $settings.ModId) {
        throw '原任务不属于本次项目，已停止取消和上传。'
    }
    if ($null -ne $previous -and (Get-LobbyValue $previous 'modId') -eq $settings.ModId) {
        $phase = [string](Get-LobbyValue $previous 'phase')
        $failedAt = [string](Get-LobbyValue $previous 'failedAtPhase')
        if ($phase -eq 'cancelling' -or ($phase -eq 'needs_check' -and $failedAt -eq 'cancelling')) {
            throw '原取消请求结果尚未确认，请先查询状态；不会重复取消或上传。'
        }
        if (-not $StartNew -and ($phase -in @('updating', 'submitting', 'submitted') -or
            ($phase -eq 'needs_check' -and $failedAt -in @('updating', 'submitting', 'submitted')))) {
            Write-Host '上次任务已有资源更新或自测提交，正在自动查询并核对原任务……'
            $reconciled = Resolve-LobbyPreviousUpload -ModId $settings.ModId -Cookie $settings.Cookie -StatePath $statePath -PreviousState $previous -InitialProject $project -ExpectedProjectName $ExpectedProjectName -WaitTimeoutSeconds $WaitTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
            $project = $reconciled.Project
            $previous = $reconciled.State
        }
    }

    $null = Get-LobbyResourceIndex -Data $project -ResourceIndex $ResourceIndex
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw '尚未配置地图源目录。请运行“配置上传自测.cmd”填写源目录，或使用 -SourcePath 指定。' }
    if ($PackagePath) {
        # A supplied ZIP is a content reference, never the base for a new upload.
        # Validate before cancelling the old test, then build from current source.
        $null = Assert-MapPackageSource -SourcePath $SourcePath -PackagePath $PackagePath -Settings $settings
        Write-Host '指定 ZIP 与当前源码已核对；本次上传将全量生成新的 UUID 包，所有版本号保持原值。'
    }
    $cancellation = $null
    if ($CancelOnly -or $CancelPreviousSelfTest) {
        $cancellation = Stop-LobbySelfTest -ModId $settings.ModId -Cookie $settings.Cookie -StatePath $statePath -PreviousState $previous -ExpectedProjectName $ExpectedProjectName
        if ($CancelOnly) {
            if ($PassThru) { $cancellation }
            return
        }
    }
    Write-Host '登录与项目检查通过，开始全量打包并生成本次 UUID……'
    $package = & (Join-Path $PSScriptRoot 'Pack-LobbyMap.ps1') -SourcePath $SourcePath -OutputDirectory $OutputDirectory -ConfigPath $ConfigPath -PassThru
    if ($null -eq $package -or -not (Get-LobbyValue $package 'Path')) { throw '打包器未返回有效的新包，未进行上传。' }
    $PackagePath = $package.Path
    $verified = Assert-MapPackageSource -SourcePath $SourcePath -PackagePath $PackagePath -ExpectedSourceDigest ([string](Get-LobbyValue $package 'SourceDigest')) -RequireFresh -Settings $settings
    $startParameters = @{ PackageSourceDigest = $verified.SourceDigest; SourceDigestAlgorithm = $verified.SourceDigestAlgorithm; RandomizedUuidCount = $verified.RandomizedUuidCount }
    if ($CancelPreviousSelfTest) { $startParameters.RequireInit = $true }
    $result = Start-LobbySelfTest -PackagePath $PackagePath -ModId $settings.ModId -Cookie $settings.Cookie -ResourceIndex $ResourceIndex -WaitTimeoutSeconds $WaitTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds -StatePath $statePath @startParameters
    $result | Add-Member -NotePropertyName SourceDigest -NotePropertyValue $verified.SourceDigest
    $result | Add-Member -NotePropertyName SourceDigestAlgorithm -NotePropertyValue $verified.SourceDigestAlgorithm
    $result | Add-Member -NotePropertyName RandomizedUuidCount -NotePropertyValue $verified.RandomizedUuidCount
    if ($null -ne $cancellation) { $result | Add-Member -NotePropertyName CancellationStatus -NotePropertyValue $cancellation.CancellationStatus }
    if ($PassThru) { $result }
}
catch {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host '开发者平台：https://mcdev.webapp.163.com/'
    exit 1
}
finally {
    if ($null -ne $runLock) { $runLock.Dispose() }
    $settings = $null
}
