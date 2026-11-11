[CmdletBinding()]
param([string]$TempRoot = $env:TEMP)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$packagerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $packagerRoot 'LobbySelfTest.ps1')
$script:checks = 0
$script:queue = New-Object System.Collections.Queue
$script:calls = New-Object System.Collections.ArrayList
$modId = '1234567890'
$projectName = 'Fixture Project'
$testRoot = Join-Path ([IO.Path]::GetFullPath($TempRoot)) ('lobbymap-selftest-cancel-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$statePath = Join-Path $testRoot 'state.json'

function Assert-True {
    param([bool]$Value, [string]$Label)
    $script:checks++
    if (-not $Value) { throw ('FAILED: ' + $Label) }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Label)
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true }
    Assert-True $caught $Label
}
function New-Project {
    param([string]$Status, [string]$Id = $modId, [string]$Name = $projectName, [string]$Package = 'old.zip')
    return [pscustomobject]@{ item_id = $Id; item_name = $Name; status = $Status; res = @([pscustomobject]@{ res_name = $Package }) }
}
function Add-Reply {
    param([string]$Method, $Data = $null, [string]$Status = 'ok', [int]$Http = 200, [string]$Failure = '')
    $script:queue.Enqueue(@{ Method = $Method; Data = $Data; Status = $Status; Http = $Http; Failure = $Failure })
}
function Reset-Scenario {
    $script:queue.Clear()
    $script:calls.Clear()
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
}
function Invoke-LobbyHttpRequest {
    param($Method, $Uri, $Cookie, $JsonBody)
    if ($script:queue.Count -eq 0) { throw 'Offline test refuses unqueued network request.' }
    $next = $script:queue.Dequeue()
    Assert-True ($Method -ceq $next.Method) 'request order'
    $null = $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $JsonBody })
    if ($Method -eq 'PUT') {
        Assert-True ($Uri -ceq ('https://mc-launcher.webapp.163.com/items/categories/pe/' + $modId + '/cancel_self_test')) 'verified cancel endpoint'
        Assert-True ([string]::IsNullOrEmpty($JsonBody)) 'cancel sends no body'
        $journal = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($journal.phase -ceq 'cancelling') 'journal precedes cancel request'
    }
    if ($next.Failure) { throw $next.Failure }
    return [pscustomobject]@{ StatusCode = $next.Http; Body = (@{ status = $next.Status; data = $next.Data } | ConvertTo-Json -Depth 10); Signature = '' }
}
function Invoke-Cancel {
    Stop-LobbySelfTest -ModId $modId -Cookie 'OFFLINE_COOKIE' -StatePath $statePath -ExpectedProjectName $projectName -WaitTimeoutSeconds 0 -PollIntervalSeconds 0
}
function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}

try {
    Add-Reply GET (New-Project init)
    $result = Invoke-Cancel
    Assert-True ($result.CancellationStatus -ceq 'not_needed' -and $script:calls.Count -eq 1) 'init skips cancel'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'init preserves original journal'

    foreach ($status in @('self_test', 'self_test_prepare')) {
        Reset-Scenario
        Add-Reply GET (New-Project $status)
        Add-Reply PUT
        Add-Reply GET (New-Project init)
        $result = Invoke-Cancel
        $record = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($result.CancellationStatus -ceq 'cancelled' -and $record.phase -ceq 'cancelled') ($status + ' confirmed cancelled')
        Assert-True ($script:queue.Count -eq 0 -and $script:calls.Count -eq 3) 'one write and readback'
        Assert-True ((Get-Content -LiteralPath $statePath -Raw) -notmatch 'OFFLINE_COOKIE') 'journal contains no credential'
    }
    Reset-Scenario
    Add-Reply GET (New-Project self_test_prepare)
    Add-Reply PUT
    Add-Reply GET (New-Project self_test_prepare)
    Add-Reply GET (New-Project init)
    $result = Stop-LobbySelfTest -ModId $modId -Cookie 'OFFLINE_COOKIE' -StatePath $statePath -ExpectedProjectName $projectName -WaitTimeoutSeconds 2 -PollIntervalSeconds 0
    Assert-True ($result.CancellationStatus -ceq 'cancelled' -and @($script:calls | Where-Object Method -eq PUT).Count -eq 1) 'delayed propagation polls reads without repeating cancel'
    foreach ($status in @('online', 'reviewing', 'preparing', 'unknown')) {
        Reset-Scenario
        Add-Reply GET (New-Project $status)
        Assert-Throws { Invoke-Cancel } ($status + ' is not cancelled')
        Assert-True ($script:calls.Count -eq 1 -and -not (Test-Path -LiteralPath $statePath)) 'unsupported status writes nothing'
    }
    $currentTarget = Get-LobbyCancelTarget -Data (New-Project self_test) -ModId $modId -ExpectedProjectName 'Old Display Name'
    $renamedTarget = Get-LobbyCancelTarget -Data (New-Project self_test -Name '同一作品的新显示名') -ModId $modId -ExpectedProjectName $projectName
    Assert-True ($currentTarget -ceq $renamedTarget) 'renaming does not change project or resource identity'
    foreach ($project in @((New-Project self_test -Id '123'), (New-Project self_test -Id ''), (New-Project self_test -Package ''))) {
        Reset-Scenario
        Add-Reply GET $project
        Assert-Throws { Invoke-Cancel } 'identity or resource mismatch rejected'
        Assert-True ($script:calls.Count -eq 1) 'mismatch never sends cancel'
    }
    foreach ($failure in @('timeout', 'http', 'rejected', 'unconfirmed', 'changed', 'wrong_state', 'read_failure')) {
        Reset-Scenario
        Add-Reply GET (New-Project self_test)
        switch ($failure) {
            timeout { Add-Reply PUT -Failure 'simulated timeout' }
            http { Add-Reply PUT -Http 403 }
            rejected { Add-Reply PUT -Status error }
            unconfirmed { Add-Reply PUT; Add-Reply GET (New-Project self_test) }
            changed { Add-Reply PUT; Add-Reply GET (New-Project init -Package 'another.zip') }
            wrong_state { Add-Reply PUT; Add-Reply GET (New-Project online) }
            read_failure { Add-Reply PUT; Add-Reply GET -Failure 'simulated read failure' }
        }
        Assert-Throws { Invoke-Cancel } ($failure + ' stops workflow')
        $record = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($record.phase -ceq 'needs_check' -and $record.failedAtPhase -ceq 'cancelling') 'uncertain cancellation journal preserved'
        Assert-True (@($script:calls | Where-Object Method -eq PUT).Count -eq 1 -and $script:queue.Count -eq 0) 'failed cancel never retried'
    }

    # Actual entry in a child process, with fake credentials, transport and pack/upload operations.
    $appRoot = Join-Path $testRoot 'entry'
    $null = New-Item -ItemType Directory -Path $appRoot
    Copy-Item -LiteralPath (Join-Path $packagerRoot 'Upload-LobbySelfTest.ps1') -Destination $appRoot
    Write-Utf8 (Join-Path $appRoot 'PackageIdentity.ps1') 'function Assert-MapPackageSource { param($SourcePath, $PackagePath, $ExpectedSourceDigest, [switch]$RequireFresh, $Settings) [pscustomobject]@{SourceDigest="offline-digest";SourceDigestAlgorithm="offline";RandomizedUuidCount=4} }'
    $moduleText = Get-Content -LiteralPath (Join-Path $packagerRoot 'LobbySelfTest.ps1') -Raw -Encoding UTF8
    $fakeTransport = @'
$script:fixtureRoot = $PSScriptRoot
function Get-LobbyProject {
    param($ModId, $Cookie)
    $data = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'remote.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot 'calls.txt') -Value 'get'
    $nextPath = Join-Path $script:fixtureRoot 'remote-next.json'
    if (Test-Path -LiteralPath $nextPath) { Move-Item -LiteralPath $nextPath -Destination (Join-Path $script:fixtureRoot 'remote.json') -Force }
    return $data
}
function Invoke-LobbyHttpRequest {
    param($Method, $Uri, $Cookie, $JsonBody)
    if ($Method -ne 'PUT' -or -not $Uri.EndsWith('/cancel_self_test')) { throw 'Unexpected offline request.' }
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot 'calls.txt') -Value 'cancel'
    $remotePath = Join-Path $script:fixtureRoot 'remote.json'
    $data = Get-Content -LiteralPath $remotePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $data.status = 'init'
    $data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $remotePath -Encoding UTF8
    if (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'timeout')) { throw 'Simulated response lost after accepted cancel.' }
    return [pscustomobject]@{ StatusCode = 200; Body = '{"status":"ok"}' }
}
function Start-LobbySelfTest {
    param($PackagePath, $ModId, $Cookie, $ResourceIndex, $WaitTimeoutSeconds, $PollIntervalSeconds, $StatePath, [switch]$RequireInit)
    if (-not $RequireInit) { throw 'Replacement upload must require init.' }
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot 'calls.txt') -Value 'upload'
    return [pscustomobject]@{ ModId = $ModId; Status = 'self_test' }
}
'@
    Write-Utf8 (Join-Path $appRoot 'LobbySelfTest.ps1') ($moduleText + [Environment]::NewLine + $fakeTransport)
    Write-Utf8 (Join-Path $appRoot 'LobbySelfTestConfig.ps1') ('function Get-LobbySelfTestConfig { param($Path, [switch]$Configure, [switch]$NonInteractive) return [pscustomobject]@{ ModId = ''' + $modId + '''; Cookie = ''OFFLINE_COOKIE''; SourcePath = ''fixture-source''; OutputDirectory = ''fixture-output'' } }')
    Write-Utf8 (Join-Path $appRoot 'Pack-LobbyMap.ps1') 'param($SourcePath, $OutputDirectory, [switch]$PassThru, $ConfigPath, $ArchiveRoot, $ExcludePattern) Add-Content -LiteralPath (Join-Path $PSScriptRoot ''calls.txt'') -Value ''pack''; [pscustomobject]@{ Path = ''offline.zip'' }'
    $entryState = Join-Path $appRoot 'lobby-test.last.json'
    $callPath = Join-Path $appRoot 'calls.txt'
    $remotePath = Join-Path $appRoot 'remote.json'
    function Invoke-Entry {
        param([string]$Mode, [string]$ExpectedId = $modId, [int]$WaitSeconds = 0, [string]$ExpectedName = $projectName)
        if (Test-Path -LiteralPath $callPath) { Remove-Item -LiteralPath $callPath }
        $options = @{ NonInteractive = $true; PassThru = $true; ExpectedModId = $ExpectedId; ExpectedProjectName = $ExpectedName; WaitTimeoutSeconds = $WaitSeconds; PollIntervalSeconds = 0 }
        if ($Mode -eq 'status') { $options.StatusOnly = $true }
        elseif ($Mode -eq 'cancel') { $options.CancelOnly = $true }
        else { $options.CancelPreviousSelfTest = $true }
        # Serialize a local invocation script; no real values or credentials are interpolated.
        $invokeFile = Join-Path $testRoot 'invoke.ps1'
        $argumentFile = Join-Path $testRoot 'arguments.xml'
        $options | Export-Clixml -LiteralPath $argumentFile
        Write-Utf8 $invokeFile 'param($Entry, $Arguments) $opts = Import-Clixml -LiteralPath $Arguments; & $Entry @opts; if ($LASTEXITCODE) { exit $LASTEXITCODE }'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invokeFile -Entry (Join-Path $appRoot 'Upload-LobbySelfTest.ps1') -Arguments $argumentFile)
        $code = $LASTEXITCODE
        $calls = if (Test-Path -LiteralPath $callPath) { @(Get-Content -LiteralPath $callPath) } else { @() }
        return [pscustomobject]@{ Code = $code; Calls = ($calls -join ','); Output = ($output -join "`n") }
    }

    Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry upload
    if ($entry.Code -ne 0 -or $entry.Calls -cne 'get,get,cancel,get,pack,upload') { Write-Host ('ENTRY-DEBUG code=' + $entry.Code + ' calls=' + $entry.Calls); Write-Host $entry.Output }
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,cancel,get,pack,upload') 'entry cancels and verifies before packing and uploading'
    Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry cancel
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,cancel,get') 'CancelOnly never packs or uploads'
    $entry = Invoke-Entry status
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get' -and $entry.Output -match 'cancelled') 'Status confirms cancellation without writing remotely'
    Assert-True ((Get-Content -LiteralPath $entryState -Raw -Encoding UTF8 | ConvertFrom-Json).phase -ceq 'cancelled') 'Status does not misreport cancellation as rejection'

    Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
    Write-Utf8 (Join-Path $appRoot 'timeout') ''
    $entry = Invoke-Entry upload
    Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq 'get,get,cancel') 'lost response stops before packing/upload'
    $entry = Invoke-Entry upload
    Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq 'get') 'retry blocked until status reconciles cancellation'
    $entry = Invoke-Entry status
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get' -and $entry.Output -match 'cancelled') 'Status recovers an accepted cancel with lost response'
    Remove-Item -LiteralPath (Join-Path $appRoot 'timeout')
    $entry = Invoke-Entry upload
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,pack,upload') 'confirmed cancellation resumes without duplicate cancel'

    # Pending upload records are automatically queried and reconciled before a new upload.
    foreach ($phase in @('updating', 'submitting', 'submitted')) {
        foreach ($failed in @($false, $true)) {
            $pending = @{ modId = $modId; phase = $phase; resourceIndex = 0; packageName = 'old.zip' }
            if ($failed) { $pending.phase = 'needs_check'; $pending.failedAtPhase = $phase }
            Write-Utf8 $entryState ($pending | ConvertTo-Json)
            Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
            $entry = Invoke-Entry upload
            Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,cancel,get,pack,upload') ($phase + ' automatically reconciles before one replacement upload')
            Assert-True ($entry.Output -match '自动查询确认上次版本已就绪') 'automatic status result shown'
        }
    }
    $pending = @{ modId = $modId; phase = 'submitted'; resourceIndex = 0; packageName = 'old.zip' }
    Write-Utf8 $entryState ($pending | ConvertTo-Json)
    Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry upload -ExpectedName 'Legacy Display Name'
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,cancel,get,pack,upload') 'legacy shortcut name does not block the same platform project'
    Assert-True ($entry.Output -match '作品显示名称已变化') 'rename is shown as information'
    Write-Utf8 $entryState ($pending | ConvertTo-Json)
    Write-Utf8 $remotePath ((New-Project init) | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry upload
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,pack,upload') 'matching init reconciles then uploads without cancel'

    Write-Utf8 $entryState ($pending | ConvertTo-Json)
    Write-Utf8 $remotePath ((New-Project self_test_prepare) | ConvertTo-Json -Depth 8)
    Write-Utf8 (Join-Path $appRoot 'remote-next.json') ((New-Project self_test -Name '同一作品的新显示名') | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry upload -WaitSeconds 2
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get,get,get,cancel,get,pack,upload') 'preparing task can be renamed while polling and still resolves by project ID'

    foreach ($remote in @((New-Project self_test_prepare), (New-Project self_test -Package 'other.zip'), (New-Project self_test -Id '123'), (New-Project self_test -Id ''), (New-Project online), (New-Project reviewing))) {
        Write-Utf8 $entryState ($pending | ConvertTo-Json)
        $originalHash = (Get-FileHash -LiteralPath $entryState).Hash
        Write-Utf8 $remotePath ($remote | ConvertTo-Json -Depth 8)
        $entry = Invoke-Entry upload
        Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq 'get') 'unconfirmed or different task never cancelled or uploaded'
        Assert-True ((Get-FileHash -LiteralPath $entryState).Hash -ceq $originalHash) 'unsuccessful automatic reconciliation preserves original journal'
    }
    Write-Utf8 $entryState ($pending | ConvertTo-Json)
    Write-Utf8 $remotePath ((New-Project self_test) | ConvertTo-Json -Depth 8)
    $entry = Invoke-Entry status
    Assert-True ($entry.Code -eq 0 -and $entry.Calls -ceq 'get') 'explicit StatusOnly remains read-only despite recoverable task'
    foreach ($phase in @('updating', 'submitting', 'submitted', 'cancelling')) {
        Write-Utf8 $entryState (@{ modId = $modId; phase = $phase } | ConvertTo-Json)
        $entry = Invoke-Entry upload
        Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq 'get') ($phase + ' missing correlation data blocks cancellation and upload')
    }
    $entry = Invoke-Entry upload -ExpectedId '123'
    Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq '') 'identity checked under lock before network'
    $lock = [IO.File]::Open((Join-Path $appRoot 'lobby-test.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $entry = Invoke-Entry upload
        Assert-True ($entry.Code -ne 0 -and $entry.Calls -ceq '') 'busy lock prevents cancellation and upload'
    }
    finally { $lock.Dispose() }
    Write-Output ('PASS: ' + $script:checks + ' cancellation checks; no real credentials or network.')
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\') + '\lobbymap-selftest-cancel-'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
