# Local configuration for the map packager and the online-lobby self-test.
# Secrets are protected with Windows DPAPI for the current Windows user only.
. (Join-Path $PSScriptRoot 'PackageIdentity.ps1')

function Get-LobbyConfigProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return , $property.Value }
    return $null
}

function ConvertTo-LobbyPatternList {
    param([object[]]$Patterns)
    $result = @()
    foreach ($pattern in @($Patterns)) {
        $text = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $result += $text
    }
    return [string[]]$result
}

function ConvertTo-LobbySelfTestSettings {
    param(
        [AllowEmptyString()][string]$ModId,
        [AllowEmptyString()][string]$Cookie,
        [AllowEmptyString()][string]$SourcePath = '',
        [AllowEmptyString()][string]$OutputDirectory = '',
        [AllowEmptyString()][string]$ArchiveRoot = 'map',
        [string[]]$IncludeDirectories = $null,
        [string[]]$IncludeFiles = $null,
        [string[]]$ExcludePatterns = $null
    )

    $cleanModId = ([string]$ModId).Trim()
    if ([string]::IsNullOrWhiteSpace($cleanModId) -or $cleanModId -match '[\x00-\x1f\x7f]') {
        throw '请输入有效的模组或联机大厅组件 ID，不能包含控制字符。'
    }
    if ($Cookie -match '[\r\n]') {
        throw 'Cookie 不能包含换行，请只复制请求头 Cookie 的值。'
    }
    $cleanCookie = ($Cookie -replace '(?i)^\s*cookie\s*:\s*', '').Trim()
    if ([string]::IsNullOrWhiteSpace($cleanCookie) -or $cleanCookie -match '[\x00-\x1f\x7f]') {
        throw '请输入有效的 Cookie，不能包含控制字符。'
    }
    if ($cleanCookie.Length -gt 65536) {
        throw 'Cookie 超过 65536 字符，请只复制请求头 Cookie 的值。'
    }

    $patternArgument = if ($null -eq $ExcludePatterns) { $null } else { ConvertTo-LobbyPatternList $ExcludePatterns }
    $packer = New-MapPackagerSettings `
        -SourcePath $SourcePath `
        -OutputDirectory $OutputDirectory `
        -ArchiveRoot $ArchiveRoot `
        -IncludeDirectories $IncludeDirectories `
        -IncludeFiles $IncludeFiles `
        -ExcludePatterns $patternArgument

    return [pscustomobject]@{
        ModId              = $cleanModId
        Cookie             = $cleanCookie
        SourcePath         = $packer.SourcePath
        OutputDirectory    = $packer.OutputDirectory
        ArchiveRoot        = $packer.ArchiveRoot
        IncludeDirectories = $packer.IncludeDirectories
        IncludeFiles       = $packer.IncludeFiles
        ExcludePatterns    = $packer.ExcludePatterns
    }
}

function Protect-LobbyCookie {
    param([Parameter(Mandatory = $true)][string]$Cookie)

    $secureCookie = $null
    $stage = 'SecureString'
    try {
        $secureCookie = ConvertTo-SecureString -String $Cookie -AsPlainText -Force -ErrorAction Stop
        $stage = 'WindowsDPAPI'
        return ConvertFrom-SecureString -SecureString $secureCookie -ErrorAction Stop
    }
    catch {
        # Do not display the underlying message or invocation: either can
        # contain a command argument and therefore the supplied credential.
        $failure = $_.Exception
        for ($depth = 0; $depth -lt 5 -and $null -ne $failure.InnerException; $depth++) {
            $failure = $failure.InnerException
        }
        $safeCode = '0x{0:X8}' -f $failure.HResult
        throw ('Cookie 加密失败（阶段：{0}；类型：{1}；代码：{2}）。原配置未更改。' -f $stage, $failure.GetType().FullName, $safeCode)
    }
    finally {
        if ($null -ne $secureCookie) { $secureCookie.Dispose() }
    }
}

function Test-LobbyCookieProtection {
    # Run in the same process and Windows logon session as the form, before
    # asking for any real credential. This value never leaves local memory.
    $probe = 'lobby-map-selftest-probe-' + [guid]::NewGuid().ToString('N')
    $secureProbe = $null
    $pointer = [IntPtr]::Zero
    try {
        $cipher = Protect-LobbyCookie -Cookie $probe
        $secureProbe = ConvertTo-SecureString -String $cipher -ErrorAction Stop
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureProbe)
        if ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -cne $probe) {
            throw '当前 Windows 用户的加密自检未通过，未读取或保存 Cookie。'
        }
        return $true
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($null -ne $secureProbe) { $secureProbe.Dispose() }
        $cipher = $null
        $probe = $null
    }
}

function Read-PackagerSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $savedConfig = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw '配置文件无法读取或 JSON 无效，请重新配置。'
    }
    if ($null -eq $savedConfig -or
        -not ($savedConfig.PSObject.Properties.Name -contains 'schemaVersion') -or
        ($savedConfig.schemaVersion -ne 1 -and $savedConfig.schemaVersion -ne 2)) {
        throw '配置文件格式无效，请重新配置。'
    }

    $savedModId = ([string](Get-LobbyConfigProperty $savedConfig 'modId')).Trim()
    if ($savedModId -and $savedModId -match '[\x00-\x1f\x7f]') {
        throw '配置中的联机大厅组件 ID 无效，请重新配置。'
    }

    $savedDirectories = Get-LobbyConfigProperty $savedConfig 'includeDirectories'
    $savedFiles = Get-LobbyConfigProperty $savedConfig 'includeFiles'
    $savedExcludes = Get-LobbyConfigProperty $savedConfig 'excludePatterns'
    if ($null -ne $savedDirectories) { $savedDirectories = ConvertTo-LobbyPatternList $savedDirectories }
    if ($null -ne $savedFiles) { $savedFiles = ConvertTo-LobbyPatternList $savedFiles }
    if ($null -ne $savedExcludes) { $savedExcludes = ConvertTo-LobbyPatternList $savedExcludes }

    $packer = New-MapPackagerSettings `
        -SourcePath ([string](Get-LobbyConfigProperty $savedConfig 'sourcePath')) `
        -OutputDirectory ([string](Get-LobbyConfigProperty $savedConfig 'outputDirectory')) `
        -ArchiveRoot ([string](Get-LobbyConfigProperty $savedConfig 'archiveRoot')) `
        -IncludeDirectories $savedDirectories `
        -IncludeFiles $savedFiles `
        -ExcludePatterns $savedExcludes

    return [pscustomobject]@{
        SchemaVersion      = [int]$savedConfig.schemaVersion
        ModId              = $savedModId
        CookieProtected    = [string](Get-LobbyConfigProperty $savedConfig 'cookieProtected')
        SourcePath         = $packer.SourcePath
        OutputDirectory    = $packer.OutputDirectory
        ArchiveRoot        = $packer.ArchiveRoot
        IncludeDirectories = $packer.IncludeDirectories
        IncludeFiles       = $packer.IncludeFiles
        ExcludePatterns    = $packer.ExcludePatterns
    }
}

function Read-LobbySelfTestConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $savedConfig = Read-PackagerSettings -Path $Path
    if ([string]::IsNullOrWhiteSpace($savedConfig.ModId)) {
        throw '请输入有效的模组或联机大厅组件 ID，不能包含控制字符。'
    }
    if ([string]::IsNullOrWhiteSpace($savedConfig.CookieProtected)) {
        throw '尚未配置 Cookie，请运行“配置上传自测.cmd”填写后再上传。'
    }

    $secureCookie = $null
    $cookiePointer = [IntPtr]::Zero
    try {
        $secureCookie = ConvertTo-SecureString -String ([string]$savedConfig.CookieProtected) -ErrorAction Stop
        $cookiePointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCookie)
        $plainCookie = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($cookiePointer)
    }
    catch {
        throw 'Cookie 无法在当前 Windows 用户下解密，请重新配置。'
    }
    finally {
        if ($cookiePointer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($cookiePointer)
        }
        if ($null -ne $secureCookie) { $secureCookie.Dispose() }
    }
    return ConvertTo-LobbySelfTestSettings `
        -ModId $savedConfig.ModId `
        -Cookie $plainCookie `
        -SourcePath $savedConfig.SourcePath `
        -OutputDirectory $savedConfig.OutputDirectory `
        -ArchiveRoot $savedConfig.ArchiveRoot `
        -IncludeDirectories $savedConfig.IncludeDirectories `
        -IncludeFiles $savedConfig.IncludeFiles `
        -ExcludePatterns $savedConfig.ExcludePatterns
}

function Save-LobbySelfTestConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Settings
    )

    $settingDirectories = Get-LobbyConfigProperty $Settings 'IncludeDirectories'
    $settingFiles = Get-LobbyConfigProperty $Settings 'IncludeFiles'
    $settingExcludes = Get-LobbyConfigProperty $Settings 'ExcludePatterns'
    if ($null -ne $settingDirectories) { $settingDirectories = ConvertTo-LobbyPatternList $settingDirectories }
    if ($null -ne $settingFiles) { $settingFiles = ConvertTo-LobbyPatternList $settingFiles }
    if ($null -ne $settingExcludes) { $settingExcludes = ConvertTo-LobbyPatternList $settingExcludes }

    $checkedSettings = ConvertTo-LobbySelfTestSettings `
        -ModId ([string](Get-LobbyConfigProperty $Settings 'ModId')) `
        -Cookie ([string](Get-LobbyConfigProperty $Settings 'Cookie')) `
        -SourcePath ([string](Get-LobbyConfigProperty $Settings 'SourcePath')) `
        -OutputDirectory ([string](Get-LobbyConfigProperty $Settings 'OutputDirectory')) `
        -ArchiveRoot ([string](Get-LobbyConfigProperty $Settings 'ArchiveRoot')) `
        -IncludeDirectories $settingDirectories `
        -IncludeFiles $settingFiles `
        -ExcludePatterns $settingExcludes
    $protectedCookie = Protect-LobbyCookie -Cookie $checkedSettings.Cookie

    $configPath = [System.IO.Path]::GetFullPath($Path)
    $configDirectory = [System.IO.Path]::GetDirectoryName($configPath)
    if (-not [System.IO.Directory]::Exists($configDirectory)) {
        throw '配置文件所在目录不存在，无法保存。'
    }
    $savedConfig = [ordered]@{
        schemaVersion      = 2
        modId              = $checkedSettings.ModId
        cookieProtected    = $protectedCookie
        sourcePath         = $checkedSettings.SourcePath
        outputDirectory    = $checkedSettings.OutputDirectory
        archiveRoot        = $checkedSettings.ArchiveRoot
        includeDirectories = @($checkedSettings.IncludeDirectories)
        includeFiles       = @($checkedSettings.IncludeFiles)
        excludePatterns    = @($checkedSettings.ExcludePatterns)
    }
    $temporaryPath = Join-Path $configDirectory ('.lobby-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $configJson = $savedConfig | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($temporaryPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($configPath)) {
            [System.IO.File]::Replace($temporaryPath, $configPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $configPath)
        }
    }
    catch {
        throw '配置保存失败，原配置未更改。请检查文件权限或占用。'
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Show-LobbySelfTestDialog {
    param(
        [string]$InitialModId = '',
        [string]$InitialCookie = '',
        [string]$InitialSourcePath = '',
        [string]$InitialOutputDirectory = '',
        [string]$InitialArchiveRoot = 'map',
        [string]$InitialExcludePatterns = '',
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $null = Test-LobbyCookieProtection
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '地图打包与联机大厅自测配置'
    $form.ClientSize = New-Object System.Drawing.Size(640, 650)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    function New-ConfigLabel {
        param([string]$Text, [int]$Top, [int]$Width = 580)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point(20, $Top)
        $label.Size = New-Object System.Drawing.Size($Width, 22)
        return $label
    }

    $idLabel = New-ConfigLabel -Text '联机大厅组件 ID（开发者平台项目 item_id）' -Top 14
    $idBox = New-Object System.Windows.Forms.TextBox
    $idBox.Location = New-Object System.Drawing.Point(20, 40)
    $idBox.Size = New-Object System.Drawing.Size(590, 27)
    $idBox.Text = $InitialModId
    $idBox.TabIndex = 0

    $cookieLabel = New-ConfigLabel -Text '开发者平台 Cookie' -Top 76
    $cookieBox = New-Object System.Windows.Forms.TextBox
    $cookieBox.Location = New-Object System.Drawing.Point(20, 102)
    $cookieBox.Size = New-Object System.Drawing.Size(590, 27)
    $cookieBox.UseSystemPasswordChar = $true
    # Let validation report an oversized paste instead of silently truncating
    # a normal request header at the TextBox default of 32767 characters.
    $cookieBox.MaxLength = 1048576
    $cookieBox.Text = $InitialCookie
    $cookieBox.TabIndex = 1

    $sourceLabel = New-ConfigLabel -Text '地图源目录（包含 level.dat 与 behavior_packs 等）' -Top 138
    $sourceBox = New-Object System.Windows.Forms.TextBox
    $sourceBox.Location = New-Object System.Drawing.Point(20, 164)
    $sourceBox.Size = New-Object System.Drawing.Size(590, 27)
    $sourceBox.Text = $InitialSourcePath
    $sourceBox.TabIndex = 2

    $outputLabel = New-ConfigLabel -Text 'ZIP 输出目录（留空则使用工具目录下的 packages）' -Top 200
    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Location = New-Object System.Drawing.Point(20, 226)
    $outputBox.Size = New-Object System.Drawing.Size(590, 27)
    $outputBox.Text = $InitialOutputDirectory
    $outputBox.TabIndex = 3

    $rootLabel = New-ConfigLabel -Text 'ZIP 归档根目录名' -Top 262 -Width 220
    $rootBox = New-Object System.Windows.Forms.TextBox
    $rootBox.Location = New-Object System.Drawing.Point(20, 288)
    $rootBox.Size = New-Object System.Drawing.Size(220, 27)
    $rootBox.Text = if ([string]::IsNullOrWhiteSpace($InitialArchiveRoot)) { 'map' } else { $InitialArchiveRoot }
    $rootBox.TabIndex = 4

    $excludeLabel = New-ConfigLabel -Text '剔除规则（每行一条，支持 *、**、? 与 ! 反选）' -Top 324
    $excludeBox = New-Object System.Windows.Forms.TextBox
    $excludeBox.Location = New-Object System.Drawing.Point(20, 350)
    $excludeBox.Size = New-Object System.Drawing.Size(590, 130)
    $excludeBox.Multiline = $true
    $excludeBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $excludeBox.AcceptsReturn = $true
    $excludeBox.Text = $InitialExcludePatterns
    $excludeBox.TabIndex = 5

    $helpLabel = New-Object System.Windows.Forms.Label
    $helpLabel.Text = "示例：**/*.pyc、**/__pycache__/**、**/.gitignore、**/.git/**`r`n按 F12 在开发者平台 me 请求头中复制 Cookie；Cookie 仅以当前 Windows 用户加密保存。`r`n保存失败时窗口保留输入，成功后才会关闭。"
    $helpLabel.Location = New-Object System.Drawing.Point(20, 488)
    $helpLabel.Size = New-Object System.Drawing.Size(590, 78)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存配置'
    $saveButton.Location = New-Object System.Drawing.Point(400, 590)
    $saveButton.Size = New-Object System.Drawing.Size(100, 32)
    $saveButton.TabIndex = 6
    $saveButton.Add_Click({
        try {
            $candidate = ConvertTo-LobbySelfTestSettings `
                -ModId $idBox.Text `
                -Cookie $cookieBox.Text `
                -SourcePath $sourceBox.Text `
                -OutputDirectory $outputBox.Text `
                -ArchiveRoot $rootBox.Text `
                -ExcludePatterns @($excludeBox.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            Save-LobbySelfTestConfig -Path $ConfigPath -Settings $candidate
            $form.Tag = $candidate
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
        catch {
            $null = [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '配置未保存', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(510, 590)
    $cancelButton.Size = New-Object System.Drawing.Size(100, 32)
    $cancelButton.TabIndex = 7
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton
    $form.Controls.AddRange(@($idLabel, $idBox, $cookieLabel, $cookieBox, $sourceLabel, $sourceBox, $outputLabel, $outputBox, $rootLabel, $rootBox, $excludeLabel, $excludeBox, $helpLabel, $saveButton, $cancelButton))
    try {
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw (New-Object System.OperationCanceledException('已取消配置，未保存。'))
        }
        return $form.Tag
    }
    finally {
        $cookieBox.Clear()
        $form.Dispose()
    }
}

function Get-LobbySelfTestConfig {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [switch]$Configure,
        [switch]$NonInteractive
    )

    $configPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $Configure -and [System.IO.File]::Exists($configPath)) {
        return Read-LobbySelfTestConfig -Path $configPath
    }
    if ($NonInteractive) {
        throw '缺少配置，或要求重新配置。请先在交互模式下运行配置入口。'
    }

    $initial = $null
    $initialCookie = ''
    if ([System.IO.File]::Exists($configPath)) {
        try { $initial = Read-PackagerSettings -Path $configPath } catch { }
        try { $initialCookie = (Read-LobbySelfTestConfig -Path $configPath).Cookie } catch { }
    }
    if ($null -eq $initial) {
        $fallbackPath = Join-Path $PSScriptRoot 'lobby-test.local.json'
        if ([System.IO.File]::Exists($fallbackPath)) {
            try { $initial = Read-PackagerSettings -Path $fallbackPath } catch { }
        }
    }
    if ($null -eq $initial) {
        $initial = New-MapPackagerSettings
        $initial | Add-Member -NotePropertyName ModId -NotePropertyValue ''
        $initial | Add-Member -NotePropertyName CookieProtected -NotePropertyValue ''
    }
    $settings = Show-LobbySelfTestDialog `
        -InitialModId ([string]$initial.ModId) `
        -InitialCookie $initialCookie `
        -InitialSourcePath ([string]$initial.SourcePath) `
        -InitialOutputDirectory ([string]$initial.OutputDirectory) `
        -InitialArchiveRoot ([string]$initial.ArchiveRoot) `
        -InitialExcludePatterns ((@($initial.ExcludePatterns)) -join "`r`n") `
        -ConfigPath $configPath
    return $settings
}
