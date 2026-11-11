[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:CheckCount = 0

function Assert-ConfigTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Config regression failed: ' + $Message) }
    $script:CheckCount++
}

function Unprotect-TestCipher {
    param([string]$Cipher)
    $secure = $null
    $pointer = [IntPtr]::Zero
    try {
        $secure = Microsoft.PowerShell.Security\ConvertTo-SecureString -String $Cipher -ErrorAction Stop
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function New-StandardTestCipher {
    param([string]$Plain)
    $secure = $null
    try {
        $secure = Microsoft.PowerShell.Security\ConvertTo-SecureString -String $Plain -AsPlainText -Force -ErrorAction Stop
        return Microsoft.PowerShell.Security\ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop
    }
    finally {
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Get-TestFunctionAst {
    param($Ast, [string]$Name)
    $matches = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    Assert-ConfigTest ($matches.Count -eq 1) ('Expected one function: ' + $Name)
    return $matches[0]
}

$packagerRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $packagerRoot 'LobbySelfTestConfig.ps1'
$tempParent = [System.IO.Path]::GetFullPath($env:TEMP)
$fixtureName = 'lobby_config_test_' + [guid]::NewGuid().ToString('N')
$fixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $tempParent $fixtureName))
Assert-ConfigTest ([System.IO.Directory]::Exists($tempParent)) 'Task temporary directory exists'
Assert-ConfigTest ([System.IO.Path]::GetDirectoryName($fixtureRoot).Equals($tempParent, [StringComparison]::OrdinalIgnoreCase)) 'Fixture is directly inside the intended temporary directory'
$null = [System.IO.Directory]::CreateDirectory($fixtureRoot)
$mockInstalled = $false

try {
    # Only dot-source the implementation. Never call the interactive entry point,
    # use its real config path, inspect a browser, or send network requests.
    . $modulePath
    Assert-ConfigTest ((Test-LobbyCookieProtection) -eq $true) 'In-process fake-value protection self-test succeeds'

    $fakePlain = 'offline_probe=fake-value-' + [guid]::NewGuid().ToString('N')
    $unicodePlain = 'offline_probe=' + [char]0x6D4B + [char]0x8BD5 + [char]0x00E9 + '-fixture'
    foreach ($plain in @($fakePlain, $unicodePlain)) {
        $cipher = Protect-LobbyCookie -Cookie $plain
        Assert-ConfigTest ($cipher -is [string] -and -not [string]::IsNullOrWhiteSpace($cipher)) 'Protection returns one nonempty standard cipher string'
        Assert-ConfigTest (-not $cipher.Contains($plain)) 'Protected output does not contain its fake plaintext'
        Assert-ConfigTest ((Unprotect-TestCipher $cipher) -ceq $plain) 'Standard PowerShell DPAPI decoder round-trips the protected value'
    }

    $longPlain = 'probe=' + ('x' * (65536 - 6))
    $longSettings = ConvertTo-LobbySelfTestSettings -ModId 'offline-fixture' -Cookie $longPlain
    Assert-ConfigTest ($longSettings.Cookie.Length -eq 65536) 'The SecureString maximum length is accepted intact'
    $longCipher = Protect-LobbyCookie -Cookie $longSettings.Cookie
    Assert-ConfigTest ((Unprotect-TestCipher $longCipher) -ceq $longPlain) 'The maximum supported fake Cookie round-trips'
    $tooLongRejected = $false
    try { $null = ConvertTo-LobbySelfTestSettings -ModId 'offline-fixture' -Cookie ($longPlain + 'x') }
    catch { $tooLongRejected = $true }
    Assert-ConfigTest $tooLongRejected 'Over-limit input is rejected before cryptographic conversion'

    # Independently create a schemaVersion=1 file using the original standard
    # cmdlets, so the reader must remain compatible with existing saved ciphers.
    $legacyPath = Join-Path $fixtureRoot 'legacy-fake-config.json'
    $legacyCipher = New-StandardTestCipher $unicodePlain
    $legacyJson = [ordered]@{schemaVersion=1;modId='legacy-fixture';cookieProtected=$legacyCipher} | ConvertTo-Json
    [System.IO.File]::WriteAllText($legacyPath, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))
    $legacyRead = Read-LobbySelfTestConfig -Path $legacyPath
    Assert-ConfigTest ($legacyRead.ModId -ceq 'legacy-fixture') 'Existing schemaVersion=1 project identity remains readable'
    Assert-ConfigTest ($legacyRead.Cookie -ceq $unicodePlain) 'Existing standard CurrentUser DPAPI ciphers remain readable'

    $configPath = Join-Path $fixtureRoot 'fake-config.json'
    $initialSettings = [pscustomobject]@{ModId='first-fixture';Cookie=$fakePlain}
    Save-LobbySelfTestConfig -Path $configPath -Settings $initialSettings
    Assert-ConfigTest ([System.IO.File]::Exists($configPath)) 'First save creates the isolated config'
    $firstJson = [System.IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
    $firstData = $firstJson | ConvertFrom-Json
    Assert-ConfigTest ($firstData.schemaVersion -eq 2) 'Save writes the current config schema'
    Assert-ConfigTest (@($firstData.includeDirectories).Count -eq 3) 'Save persists default include directories'
    Assert-ConfigTest (@($firstData.includeFiles).Count -eq 6) 'Save persists default include files'
    Assert-ConfigTest (@($firstData.excludePatterns).Count -eq 3) 'Save persists default exclusion rules'
    Assert-ConfigTest (-not $firstJson.Contains($fakePlain)) 'Created config contains no fake plaintext'
    Assert-ConfigTest ((Unprotect-TestCipher $firstData.cookieProtected) -ceq $fakePlain) 'Created config holds a valid standard protected value'

    $replacementSettings = [pscustomobject]@{ModId='replacement-fixture';Cookie=$unicodePlain}
    Save-LobbySelfTestConfig -Path $configPath -Settings $replacementSettings
    $replacementJson = [System.IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
    $replacementRead = Read-LobbySelfTestConfig -Path $configPath
    Assert-ConfigTest ($replacementRead.ModId -ceq 'replacement-fixture') 'Second save replaces the project identity'
    Assert-ConfigTest ($replacementRead.Cookie -ceq $unicodePlain) 'Second save atomically replaces the protected value'
    Assert-ConfigTest (-not $replacementJson.Contains($unicodePlain) -and -not $replacementJson.Contains($fakePlain)) 'Replacement config contains no old or new fake plaintext'
    Assert-ConfigTest (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '.lobby-config-*.tmp' -File).Count -eq 0) 'Successful saves leave no intermediate config file'

    # This deliberately hostile exception resembles an unsafe underlying error.
    # Only fake data is involved; the production diagnostic must discard its text.
    $script:ConfigFailureFakeSecret = 'FAKE_SECRET_' + [guid]::NewGuid().ToString('N')
    $script:ConfigFailureRawPrefix = 'raw-underlying-error-must-never-be-exposed:'
    function ConvertFrom-SecureString {
        [CmdletBinding()]
        param([System.Security.SecureString]$SecureString)
        throw (New-Object System.Security.Cryptography.CryptographicException ($script:ConfigFailureRawPrefix + $script:ConfigFailureFakeSecret))
    }
    $mockInstalled = $true
    $beforeFailureHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $caughtError = $null
    try {
        Save-LobbySelfTestConfig -Path $configPath -Settings ([pscustomobject]@{ModId='failed-fixture';Cookie=$script:ConfigFailureFakeSecret})
    }
    catch { $caughtError = $_ }
    Assert-ConfigTest ($null -ne $caughtError) 'A DPAPI serialization failure is reported'
    $diagnostic = $caughtError.Exception.ToString()
    Assert-ConfigTest (-not $diagnostic.Contains($script:ConfigFailureFakeSecret)) 'Protection errors never expose the fake secret'
    Assert-ConfigTest (-not $diagnostic.Contains($script:ConfigFailureRawPrefix)) 'Protection errors discard unsafe underlying exception messages'
    Assert-ConfigTest ($diagnostic -match 'WindowsDPAPI') 'Protection failure identifies the DPAPI stage'
    Assert-ConfigTest ($diagnostic -match 'CryptographicException') 'Protection failure identifies the sanitized exception type'
    Assert-ConfigTest ($diagnostic -match '0x[0-9a-fA-F]{8}') 'Protection failure identifies a hexadecimal HRESULT'
    Assert-ConfigTest ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $beforeFailureHash) 'Failed protection leaves the existing config byte-for-byte intact'

    $failedNewPath = Join-Path $fixtureRoot 'must-not-exist.json'
    $newRejected = $false
    try { Save-LobbySelfTestConfig -Path $failedNewPath -Settings $initialSettings }
    catch { $newRejected = $true }
    Assert-ConfigTest $newRejected 'Protection failure also rejects a first save'
    Assert-ConfigTest (-not [System.IO.File]::Exists($failedNewPath)) 'Failed first save leaves no partial config'
    Assert-ConfigTest (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '.lobby-config-*.tmp' -File).Count -eq 0) 'Failed protection leaves no intermediate config file'

    $selfTestError = $null
    try { $null = Test-LobbyCookieProtection }
    catch { $selfTestError = $_ }
    Assert-ConfigTest ($null -ne $selfTestError) 'Self-test rejects an unavailable DPAPI provider'
    Assert-ConfigTest (-not $selfTestError.Exception.ToString().Contains($script:ConfigFailureFakeSecret)) 'Self-test errors also sanitize hostile provider messages'
    Remove-Item -LiteralPath 'Function:\ConvertFrom-SecureString'
    $mockInstalled = $false
    Assert-ConfigTest ((Test-LobbyCookieProtection) -eq $true) 'Self-test succeeds after the fake provider failure is removed'

    # Validate the modal save lifecycle without creating or driving a GUI.
    $tokens = $null
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    Assert-ConfigTest (@($parseErrors).Count -eq 0) 'Config implementation parses under Windows PowerShell 5.1'
    $dialogAst = Get-TestFunctionAst $moduleAst 'Show-LobbySelfTestDialog'
    $pathParameters = @($dialogAst.Body.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'ConfigPath'})
    Assert-ConfigTest ($pathParameters.Count -eq 1) 'Dialog receives its explicit destination config path'
    Assert-ConfigTest ($pathParameters[0].Extent.Text -match 'Mandatory\s*=\s*\$true') 'Dialog config path is mandatory'
    $saveCallbacks = @($dialogAst.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq '$saveButton' -and $node.Member.Extent.Text -eq 'Add_Click'
    }, $true))
    Assert-ConfigTest ($saveCallbacks.Count -eq 1) 'Dialog has one save callback'
    $callbackAst = $saveCallbacks[0].Arguments[0]
    $saveCalls = @($callbackAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Save-LobbySelfTestConfig'
    }, $true))
    $okAssignments = @($callbackAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$form.DialogResult' -and $node.Right.Extent.Text -match '::OK\b'
    }, $true))
    Assert-ConfigTest ($saveCalls.Count -eq 1) 'The save callback performs the actual protected write'
    Assert-ConfigTest ($okAssignments.Count -eq 1 -and $saveCalls[0].Extent.StartOffset -lt $okAssignments[0].Extent.StartOffset) 'Dialog only reports success after the protected save call'

    $getAst = Get-TestFunctionAst $moduleAst 'Get-LobbySelfTestConfig'
    $duplicateSaves = @($getAst.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Save-LobbySelfTestConfig'
    }, $true))
    Assert-ConfigTest ($duplicateSaves.Count -eq 0) 'Get-LobbySelfTestConfig does not save again after the modal callback'
    $dialogCalls = @($getAst.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Show-LobbySelfTestDialog'
    }, $true))
    Assert-ConfigTest ($dialogCalls.Count -eq 1) 'Get-LobbySelfTestConfig invokes the dialog once'
    Assert-ConfigTest (@($dialogCalls[0].CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ConfigPath'}).Count -eq 1) 'The caller passes its selected config destination to the dialog'

    Write-Host ('Lobby config offline regression passed: {0} checks.' -f $script:CheckCount)
}
finally {
    if ($mockInstalled) { Remove-Item -LiteralPath 'Function:\ConvertFrom-SecureString' -ErrorAction SilentlyContinue }
    $script:ConfigFailureFakeSecret = $null
    $script:ConfigFailureRawPrefix = $null
    $safeFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    if (-not [System.IO.Path]::GetDirectoryName($safeFixture).Equals($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($safeFixture) -cne $fixtureName) {
        throw 'Refusing cleanup outside the exact test-owned fixture directory.'
    }
    if ([System.IO.Directory]::Exists($safeFixture)) { Remove-Item -LiteralPath $safeFixture -Recurse -Force }
}
