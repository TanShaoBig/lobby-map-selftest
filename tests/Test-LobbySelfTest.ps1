[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:CheckCount = 0
$script:HttpCalls = New-Object System.Collections.ArrayList
$script:HttpQueue = New-Object System.Collections.Queue

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
    $script:CheckCount++
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    Assert-True -Condition ($Actual -ceq $Expected) -Message "$Message；实际=[$Actual]，预期=[$Expected]"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $caught = $false
    try { & $Action | Out-Null }
    catch { $caught = $true }
    Assert-True -Condition $caught -Message $Message
}

function Write-TestUtf8 {
    param([string]$Path, [string]$Text, [switch]$Bom)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
}

function Get-TestManifest {
    param([string]$Kind)
    return (@{
        format_version = 2
        header = @{ name = '测试包'; description = 'offline fixture'; uuid = [guid]::NewGuid().ToString(); version = @(1, 0, 0) }
        modules = @(@{ type = $Kind; uuid = [guid]::NewGuid().ToString(); version = @(1, 0, 0) })
    } | ConvertTo-Json -Depth 8)
}

function New-TestMap {
    param([string]$Root)
    foreach ($relative in @('behavior_packs/test_behavior/entities', 'resource_packs/test_resource/textures', 'db')) {
        New-Item -ItemType Directory -Path (Join-Path $Root $relative) -Force | Out-Null
    }
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/manifest.json') -Text (Get-TestManifest 'data')
    Write-TestUtf8 -Path (Join-Path $Root 'resource_packs/test_resource/manifest.json') -Text (Get-TestManifest 'resources')
    $behavior = Get-Content -LiteralPath (Join-Path $Root 'behavior_packs/test_behavior/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $resource = Get-Content -LiteralPath (Join-Path $Root 'resource_packs/test_resource/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $behavior | Add-Member -NotePropertyName dependencies -NotePropertyValue @(
        [pscustomobject]@{ uuid = $resource.header.uuid; version = @(1, 0, 0) },
        [pscustomobject]@{ uuid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; version = @(9, 2, 1) },
        [pscustomobject]@{ module_name = '@minecraft/server'; version = '1.0.0' })
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/manifest.json') -Text ($behavior | ConvertTo-Json -Depth 12)
    foreach ($name in @('level.dat', 'level.dat_old', 'levelname.txt', 'world_icon.jpeg')) {
        Write-TestUtf8 -Path (Join-Path $Root $name) -Text "test $name"
    }
    Write-TestUtf8 -Path (Join-Path $Root 'world_behavior_packs.json') -Text (ConvertTo-Json -InputObject @(@{ pack_id = $behavior.header.uuid; version = @(1, 0, 0) }) -Depth 8)
    Write-TestUtf8 -Path (Join-Path $Root 'world_resource_packs.json') -Text (ConvertTo-Json -InputObject @(@{ pack_id = $resource.header.uuid; version = @(1, 0, 0) }) -Depth 8)
    Write-TestUtf8 -Path (Join-Path $Root 'db/CURRENT') -Text 'fixture'
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/keep.py') -Text 'print("fixture")'
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/omit.pyc') -Text 'omit'
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/.gitignore') -Text '*'
    New-Item -ItemType Directory -Path (Join-Path $Root 'behavior_packs/test_behavior/__pycache__') -Force | Out-Null
    Write-TestUtf8 -Path (Join-Path $Root 'behavior_packs/test_behavior/__pycache__/omit.pyc') -Text 'omit'
    Write-TestUtf8 -Path (Join-Path $Root 'omit-root.txt') -Text 'omit'
}

function New-TestModData {
    return ('{"status":"processing","author_info":{"name":"owner"},"res":[{"res_name":"previous.zip","res_url":"previous-url","res_id":"old-id","res_info":{},"cdn_info":{},"cdn_url":"old-cdn"}],"nested":{"value":null,"empty":[],"list":[null,{"x":null}]},"subject_id":"","commercial_time":null,"pri_effect_type":"","sub_effect_type":null,"dlc_info":{"master":null,"slave_list":null},"description":"preserve description"}' | ConvertFrom-Json)
}

function New-TestZip {
    param([string]$Path, [string[]]$Entries)
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            if (-not $name.EndsWith('/')) {
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write('fixture') } finally { $writer.Dispose() }
            }
        }
    }
    finally { $zip.Dispose() }
}

$packagerRoot = Split-Path -Parent $PSScriptRoot
$packScript = Join-Path $packagerRoot 'Pack-LobbyMap.ps1'
$uploadModule = Join-Path $packagerRoot 'LobbySelfTest.ps1'
. (Join-Path $packagerRoot 'PackageIdentity.ps1')
$tempParent = $env:TEMP
$fixtureRoot = Join-Path $tempParent ('lobbymap_selftest_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

try {
    $sourceRoot = Join-Path $fixtureRoot 'source'
    $outputRoot = Join-Path $fixtureRoot 'packages'
    New-TestMap -Root $sourceRoot
    $originalSource = Get-MapSourceSnapshot $sourceRoot
    $packageDate = [datetime]'2026-10-22T12:34:56'
    $package = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -PassThru
    Assert-True -Condition ($null -ne $package) -Message '打包返回本轮成功对象'
    Assert-True -Condition (Test-Path -LiteralPath $package.Path -PathType Leaf) -Message '打包返回本轮 ZIP 路径'
    Assert-True -Condition ($package.Length -gt 0) -Message '返回包体大小'
    Assert-Equal -Actual $package.Sha256 -Expected ((Get-FileHash -LiteralPath $package.Path -Algorithm SHA256).Hash) -Message '返回正确 SHA256'
    $firstPackageHash = (Get-FileHash -LiteralPath $package.Path -Algorithm SHA256).Hash
    $secondPackage = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -PassThru
    Assert-True -Condition ($secondPackage.Path -cne $package.Path) -Message '同秒生成新文件名'
    Assert-Equal -Actual ((Get-FileHash -LiteralPath $package.Path -Algorithm SHA256).Hash) -Expected $firstPackageHash -Message '保留已有包'
    Assert-Equal -Actual (Get-MapSourceSnapshot $sourceRoot).Digest -Expected $originalSource.Digest -Message '连续打包不改源工程'
    Assert-Equal -Actual $package.RandomizedUuidCount -Expected 4 -Message '包头和所有模块 UUID 都已随机'
    Assert-True -Condition ($package.Sha256 -cne $secondPackage.Sha256) -Message '同源连续打包内容标识不同'
    $null = Assert-MapPackageSource -SourcePath $sourceRoot -PackagePath $package.Path -RequireFresh
    $null = Assert-MapPackageSource -SourcePath $sourceRoot -PackagePath $secondPackage.Path -RequireFresh
    $firstArchive = [IO.Compression.ZipFile]::OpenRead($package.Path)
    $secondArchive = [IO.Compression.ZipFile]::OpenRead($secondPackage.Path)
    try {
        $firstIds = @()
        $secondIds = @()
        foreach ($path in @('behavior_packs/test_behavior/manifest.json', 'resource_packs/test_resource/manifest.json')) {
            $one = Convert-MapIdentityJson (Read-MapArchiveText $firstArchive.GetEntry('map/' + $path))
            $two = Convert-MapIdentityJson (Read-MapArchiveText $secondArchive.GetEntry('map/' + $path))
            $firstIds += @($one.header.uuid) + @($one.modules.uuid)
            $secondIds += @($two.header.uuid) + @($two.modules.uuid)
            Assert-Equal -Actual ($one.header.version -join '.') -Expected '1.0.0' -Message '保留包头版本'
            Assert-Equal -Actual ($one.modules[0].version -join '.') -Expected '1.0.0' -Message '保留模块版本'
        }
        Assert-True -Condition (@($firstIds | Where-Object { $secondIds -contains $_ }).Count -eq 0) -Message '两次打包没有复用任何 UUID'
    }
    finally { $firstArchive.Dispose(); $secondArchive.Dispose() }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($package.Path)
    try { $entryNames = @($zip.Entries | ForEach-Object { $_.FullName }) }
    finally { $zip.Dispose() }
    Assert-True -Condition ($entryNames -contains 'map/behavior_packs/test_behavior/entities/') -Message '保留行为包空目录'
    Assert-True -Condition ($entryNames -contains 'map/resource_packs/test_resource/textures/') -Message '保留资源包空目录'
    Assert-True -Condition ($entryNames -contains 'map/behavior_packs/test_behavior/keep.py') -Message '包含运行脚本'
    Assert-True -Condition (@($entryNames | Where-Object { $_ -match '(?i)(\.pyc$|__pycache__|(^|/)\.gitignore$)' }).Count -eq 0) -Message '排除 pyc、缓存和 gitignore'
    Assert-True -Condition ($entryNames -notcontains 'map/omit-root.txt') -Message '根目录白名单生效'
    Assert-True -Condition (@($entryNames | Where-Object { -not $_.StartsWith('map/') }).Count -eq 0) -Message '全部内容位于 map 顶层'

    $requiredFile = Join-Path $sourceRoot 'world_icon.jpeg'
    Remove-Item -LiteralPath $requiredFile
    Assert-Throws -Action { & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PassThru } -Message '缺少必要文件时拒绝打包'
    Write-TestUtf8 -Path $requiredFile -Text 'fixture'
    $manifestPath = Join-Path $sourceRoot 'behavior_packs/test_behavior/manifest.json'
    $originalManifest = [System.IO.File]::ReadAllText($manifestPath)
    Write-TestUtf8 -Path $manifestPath -Text $originalManifest -Bom
    Assert-Throws -Action { & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PassThru } -Message 'BOM manifest 拒绝打包'
    Write-TestUtf8 -Path $manifestPath -Text $originalManifest
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.tmp').Count -eq 0) -Message '失败后没有残留临时包'

    if (-not (Test-Path -LiteralPath $uploadModule -PathType Leaf)) { throw "上传模块尚未生成：$uploadModule" }
    . $uploadModule

    $checkedPackage = Assert-LobbyPackage -Path $package.Path
    Assert-Equal -Actual $checkedPackage.Path -Expected $package.Path -Message '上传前校验固定包路径'
    Assert-Equal -Actual $checkedPackage.Sha256 -Expected $firstPackageHash -Message '上传前校验包哈希'
    $badPackagePath = Join-Path $fixtureRoot 'bad-root.zip'
    New-TestZip -Path $badPackagePath -Entries @('level.dat')
    Assert-Throws -Action { Assert-LobbyPackage -Path $badPackagePath } -Message '拒绝没有顶层目录的 ZIP'

    $uploadBody = "`n{`"url`":`"signed-url`",`"other`": 7}`n"
    $update = New-LobbyUpdateData -Data (New-TestModData) -UploadBody $uploadBody -UploadSign 'test-signature' -PackageName '测试地图.zip'
    Assert-Equal -Actual $update.res[0].res_url.body -Expected $uploadBody -Message '保留上传原文与空白'
    Assert-Equal -Actual $update.res[0].res_url.sign -Expected 'test-signature' -Message '绑定返回签名'
    Assert-Equal -Actual $update.res[0].res_name -Expected '测试地图.zip' -Message '使用本轮包文件名'
    Assert-Equal -Actual $update.res[0].res_url.file_type -Expected 'zip_package' -Message 'ZIP 文件类型'
    Assert-True -Condition (-not $update.ContainsKey('author_info')) -Message '移除只读 author_info'
    foreach ($removed in @('res_id', 'res_info', 'cdn_info', 'cdn_url')) {
        Assert-True -Condition (-not $update.res[0].ContainsKey($removed)) -Message "移除旧资源字段 $removed"
    }
    Assert-Equal -Actual $update.nested.value -Expected '' -Message '嵌套 null 转为空字符串'
    Assert-Equal -Actual $update.nested.list[0] -Expected '' -Message '数组 null 转为空字符串'
    Assert-Equal -Actual $update.nested.list[1].x -Expected '' -Message '数组对象中的 null 转为空字符串'
    Assert-True -Condition ($update.nested.empty -is [array] -and $update.nested.empty.Count -eq 0) -Message '空数组类型不变'
    foreach ($nullable in @('subject_id', 'commercial_time', 'openbeta_time')) {
        Assert-True -Condition ($update.ContainsKey($nullable) -and $null -eq $update[$nullable]) -Message "$nullable 归一化为 null"
    }
    Assert-True -Condition (-not $update.ContainsKey('pri_effect_type') -and -not $update.ContainsKey('sub_effect_type')) -Message '空效果类型删除'
    Assert-True -Condition ($update.dlc_info.master -is [System.Collections.IDictionary] -and $update.dlc_info.master.Count -eq 0) -Message 'dlc master 为对象'
    Assert-True -Condition ($update.dlc_info.slave_list -is [array] -and $update.dlc_info.slave_list.Count -eq 0) -Message 'dlc slave_list 为空数组'
    Assert-Equal -Actual $update.description -Expected 'preserve description' -Message '保留无关元数据'
    $multiple = New-TestModData
    $multiple.res = @($multiple.res[0], ($multiple.res[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json))
    Assert-Throws -Action { New-LobbyUpdateData -Data $multiple -UploadBody $uploadBody -UploadSign 'sign' -PackageName 'test.zip' } -Message '多个资源时禁止隐式替换'
    $selected = New-LobbyUpdateData -Data $multiple -UploadBody $uploadBody -UploadSign 'sign' -PackageName 'test.zip' -ResourceIndex 1
    Assert-Equal -Actual $selected.res[0].res_name -Expected 'previous.zip' -Message '保留未选择的资源'
    Assert-Equal -Actual $selected.res[1].res_name -Expected 'test.zip' -Message '仅替换显式选择资源'
    Assert-Throws -Action { New-LobbyUpdateData -Data $multiple -UploadBody $uploadBody -UploadSign 'sign' -PackageName 'test.zip' -ResourceIndex 2 } -Message '资源索引越界拒绝'

    $reply = Read-LobbyUploadReply -Body ("<html><textarea>" + $uploadBody + '</textarea></html>') -Signature 'signature'
    Assert-Equal -Actual $reply.Body -Expected $uploadBody -Message 'textarea 原文不重写'
    Assert-Equal -Actual $reply.Sign -Expected 'signature' -Message '保存签名头'
    Assert-Throws -Action { Read-LobbyUploadReply -Body '<textarea>{"ok":true}</textarea>' -Signature '' } -Message '缺少签名拒绝'
    Assert-Throws -Action { Read-LobbyUploadReply -Body '<textarea>bad json</textarea>' -Signature 'sign' } -Message '非法上传 JSON 拒绝'
    Assert-Throws -Action { Read-LobbyUploadReply -Body '<html>no textarea</html>' -Signature 'sign' } -Message '没有 textarea 拒绝'
    Assert-Throws -Action { Read-LobbyUploadReply -Body '<textarea>[]</textarea>' -Signature 'sign' } -Message '非对象上传响应拒绝'
    Assert-Throws -Action { Invoke-LobbyHttpRequest -Method GET -Uri 'https://example.invalid/' -Cookie 'test-cookie=fixture' } -Message '真实传输边界拒绝未指定主机'
    Assert-Throws -Action { Invoke-LobbyHttpRequest -Method POST -Uri 'https://pfp.ps.netease.com/x19s/file/new/' -Cookie 'test-cookie=fixture' -PackagePath $package.Path -UploadToken 'token' } -Message '真实传输边界拒绝将账号 Cookie 带到上传主机'
    Assert-Throws -Action { Invoke-LobbyHttpRequest -Method GET -Uri 'https://mc-launcher.webapp.163.com/items/categories/pe/test-mod' -Cookie "cookie=fixture`r`nInjected: test" } -Message '真实传输边界拒绝 Cookie 换行注入'

    # 内存 HttpMessageHandler 接收真正的 HttpClient 请求，检查 multipart 构建与认证隔离。
    Add-Type -ReferencedAssemblies 'System.Net.Http' -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class LobbyTestCaptureHandler : HttpMessageHandler {
    public string UriText;
    public string Method;
    public string Cookie;
    public string ContentType;
    public string Body;
    public int RequestCount;

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        RequestCount++;
        UriText = request.RequestUri.AbsoluteUri;
        Method = request.Method.Method;
        Cookie = request.Headers.Contains("Cookie") ? string.Join(";", request.Headers.GetValues("Cookie")) : "";
        ContentType = request.Content == null || request.Content.Headers.ContentType == null ? "" : request.Content.Headers.ContentType.ToString();
        Body = request.Content == null ? "" : request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        HttpResponseMessage response = new HttpResponseMessage(HttpStatusCode.OK);
        response.Content = new StringContent("<textarea>{\"url\":\"memory-transport\"}</textarea>");
        response.Headers.TryAddWithoutValidation("x-ntes-signature", "transport-signature");
        return Task.FromResult(response);
    }
}
'@
    $getHandler = New-Object LobbyTestCaptureHandler
    $transportReply = Invoke-LobbyHttpRequest -Method GET -Uri 'https://mc-launcher.webapp.163.com/items/categories/pe/test-mod' -Cookie 'test-cookie=fixture' -MessageHandler $getHandler
    Assert-Equal -Actual $getHandler.RequestCount -Expected 1 -Message 'HttpClient 内存传输只请求一次'
    Assert-Equal -Actual $getHandler.Cookie -Expected 'test-cookie=fixture' -Message '实际 HTTP GET 含平台 Cookie'
    Assert-Equal -Actual $transportReply.Signature -Expected 'transport-signature' -Message '实际 HttpClient 读取签名响应头'
    Assert-Equal -Actual $transportReply.StatusCode -Expected 200 -Message '实际 HttpClient 保留响应状态码'
    $uploadHandler = New-Object LobbyTestCaptureHandler
    $null = Invoke-LobbyHttpRequest -Method POST -Uri 'https://pfp.ps.netease.com/x19s/file/new/' -PackagePath $package.Path -UploadToken 'transport-upload-token' -UploadFileName 'transport-map.zip' -MessageHandler $uploadHandler
    Assert-Equal -Actual $uploadHandler.Cookie -Expected '' -Message '实际 multipart 请求没有账号 Cookie'
    Assert-True -Condition ($uploadHandler.ContentType.StartsWith('multipart/form-data;')) -Message '实际请求为 multipart/form-data'
    Assert-True -Condition ($uploadHandler.Body -match 'name="?Authorization"?' -and $uploadHandler.Body.Contains('transport-upload-token')) -Message '实际 multipart 含上传 Authorization 字段'
    Assert-True -Condition ($uploadHandler.Body -match 'name="?fpfile"?' -and $uploadHandler.Body.Contains('application/x-zip-compressed')) -Message '实际 multipart 含 fpfile 与 ZIP MIME'
    Assert-True -Condition ($uploadHandler.Body.Contains('transport-map.zip')) -Message '实际 multipart 使用指定远端 ZIP 文件名'
    Assert-True -Condition (-not $uploadHandler.Body.Contains('test-cookie=fixture')) -Message '实际上传正文不含平台 Cookie'
    $jsonHandler = New-Object LobbyTestCaptureHandler
    $testJsonBody = '{"description":"中文测试"}'
    $null = Invoke-LobbyHttpRequest -Method POST -Uri 'https://mc-launcher.webapp.163.com/items/categories/pe/test-mod/update' -Cookie 'test-cookie=fixture' -JsonBody $testJsonBody -MessageHandler $jsonHandler
    Assert-Equal -Actual $jsonHandler.Body -Expected $testJsonBody -Message '实际 JSON 请求保留 UTF8 中文'
    Assert-Equal -Actual $jsonHandler.ContentType -Expected 'application/json; charset=utf-8' -Message '实际 JSON 请求声明 UTF8'

    # 网络流程用进程内响应队列，绝不访问真实平台。
    function Invoke-LobbyHttpRequest {
        param($Method, $Uri, $Cookie, $JsonBody, $PackagePath, $UploadToken, $TimeoutSeconds, $UploadFileName)
        if ($UploadFileName) { $script:LastUploadFileName = [string]$UploadFileName }
        $null = $script:HttpCalls.Add([pscustomobject]@{ Method = [string]$Method; Uri = [string]$Uri; Cookie = [string]$Cookie; JsonBody = $JsonBody; PackagePath = [string]$PackagePath; UploadToken = [string]$UploadToken; UploadFileName = [string]$UploadFileName })
        if ($script:HttpQueue.Count -eq 0) { throw '模拟请求超出预定队列，测试不会访问网络。' }
        $next = $script:HttpQueue.Dequeue()
        if ($next.ContainsKey('Method')) { Assert-Equal -Actual ([string]$Method).ToUpperInvariant() -Expected $next.Method -Message '请求方法符合流程' }
        if ($next.ContainsKey('Path')) { Assert-True -Condition (([string]$Uri).EndsWith($next.Path)) -Message "请求路径符合流程 $($next.Path)" }
        if ($next.ContainsKey('Throw')) { throw $next.Throw }
        return [pscustomobject]@{ StatusCode = $next.StatusCode; Body = $next.Body.Replace('__UPLOADED_PACKAGE_NAME__', $script:LastUploadFileName); Signature = $next.Signature }
    }

    function Add-TestHttpReply {
        param([string]$Method, [string]$Path, [int]$StatusCode = 200, [string]$Body = '{"status":"ok"}', [string]$Signature = '')
        $script:HttpQueue.Enqueue(@{ Method = $Method; Path = $Path; StatusCode = $StatusCode; Body = $Body; Signature = $Signature })
    }

    function Reset-TestHttp {
        $script:HttpCalls.Clear()
        $script:HttpQueue.Clear()
        $script:LastUploadFileName = ''
    }

    function Add-TestUploadStart {
        param([int]$UploadStatus = 200, [string]$UploadReply = '<textarea>{"url":"test-upload"}</textarea>')
        $modJson = @{ status = 'ok'; data = (New-TestModData) } | ConvertTo-Json -Depth 15 -Compress
        Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body $modJson
        Add-TestHttpReply -Method GET -Path '/filepicker/file_token?file_type=zip_package&secure=true' -Body '{"status":"ok","data":{"token":"test-upload-token"}}'
        Add-TestHttpReply -Method POST -Path '/x19s/file/new/' -StatusCode $UploadStatus -Body $UploadReply -Signature 'test-signature'
        if ($UploadStatus -eq 200) {
            Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body $modJson
        }
    }

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
    Add-TestHttpReply -Method PUT -Path '/items/categories/pe/test-mod/self-test-apply'
    $readyData = New-TestModData
    $readyData.status = 'self_test'
    $readyData.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $readyData } | ConvertTo-Json -Depth 15 -Compress)
    $readyState = Join-Path $fixtureRoot 'ready-state.json'
    $result = Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath $readyState -WaitTimeoutSeconds 3 -PollIntervalSeconds 1 -PackageSourceDigest $package.SourceDigest -SourceDigestAlgorithm $package.SourceDigestAlgorithm -RandomizedUuidCount $package.RandomizedUuidCount
    Assert-Equal -Actual $result.Status -Expected 'self_test' -Message '自测就绪结果'
    Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '完整消费上传提交查询队列'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 7 -Message '成功流程请求数'
    $uploadCall = @($script:HttpCalls | Where-Object { $_.Uri.StartsWith('https://pfp.ps.netease.com/') })[0]
    Assert-Equal -Actual $uploadCall.Cookie -Expected '' -Message '上传主机不携带账号 Cookie'
    Assert-Equal -Actual $uploadCall.UploadToken -Expected 'test-upload-token' -Message '上传仅使用专用 token'
    Assert-True -Condition ($uploadCall.UploadFileName -match '^lobby-map-[0-9TZ]+-[a-fA-F0-9-]+\.zip$') -Message '每次上传生成独立 ASCII 远端文件名'
    foreach ($call in @($script:HttpCalls | Where-Object { $_.Uri.StartsWith('https://mc-launcher.webapp.163.com/') })) {
        Assert-Equal -Actual $call.Cookie -Expected 'test-cookie=fixture' -Message '平台请求带账号 Cookie'
    }
    if (Test-Path -LiteralPath $readyState) {
        $stateText = [System.IO.File]::ReadAllText($readyState)
        Assert-True -Condition ($stateText -notmatch 'test-cookie=fixture|test-upload-token') -Message '状态回执不含认证凭据'
        Assert-Equal -Actual (($stateText | ConvertFrom-Json).packageName) -Expected $uploadCall.UploadFileName -Message '回执保存唯一远端包名'
        $recorded = $stateText | ConvertFrom-Json
        Assert-Equal $recorded.sourceDigest $package.SourceDigest '回执保存本次全量源码摘要'
        Assert-Equal $recorded.sourceDigestAlgorithm $package.SourceDigestAlgorithm '回执标明摘要算法'
        Assert-Equal $recorded.randomizedUuidCount 4 '回执保存本次随机 UUID 数量'
    }

    Reset-TestHttp
    Add-TestUploadStart -UploadStatus 500
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'upload-fail.json') } -Message '上传 HTTP 失败终止'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 3 -Message '上传失败没有更新或提交'

    Reset-TestHttp
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -StatusCode 401 -Body '{"status":"error"}'
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'auth-fail.json') } -Message '登录失效终止'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 1 -Message '登录失效不上传或写入'

    Reset-TestHttp
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = (New-TestModData) } | ConvertTo-Json -Depth 15 -Compress)
    Add-TestHttpReply -Method GET -Path '/filepicker/file_token?file_type=zip_package&secure=true' -Body '{"status":"ok","data":{}}'
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'token-fail.json') } -Message '没有上传 token 时终止'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 2 -Message '没有 token 不发送 ZIP'

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update' -Body '{"status":"error"}'
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'update-fail.json') } -Message '更新拒绝后终止'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 5 -Message '更新失败不提交自测'

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
    $script:HttpQueue.Enqueue(@{ Method = 'PUT'; Path = '/items/categories/pe/test-mod/self-test-apply'; Throw = 'mock timeout' })
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'submit-uncertain.json') } -Message '申请自测超时报告异常'
    Assert-Equal -Actual (@($script:HttpCalls | Where-Object Method -eq 'PUT').Count) -Expected 1 -Message '写请求超时不重放'

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
    Add-TestHttpReply -Method PUT -Path '/items/categories/pe/test-mod/self-test-apply'
    $staleData = New-TestModData
    $staleData.status = 'online'
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $staleData } | ConvertTo-Json -Depth 15 -Compress)
    $readyData = New-TestModData
    $readyData.status = 'self_test'
    $readyData.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $readyData } | ConvertTo-Json -Depth 15 -Compress)
    $result = Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'old-online.json') -WaitTimeoutSeconds 5 -PollIntervalSeconds 1
    Assert-Equal -Actual $result.Status -Expected 'self_test' -Message '等待到新自测状态'
    Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '旧 online 状态没有提前认定完成'

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
    Add-TestHttpReply -Method PUT -Path '/items/categories/pe/test-mod/self-test-apply'
    $failedData = New-TestModData
    $failedData.status = 'init'
    $failedData.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $failedData } | ConvertTo-Json -Depth 15 -Compress)
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'selftest-fail.json') -WaitTimeoutSeconds 0 } -Message '平台 init 状态报告自测失败'
    Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '读取平台自测失败状态'

    Reset-TestHttp
    Add-TestUploadStart
    Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
    Add-TestHttpReply -Method PUT -Path '/items/categories/pe/test-mod/self-test-apply'
    $wrongSignData = New-TestModData
    $wrongSignData.status = 'self_test'
    $wrongSignData.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
    $wrongSignData.res[0].res_url = [pscustomobject]@{ sign = 'old-signature' }
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $wrongSignData } | ConvertTo-Json -Depth 15 -Compress)
    $rightSignData = New-TestModData
    $rightSignData.status = 'self_test'
    $rightSignData.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
    $rightSignData.res[0].res_url = [pscustomobject]@{ sign = 'test-signature' }
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $rightSignData } | ConvertTo-Json -Depth 15 -Compress)
    $result = Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'test-cookie=fixture' -StatePath (Join-Path $fixtureRoot 'signature-match.json') -WaitTimeoutSeconds 5 -PollIntervalSeconds 1
    Assert-Equal -Actual $result.Status -Expected 'self_test' -Message '签名一致才认定自测就绪'
    Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '拒绝旧签名导致的假成功'

    Reset-TestHttp
    $oldLocalNameData = New-TestModData
    $oldLocalNameData.status = 'self_test'
    $oldLocalNameData.res[0].res_name = [System.IO.Path]::GetFileName($package.Path)
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $oldLocalNameData } | ConvertTo-Json -Depth 15 -Compress)
    Assert-Throws -Action { Wait-LobbySelfTest -ModId 'test-mod' -Cookie 'test-cookie=fixture' -ExpectedPackageName 'lobby-map-123456789-abcdef.zip' -WaitTimeoutSeconds 0 } -Message '同一本地 ZIP 的旧 self_test 不能满足本次唯一远端包名'
    Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '只查询一次旧包状态，不重复上传'

    # 自动取消后的上传只接受仍处于 init 且原资源未变化的同一项目。
    $guardData = New-TestModData
    $guardData | Add-Member -NotePropertyName item_id -NotePropertyValue 'test-mod'
    $guardData.status = 'self_test'
    Reset-TestHttp
    Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body (@{ status = 'ok'; data = $guardData } | ConvertTo-Json -Depth 15 -Compress)
    Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'fixture' -StatePath (Join-Path $fixtureRoot 'cancel-raced.json') -RequireInit } -Message '取消后状态变化时不开始上传'
    Assert-Equal -Actual $script:HttpCalls.Count -Expected 1 -Message '取消状态变化没有 token 或上传写入'
    $guardData.status = 'init'
    $guardJson = @{ status = 'ok'; data = $guardData } | ConvertTo-Json -Depth 15 -Compress
    foreach ($race in @('resource', 'status', 'none')) {
        Reset-TestHttp
        Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body $guardJson
        Add-TestHttpReply -Method GET -Path '/filepicker/file_token?file_type=zip_package&secure=true' -Body '{"status":"ok","data":{"token":"test-upload-token"}}'
        Add-TestHttpReply -Method POST -Path '/x19s/file/new/' -Body '<textarea>{"url":"test-upload"}</textarea>' -Signature 'test-signature'
        $changed = $guardJson | ConvertFrom-Json
        if ($race -eq 'resource') { $changed.data.res[0].res_name = 'another-task.zip' }
        if ($race -eq 'status') { $changed.data.status = 'self_test' }
        Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body ($changed | ConvertTo-Json -Depth 15 -Compress)
        if ($race -eq 'none') {
            Add-TestHttpReply -Method POST -Path '/items/categories/pe/test-mod/update'
            Add-TestHttpReply -Method PUT -Path '/items/categories/pe/test-mod/self-test-apply'
            $changed.data.status = 'self_test'
            $changed.data.res[0].res_name = '__UPLOADED_PACKAGE_NAME__'
            Add-TestHttpReply -Method GET -Path '/items/categories/pe/test-mod' -Body ($changed | ConvertTo-Json -Depth 15 -Compress)
            $guardResult = Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'fixture' -StatePath (Join-Path $fixtureRoot 'cancel-upload-ready.json') -RequireInit -WaitTimeoutSeconds 0
            Assert-Equal -Actual $guardResult.Status -Expected 'self_test' -Message '取消后原资源保持不变可完成新版上传'
        }
        else {
            Assert-Throws -Action { Start-LobbySelfTest -PackagePath $package.Path -ModId 'test-mod' -Cookie 'fixture' -StatePath (Join-Path $fixtureRoot ('cancel-race-' + $race + '.json')) -RequireInit } -Message ('上传期间 ' + $race + ' 变化时阻断资源更新')
            Assert-Equal -Actual $script:HttpCalls.Count -Expected 4 -Message '平台变化后不更新资源或申请自测'
        }
        Assert-Equal -Actual $script:HttpQueue.Count -Expected 0 -Message '取消后上传保护按预期消费队列'
    }

    # 在独立子进程执行真实主入口；旁边的模块是纯离线替身，不读取账号或访问网络。
    $smokeApp = Join-Path $fixtureRoot 'isolated-app'
    $smokeOutput = Join-Path $fixtureRoot 'entry-packages'
    New-Item -ItemType Directory -Path $smokeApp -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $packagerRoot 'Upload-LobbySelfTest.ps1') -Destination (Join-Path $smokeApp 'Upload-LobbySelfTest.ps1')
    Copy-Item -LiteralPath $packScript -Destination (Join-Path $smokeApp 'Pack-LobbyMap.ps1')
    Copy-Item -LiteralPath (Join-Path $packagerRoot 'PackageIdentity.ps1') -Destination $smokeApp
    $smokeMarkers = Join-Path $smokeApp 'smoke-markers.jsonl'
    $smokeState = Join-Path $smokeApp 'lobby-test.last.json'
    $smokeResult = Join-Path $fixtureRoot 'entry-result.clixml'
    $smokeConfigModule = @'
$script:SmokeAppRoot = $PSScriptRoot
function Write-SmokeMarker {
    param([string]$Kind, $Data)
    $record = @{ kind = $Kind; data = $Data } | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath (Join-Path $script:SmokeAppRoot 'smoke-markers.jsonl') -Value $record -Encoding UTF8
}
function Get-LobbySelfTestConfig {
    param([string]$Path, [switch]$Configure, [switch]$NonInteractive)
    Write-SmokeMarker -Kind config -Data @{ path = $Path; configure = [bool]$Configure; nonInteractive = [bool]$NonInteractive }
    return [pscustomobject]@{ ModId = 'smoke-mod'; Cookie = 'offline-fixture' }
}
'@
    Write-TestUtf8 -Path (Join-Path $smokeApp 'LobbySelfTestConfig.ps1') -Text $smokeConfigModule -Bom
    $smokeNetworkModule = @'
function Get-LobbyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { $value = $Object[$Name] }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $value = $property.Value
    }
    if ($value -is [array]) { return ,$value }
    return $value
}
function Get-LobbyProject {
    param([string]$ModId, [string]$Cookie)
    Write-SmokeMarker -Kind project -Data @{ modId = $ModId }
    $remotePath = Join-Path $script:SmokeAppRoot 'smoke-remote.json'
    if (Test-Path -LiteralPath $remotePath) { return (Get-Content -LiteralPath $remotePath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return [pscustomobject]@{ item_id = 'smoke-mod'; status = 'processing'; res = @([pscustomobject]@{ res_name = 'previous.zip' }) }
}
function Get-LobbyResourceIndex {
    param($Data, [int]$ResourceIndex = -1)
    Write-SmokeMarker -Kind resourceIndex -Data @{ index = $ResourceIndex }
    return 0
}
function Write-LobbySelfTestState {
    param([string]$Path, $State)
    Write-SmokeMarker -Kind state -Data @{ path = $Path; phase = $State.phase }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $State -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
}
function Start-LobbySelfTest {
    param([string]$PackagePath, [string]$ModId, [string]$Cookie, [int]$ResourceIndex, [int]$WaitTimeoutSeconds, [int]$PollIntervalSeconds, [string]$StatePath, [string]$PackageSourceDigest, [string]$SourceDigestAlgorithm, [int]$RandomizedUuidCount)
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw 'Smoke entry did not pass a real ZIP.' }
    Write-SmokeMarker -Kind start -Data @{ packagePath = $PackagePath; modId = $ModId; statePath = $StatePath; index = $ResourceIndex; wait = $WaitTimeoutSeconds; poll = $PollIntervalSeconds; sourceDigest = $PackageSourceDigest; sourceDigestAlgorithm = $SourceDigestAlgorithm; randomizedUuidCount = $RandomizedUuidCount }
    Write-LobbySelfTestState -Path $StatePath -State @{ modId = $ModId; phase = 'ready'; packagePath = $PackagePath; packageName = 'smoke-remote.zip'; resourceIndex = 0 }
    return [pscustomobject]@{ Status = 'self_test'; ModId = $ModId; PackagePath = $PackagePath; StatePath = $StatePath }
}
'@
    $smokeNetworkModule += "`r`nfunction Resolve-LobbyPreviousUpload {`r`n" + (Get-Command Resolve-LobbyPreviousUpload).Definition + "`r`n}`r`n"
    $smokeNetworkModule += "`r`nfunction Assert-LobbyProjectIdentity {`r`n" + (Get-Command Assert-LobbyProjectIdentity).Definition + "`r`n}`r`n"
    Write-TestUtf8 -Path (Join-Path $smokeApp 'LobbySelfTest.ps1') -Text $smokeNetworkModule -Bom
    $smokeRunner = Join-Path $fixtureRoot 'run-entry-smoke.ps1'
    $smokeRunnerText = @'
param([string]$EntryPath, [string]$SourcePath, [string]$OutputDirectory, [string]$Mode, [string]$ResultPath, [string]$ReferencePackage)
$ErrorActionPreference = 'Stop'
$entryArgs = @{ SourcePath = $SourcePath; OutputDirectory = $OutputDirectory; NonInteractive = $true; PassThru = $true }
switch ($Mode) {
    'configure' { $entryArgs['ConfigureOnly'] = $true }
    'status' { $entryArgs['StatusOnly'] = $true }
    'new' { $entryArgs['StartNew'] = $true }
    'reference' { $entryArgs['PackagePath'] = $ReferencePackage }
}
$global:LASTEXITCODE = 0
$result = & $EntryPath @entryArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($null -ne $result) { $result | Export-Clixml -LiteralPath $ResultPath }
'@
    Write-TestUtf8 -Path $smokeRunner -Text $smokeRunnerText -Bom

    function Invoke-TestEntry {
        param([string]$Mode, [string]$ReferencePackage = '')
        if (Test-Path -LiteralPath $smokeMarkers) { Remove-Item -LiteralPath $smokeMarkers -Force }
        if (Test-Path -LiteralPath $smokeResult) { Remove-Item -LiteralPath $smokeResult -Force }
        $referenceArguments = @()
        if ($ReferencePackage) { $referenceArguments = @('-ReferencePackage', $ReferencePackage) }
        $childOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $smokeRunner -EntryPath (Join-Path $smokeApp 'Upload-LobbySelfTest.ps1') -SourcePath $sourceRoot -OutputDirectory $smokeOutput -Mode $Mode -ResultPath $smokeResult @referenceArguments)
        $childExit = $LASTEXITCODE
        $records = @()
        if (Test-Path -LiteralPath $smokeMarkers) { $records = @(Get-Content -LiteralPath $smokeMarkers -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }) }
        return [pscustomobject]@{ ExitCode = $childExit; Records = $records; Output = $childOutput }
    }

    $normalEntry = Invoke-TestEntry -Mode normal
    if ($normalEntry.ExitCode -ne 0) { Write-Host ($normalEntry.Output -join [Environment]::NewLine) }
    Assert-Equal -Actual $normalEntry.ExitCode -Expected 0 -Message '真实主入口可在子 PS5.1 执行成功'
    Assert-True -Condition (Test-Path -LiteralPath $smokeResult) -Message '主入口 PassThru 返回对象'
    $entryResult = Import-Clixml -LiteralPath $smokeResult
    Assert-Equal -Actual $entryResult.Status -Expected 'self_test' -Message '主入口保留上传返回状态'
    $configMarker = @($normalEntry.Records | Where-Object kind -eq config)[0]
    Assert-Equal -Actual (Split-Path -Leaf $configMarker.data.path) -Expected 'lobby-test.local.json' -Message '主入口默认配置文件名'
    Assert-Equal -Actual (Split-Path -Leaf (Split-Path -Parent $configMarker.data.path)) -Expected (Split-Path -Leaf $smokeApp) -Message '主入口默认配置定位到自身目录'
    Assert-True -Condition ([bool]$configMarker.data.nonInteractive) -Message '主入口传递非交互模式'
    $startMarkers = @($normalEntry.Records | Where-Object kind -eq start)
    Assert-Equal -Actual $startMarkers.Count -Expected 1 -Message '主入口只启动一次上传流程'
    Assert-Equal -Actual $startMarkers[0].data.packagePath -Expected $entryResult.PackagePath -Message '主入口把本次打包结果传给上传流程'
    Assert-True -Condition (Test-Path -LiteralPath $entryResult.PackagePath -PathType Leaf) -Message '主入口实际生成小地图 ZIP'
    Assert-True -Condition ((Split-Path -Leaf (Split-Path -Parent $entryResult.PackagePath)) -eq (Split-Path -Leaf $smokeOutput)) -Message '主入口包路径来自指定输出目录'
    Assert-Equal -Actual (Split-Path -Leaf $startMarkers[0].data.statePath) -Expected 'lobby-test.last.json' -Message '主入口传递自身目录下状态文件名'
    Assert-Equal -Actual (Split-Path -Leaf (Split-Path -Parent $startMarkers[0].data.statePath)) -Expected (Split-Path -Leaf $smokeApp) -Message '主入口传递自身目录下状态路径'
    Assert-Equal -Actual (($normalEntry.Records | ForEach-Object kind) -join ',') -Expected 'config,project,resourceIndex,start,state' -Message '主入口先预检再打包与上传'
    $entryPackageCount = @(Get-ChildItem -LiteralPath $smokeOutput -Filter '*.zip' -File).Count

    $configureEntry = Invoke-TestEntry -Mode configure
    Assert-Equal -Actual $configureEntry.ExitCode -Expected 0 -Message 'ConfigureOnly 成功返回'
    Assert-Equal -Actual $configureEntry.Records.Count -Expected 1 -Message 'ConfigureOnly 仅访问配置函数'
    Assert-True -Condition ([bool]$configureEntry.Records[0].data.configure) -Message 'ConfigureOnly 请求打开配置'
    Assert-Equal -Actual (@(Get-ChildItem -LiteralPath $smokeOutput -Filter '*.zip' -File).Count) -Expected $entryPackageCount -Message 'ConfigureOnly 不生成包'

    Write-TestUtf8 -Path (Join-Path $smokeApp 'smoke-remote.json') -Text '{"item_id":"smoke-mod","status":"self_test","res":[{"res_name":"smoke-remote.zip"}]}'
    $statusEntry = Invoke-TestEntry -Mode status
    Assert-Equal -Actual $statusEntry.ExitCode -Expected 0 -Message 'StatusOnly 成功返回'
    Assert-Equal -Actual (@($statusEntry.Records | Where-Object kind -eq start).Count) -Expected 0 -Message 'StatusOnly 不调用上传流程'
    Assert-Equal -Actual (@(Get-ChildItem -LiteralPath $smokeOutput -Filter '*.zip' -File).Count) -Expected $entryPackageCount -Message 'StatusOnly 不生成包'
    $statusResult = Import-Clixml -LiteralPath $smokeResult
    Assert-True -Condition ([bool]$statusResult.MatchesLastPackage) -Message 'StatusOnly 核对上次远端包名'
    Assert-Equal -Actual ((Get-Content -LiteralPath $smokeState -Raw -Encoding UTF8 | ConvertFrom-Json).phase) -Expected 'ready' -Message 'StatusOnly 将已确认回执标记为就绪'

    Write-TestUtf8 -Path $smokeState -Text '{"modId":"smoke-mod","phase":"needs_check","failedAtPhase":"submitting","resourceIndex":0,"packageName":"smoke-remote.zip"}'
    Write-TestUtf8 -Path (Join-Path $smokeApp 'smoke-remote.json') -Text '{"item_id":"smoke-mod","status":"self_test","res":[{"res_name":"other-remote.zip"}]}'
    $blockedEntry = Invoke-TestEntry -Mode normal
    Assert-Equal -Actual $blockedEntry.ExitCode -Expected 1 -Message '主入口阻止重放结果不明的自测申请'
    Assert-Equal -Actual (@($blockedEntry.Records | Where-Object kind -eq start).Count) -Expected 0 -Message '结果不明时没有上传写操作'
    Assert-Equal -Actual (@(Get-ChildItem -LiteralPath $smokeOutput -Filter '*.zip' -File).Count) -Expected $entryPackageCount -Message '结果不明时没有重新打包'
    Assert-True -Condition (($blockedEntry.Output -join '') -match '唯一资源名不匹配') -Message '自动查询明确报告原任务资源不匹配'
    Write-TestUtf8 -Path (Join-Path $smokeApp 'smoke-remote.json') -Text '{"item_id":"smoke-mod","status":"self_test","res":[{"res_name":"smoke-remote.zip"}]}'
    $recoveredEntry = Invoke-TestEntry -Mode normal
    Assert-Equal -Actual $recoveredEntry.ExitCode -Expected 0 -Message '自动查询确认旧任务后直接继续上传'
    Assert-Equal -Actual (@($recoveredEntry.Records | Where-Object kind -eq start).Count) -Expected 1 -Message '自动恢复只启动一次上传'
    Assert-True -Condition (($recoveredEntry.Output -join '') -match '自动查询确认上次版本已就绪') -Message '恢复流程输出自动查询结论'
    Write-TestUtf8 -Path $smokeState -Text '{"modId":"smoke-mod","phase":"needs_check","failedAtPhase":"submitting","resourceIndex":0,"packageName":"smoke-remote.zip"}'
    $newEntry = Invoke-TestEntry -Mode new
    if ($newEntry.ExitCode -ne 0) { Write-Host ($newEntry.Output -join [Environment]::NewLine) }
    Assert-Equal -Actual $newEntry.ExitCode -Expected 0 -Message '显式 StartNew 可开始新任务'
    Assert-Equal -Actual (@($newEntry.Records | Where-Object kind -eq start).Count) -Expected 1 -Message 'StartNew 只启动一次上传'
    Assert-Equal -Actual (@(Get-ChildItem -LiteralPath $smokeOutput -Filter '*.zip' -File).Count) -Expected ($entryPackageCount + 2) -Message '自动恢复与显式 StartNew 各生成独立新包'

    $referenceResult = Import-Clixml -LiteralPath $smokeResult
    $referenceHash = (Get-FileHash -LiteralPath $referenceResult.PackagePath).Hash
    $referenceEntry = Invoke-TestEntry -Mode reference -ReferencePackage $referenceResult.PackagePath
    Assert-Equal $referenceEntry.ExitCode 0 '传入现成包时仍可完成离线上传'
    $rebuiltResult = Import-Clixml -LiteralPath $smokeResult
    Assert-True ($rebuiltResult.PackagePath -cne $referenceResult.PackagePath) '传入包只作校验参考，上传本次全量新包'
    Assert-Equal (Get-FileHash -LiteralPath $referenceResult.PackagePath).Hash $referenceHash '参考包保持原样'
    Assert-True ((Get-FileHash -LiteralPath $rebuiltResult.PackagePath).Hash -cne $referenceHash) '再次上传生成新 UUID 内容'
    $rebuiltStart = @($referenceEntry.Records | Where-Object kind -eq start)[0].data
    Assert-Equal $rebuiltStart.sourceDigest $rebuiltResult.SourceDigest '上传入口透传实际包源码摘要'
    Assert-Equal $rebuiltStart.sourceDigestAlgorithm 'sha256-path-nul-sha256-lf-v1' '上传入口透传摘要算法'
    Assert-Equal $rebuiltStart.randomizedUuidCount 4 '上传入口透传实际随机 UUID 数量'
    Assert-Throws { Assert-MapPackageSource -SourcePath $sourceRoot -PackagePath $package.Path } '旧包内容与当前源不一致时拒绝作为参考'
    Write-Host ("PASS: {0} checks (Windows PowerShell {1}), no real network calls." -f $script:CheckCount, $PSVersionTable.PSVersion) -ForegroundColor Green
}
finally {
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    $resolvedParent = [System.IO.Path]::GetFullPath($tempParent).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedFixture) -notmatch '^lobbymap_selftest_[a-f0-9]{32}$') {
        throw '测试目录校验失败，不执行递归清理。'
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
