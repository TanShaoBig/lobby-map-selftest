[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Checks = 0

function Assert-RuleTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Pack rule regression failed: $Message" }
    $script:Checks++
}

function Write-RuleUtf8 {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-RuleManifest {
    param([string]$Kind)
    return (@{
        format_version = 2
        header = @{ name = 'rule fixture'; uuid = [guid]::NewGuid().ToString(); version = @(1, 0, 0) }
        modules = @(@{ type = $Kind; uuid = [guid]::NewGuid().ToString(); version = @(1, 0, 0) })
    } | ConvertTo-Json -Depth 8)
}

function New-RuleMap {
    param([string]$Root)
    foreach ($relative in @('behavior_packs/behavior/entities', 'behavior_packs/behavior/nested', 'resource_packs/resource/textures', 'db', 'custom_data/nested')) {
        New-Item -ItemType Directory -Path (Join-Path $Root $relative) -Force | Out-Null
    }
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/manifest.json') -Text (New-RuleManifest 'data')
    Write-RuleUtf8 -Path (Join-Path $Root 'resource_packs/resource/manifest.json') -Text (New-RuleManifest 'resources')
    $behavior = Get-Content -LiteralPath (Join-Path $Root 'behavior_packs/behavior/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $resource = Get-Content -LiteralPath (Join-Path $Root 'resource_packs/resource/manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @('level.dat', 'level.dat_old', 'levelname.txt', 'world_icon.jpeg')) {
        Write-RuleUtf8 -Path (Join-Path $Root $name) -Text "fixture $name"
    }
    Write-RuleUtf8 -Path (Join-Path $Root 'world_behavior_packs.json') -Text (ConvertTo-Json -InputObject @(@{ pack_id = $behavior.header.uuid; version = @(1, 0, 0) }) -Depth 8)
    Write-RuleUtf8 -Path (Join-Path $Root 'world_resource_packs.json') -Text (ConvertTo-Json -InputObject @(@{ pack_id = $resource.header.uuid; version = @(1, 0, 0) }) -Depth 8)
    Write-RuleUtf8 -Path (Join-Path $Root 'db/CURRENT') -Text 'fixture'
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/keep.py') -Text 'print("keep")'
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/omit.pyc') -Text 'omit'
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/.gitignore') -Text '*'
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/debug.log') -Text 'omit'
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/nested/keep.log') -Text 'keep'
    New-Item -ItemType Directory -Path (Join-Path $Root 'behavior_packs/behavior/__pycache__') -Force | Out-Null
    Write-RuleUtf8 -Path (Join-Path $Root 'behavior_packs/behavior/__pycache__/omit.pyc') -Text 'omit'
    Write-RuleUtf8 -Path (Join-Path $Root 'custom_data/nested/note.txt') -Text 'custom'
    Write-RuleUtf8 -Path (Join-Path $Root 'omit-root.txt') -Text 'omit'
}

function Get-RuleEntries {
    param([string]$Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try { return @($zip.Entries | ForEach-Object { $_.FullName }) }
    finally { $zip.Dispose() }
}

$packagerRoot = Split-Path -Parent $PSScriptRoot
$packScript = Join-Path $packagerRoot 'Pack-LobbyMap.ps1'
$configModule = Join-Path $packagerRoot 'LobbySelfTestConfig.ps1'
. (Join-Path $packagerRoot 'PackageIdentity.ps1')
. $configModule

$fixtureRoot = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('lobbymap-selftest-rule-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $fixtureRoot 'source'
$outputRoot = Join-Path $fixtureRoot 'output'
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

try {
    New-RuleMap -Root $sourceRoot
    $packageDate = [datetime]'2026-01-02T03:04:05'

    # Unit-level glob behaviour: *, **, ?, negation, and directory matching.
    Assert-RuleTest (Test-MapGlobMatch -Path 'a.pyc' -Pattern '**/*.pyc') '**/*.pyc matches a root file'
    Assert-RuleTest (Test-MapGlobMatch -Path 'behavior_packs/x/a.pyc' -Pattern '**/*.pyc') '**/*.pyc matches a nested file'
    Assert-RuleTest (-not (Test-MapGlobMatch -Path 'behavior_packs/x/a.pyc' -Pattern '*.pyc')) '*.pyc stays at one level'
    Assert-RuleTest (Test-MapGlobMatch -Path 'behavior_packs/x/__pycache__/a.pyc' -Pattern '**/__pycache__/**') 'cache pattern matches nested files'
    Assert-RuleTest (Test-MapGlobMatch -Path 'behavior_packs/x/__pycache__/' -Pattern '**/__pycache__/**') 'cache pattern matches the directory itself'
    Assert-RuleTest (Test-MapGlobMatch -Path 'a1.log' -Pattern 'a?.log') '? matches one character'
    Assert-RuleTest (-not (Test-MapPathExcluded -Path 'x/keep.log' -Patterns @('**/*.log', '!**/keep.log'))) 'a later ! rule re-includes a file'
    Assert-RuleTest (Test-MapPathExcluded -Path 'x/omit.log' -Patterns @('**/*.log', '!**/keep.log')) 'negation only re-includes its own match'
    Assert-RuleTest (Test-MapPathExcluded -Path 'x/.gitignore' -Patterns @('**/.gitignore')) 'dotfiles can be excluded'

    # Defaults: standard map whitelist, default excludes, empty directories kept.
    $package = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -PassThru
    Assert-RuleTest ($null -ne $package -and (Test-Path -LiteralPath $package.Path)) 'default pack succeeds'
    $entries = Get-RuleEntries $package.Path
    Assert-RuleTest ($entries -contains 'map/behavior_packs/behavior/entities/') 'empty behavior-pack directory is preserved'
    Assert-RuleTest ($entries -contains 'map/resource_packs/resource/textures/') 'empty resource-pack directory is preserved'
    Assert-RuleTest ($entries -contains 'map/behavior_packs/behavior/keep.py') 'normal scripts are packaged'
    Assert-RuleTest (-not ($entries -contains 'map/behavior_packs/behavior/omit.pyc')) 'default rule excludes .pyc'
    Assert-RuleTest (-not ($entries -contains 'map/behavior_packs/behavior/__pycache__/omit.pyc')) 'default rule excludes __pycache__'
    Assert-RuleTest (-not ($entries -contains 'map/behavior_packs/behavior/.gitignore')) 'default rule excludes .gitignore'
    Assert-RuleTest (-not ($entries -contains 'map/omit-root.txt')) 'root whitelist stays closed'
    Assert-RuleTest (-not (@($entries | Where-Object { $_ -match '(?i)(\.pyc$|__pycache__|(^|/)\.gitignore$)' }).Count)) 'no excluded default artifacts remain'
    Assert-RuleTest ($entries -contains 'map/behavior_packs/behavior/debug.log') 'non-default files stay unless configured'
    $null = Assert-MapPackageSource -PackagePath $package.Path -SourcePath $sourceRoot

    # Custom exclusion list: extra pattern removes logs; negation brings one back.
    $custom = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -ExcludePattern @('**/*.pyc', '**/__pycache__/**', '**/.gitignore', '**/*.log') -PassThru
    $customEntries = Get-RuleEntries $custom.Path
    Assert-RuleTest (-not ($customEntries -contains 'map/behavior_packs/behavior/debug.log')) 'custom pattern excludes debug.log'
    Assert-RuleTest (-not ($customEntries -contains 'map/behavior_packs/behavior/nested/keep.log')) 'custom pattern excludes nested log'

    $negated = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -ExcludePattern @('**/*.log', '!**/keep.log') -PassThru
    $negatedEntries = Get-RuleEntries $negated.Path
    Assert-RuleTest (-not ($negatedEntries -contains 'map/behavior_packs/behavior/debug.log')) 'negated list still excludes other logs'
    Assert-RuleTest ($negatedEntries -contains 'map/behavior_packs/behavior/nested/keep.log') 'negated list re-includes keep.log'

    # Custom include directory and custom archive root.
    $customRoot = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -ArchiveRoot 'world' -IncludeDirectory @('behavior_packs', 'resource_packs', 'db', 'custom_data') -PassThru
    $rootEntries = Get-RuleEntries $customRoot.Path
    Assert-RuleTest ($rootEntries -contains 'world/custom_data/nested/note.txt') 'custom include directory is packaged'
    Assert-RuleTest ($rootEntries -contains 'world/') 'custom archive root is used'
    Assert-RuleTest (-not (@($rootEntries | Where-Object { -not $_.StartsWith('world/') }).Count)) 'all entries sit under the custom root'

    # Nested include directory: parent directory entries are created automatically.
    $nested = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -PackageDate $packageDate -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -IncludeDirectory @('behavior_packs', 'resource_packs', 'db', 'custom_data/nested') -PassThru
    $nestedEntries = Get-RuleEntries $nested.Path
    Assert-RuleTest ($nestedEntries -contains 'map/custom_data/') 'parent of a nested include directory is created'
    Assert-RuleTest ($nestedEntries -contains 'map/custom_data/nested/note.txt') 'nested include directory is packaged'

    # Invalid patterns and paths must fail before producing a package.
    Assert-RuleTest (& { try { New-MapPackagerSettings -ExcludePatterns @('../escape') | Out-Null; $false } catch { $true } }) 'parent traversal pattern is rejected'
    Assert-RuleTest (& { try { New-MapPackagerSettings -IncludeDirectories @('C:\absolute') | Out-Null; $false } catch { $true } }) 'absolute include path is rejected'
    Assert-RuleTest (& { try { & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -ConfigPath (Join-Path $fixtureRoot 'no-config.json') -ExcludePattern @('../escape') | Out-Null; $false } catch { $true } }) 'packer rejects an invalid pattern'

    # Config save/read preserves every generic field, including the lobby component ID.
    $configPath = Join-Path $fixtureRoot 'config.json'
    $settings = [pscustomobject]@{
        ModId = 'fixture-component-id'
        Cookie = 'offline=fixture'
        SourcePath = $sourceRoot
        OutputDirectory = $outputRoot
        ArchiveRoot = 'world'
        IncludeDirectories = @('behavior_packs', 'resource_packs', 'db', 'custom_data')
        IncludeFiles = @('level.dat', 'levelname.txt', 'world_behavior_packs.json', 'world_resource_packs.json')
        ExcludePatterns = @('**/*.pyc', '**/*.log', '!**/keep.log')
    }
    Save-LobbySelfTestConfig -Path $configPath -Settings $settings
    $saved = Read-PackagerSettings -Path $configPath
    Assert-RuleTest ($saved.ModId -ceq 'fixture-component-id') 'lobby component ID round-trips'
    Assert-RuleTest ($saved.SourcePath -ceq $sourceRoot) 'source path round-trips'
    Assert-RuleTest ($saved.OutputDirectory -ceq $outputRoot) 'output path round-trips'
    Assert-RuleTest ($saved.ArchiveRoot -ceq 'world') 'archive root round-trips'
    Assert-RuleTest (@($saved.IncludeDirectories).Count -eq 4) 'include directories round-trip'
    Assert-RuleTest (@($saved.IncludeFiles).Count -eq 4) 'include files round-trip'
    Assert-RuleTest (@($saved.ExcludePatterns).Count -eq 3) 'exclusion rules round-trip'
    $readBack = Read-LobbySelfTestConfig -Path $configPath
    Assert-RuleTest ($readBack.Cookie -ceq 'offline=fixture') 'cookie decrypts for the current user'
    Assert-RuleTest (-not ([System.IO.File]::ReadAllText($configPath)).Contains('offline=fixture')) 'plain cookie is never stored'

    # A package created with the config's rules passes verification with those rules.
    $fromConfig = & $packScript -SourcePath $sourceRoot -OutputDirectory $outputRoot -ConfigPath $configPath -PackageDate $packageDate -PassThru
    $fromConfigEntries = Get-RuleEntries $fromConfig.Path
    Assert-RuleTest ($fromConfigEntries -contains 'world/custom_data/nested/note.txt') 'config include directory applied'
    Assert-RuleTest (-not ($fromConfigEntries -contains 'world/behavior_packs/behavior/debug.log')) 'config exclusion applied'

    # Legacy schemaVersion=1 files remain readable and inherit generic defaults.
    $legacyPath = Join-Path $fixtureRoot 'legacy.json'
    Write-RuleUtf8 -Path $legacyPath -Text ('{"schemaVersion":1,"modId":"legacy-component","cookieProtected":"' + (Protect-LobbyCookie -Cookie 'legacy=fixture') + '"}')
    $legacy = Read-PackagerSettings -Path $legacyPath
    Assert-RuleTest ($legacy.ModId -ceq 'legacy-component') 'legacy config ID is read'
    Assert-RuleTest (@($legacy.IncludeDirectories).Count -eq 3) 'legacy config inherits default includes'
    Assert-RuleTest (@($legacy.ExcludePatterns).Count -eq 3) 'legacy config inherits default excludes'

    # A mismatched settings set must reject an archive built for another whitelist.
    Assert-RuleTest (& { try { Assert-MapPackageSource -PackagePath $package.Path -SourcePath $sourceRoot -Settings (New-MapPackagerSettings -IncludeDirectories @('db') -IncludeFiles @() -SourcePath $sourceRoot) | Out-Null; $false } catch { $true } }) 'settings mismatch is rejected'

    Write-Host ('Pack rule offline regression passed: {0} checks.' -f $script:Checks)
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'lobbymap-selftest-rule-'))
    if (-not $resolved.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
