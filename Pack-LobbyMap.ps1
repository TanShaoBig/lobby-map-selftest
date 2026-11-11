[CmdletBinding()]
param(
    [string]$SourcePath = '',
    [string]$OutputDirectory = '',
    [string]$ArchiveRoot = '',
    [string[]]$IncludeDirectory = $null,
    [string[]]$IncludeFile = $null,
    [string[]]$ExcludePattern = $null,
    [string]$ConfigPath = '',
    [datetime]$PackageDate = (Get-Date),
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'PackageIdentity.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'lobby-test.local.json'
}
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $configModule = Join-Path $PSScriptRoot 'LobbySelfTestConfig.ps1'
    if (-not (Test-Path -LiteralPath $configModule -PathType Leaf)) { throw '配置文件存在，但缺少读取配置的 LobbySelfTestConfig.ps1。' }
    . $configModule
    $configured = Read-PackagerSettings -Path $ConfigPath
}
else {
    $configured = New-MapPackagerSettings
}

$effectiveSource = if ([string]::IsNullOrWhiteSpace($SourcePath)) { $configured.SourcePath } else { $SourcePath }
$effectiveOutput = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $configured.OutputDirectory } else { $OutputDirectory }
$effectiveRoot = if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $configured.ArchiveRoot } else { $ArchiveRoot }
$effectiveIncludes = if ($null -eq $IncludeDirectory) { $configured.IncludeDirectories } else { $IncludeDirectory }
$effectiveIncludeFiles = if ($null -eq $IncludeFile) { $configured.IncludeFiles } else { $IncludeFile }
$effectiveExcludes = if ($null -eq $ExcludePattern) { $configured.ExcludePatterns } else { $ExcludePattern }

if ([string]::IsNullOrWhiteSpace($effectiveSource)) {
    throw '尚未配置地图源目录。请运行“配置上传自测.cmd”填写源目录，或使用 -SourcePath 指定。'
}
if ([string]::IsNullOrWhiteSpace($effectiveOutput)) {
    $effectiveOutput = Join-Path $PSScriptRoot 'packages'
}

$settings = New-MapPackagerSettings `
    -SourcePath $effectiveSource `
    -OutputDirectory $effectiveOutput `
    -ArchiveRoot $effectiveRoot `
    -IncludeDirectories $effectiveIncludes `
    -IncludeFiles $effectiveIncludeFiles `
    -ExcludePatterns $effectiveExcludes

function Add-FileToArchive {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [byte[]]$ReplacementBytes = $null
    )

    $entry = $Archive.CreateEntry(
        $EntryName,
        [System.IO.Compression.CompressionLevel]::Optimal
    )
    $entryLastWriteTime = [System.DateTimeOffset]$File.LastWriteTime
    if ($entryLastWriteTime.Year -lt 1980) {
        $entryLastWriteTime = [System.DateTimeOffset]::new(
            1980,
            1,
            1,
            0,
            0,
            0,
            [System.TimeSpan]::Zero
        )
    }
    elseif ($entryLastWriteTime.Year -gt 2107) {
        $entryLastWriteTime = [System.DateTimeOffset]::new(
            2107,
            12,
            31,
            23,
            59,
            58,
            [System.TimeSpan]::Zero
        )
    }
    $entry.LastWriteTime = $entryLastWriteTime

    $sourceStream = $null
    $entryStream = $null
    try {
        $entryStream = $entry.Open()
        if ($null -ne $ReplacementBytes) {
            $entryStream.Write($ReplacementBytes, 0, $ReplacementBytes.Length)
            return
        }
        $fileShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $sourceStream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $fileShare
        )
        $sourceStream.CopyTo($entryStream)
    }
    finally {
        if ($null -ne $entryStream) {
            $entryStream.Dispose()
        }
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }
    }
}

function Get-RelativeArchivePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    return $FullPath.Substring($RootPath.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $hashAlgorithm = $null
    $fileStream = $null
    try {
        $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        $fileStream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $hashBytes = $hashAlgorithm.ComputeHash($fileStream)
        return [System.BitConverter]::ToString($hashBytes).Replace('-', '')
    }
    finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
        if ($null -ne $hashAlgorithm) {
            $hashAlgorithm.Dispose()
        }
    }
}

function Assert-PackManifests {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackRoot,

        [Parameter(Mandatory = $true)]
        [string]$PackKind
    )

    $packDirectories = @(Get-ChildItem -LiteralPath $PackRoot -Directory -Force)
    foreach ($packDirectory in $packDirectories) {
        $manifestPath = Join-Path -Path $packDirectory.FullName -ChildPath 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $packFiles = @(Get-ChildItem -LiteralPath $packDirectory.FullName -Recurse -File -Force)
            if ($packFiles.Count -ne 0) {
                throw "$PackKind pack directory contains files but is missing manifest.json: $($packDirectory.FullName)"
            }

            Write-Warning "Skipping empty $PackKind pack directory without manifest.json: $($packDirectory.FullName)"
            Write-Output $packDirectory.FullName
            continue
        }

        $manifestStream = $null
        $manifestReader = $null
        try {
            $fileShare = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $manifestStream = [System.IO.File]::Open(
                $manifestPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                $fileShare
            )

            $prefix = New-Object byte[] 3
            $prefixLength = $manifestStream.Read($prefix, 0, $prefix.Length)
            if (
                $prefixLength -eq 3 -and
                $prefix[0] -eq 0xEF -and
                $prefix[1] -eq 0xBB -and
                $prefix[2] -eq 0xBF
            ) {
                throw 'UTF-8 BOM is not allowed.'
            }
            $manifestStream.Position = 0

            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $manifestReader = New-Object System.IO.StreamReader($manifestStream, $strictUtf8, $false)
            $manifestText = $manifestReader.ReadToEnd()
            $manifestJson = $manifestText | ConvertFrom-Json
            if ($null -eq $manifestJson) {
                throw 'Manifest JSON must not be empty or null.'
            }
            if (-not ($manifestJson.PSObject.Properties.Name -contains 'format_version')) {
                throw 'Manifest JSON is missing format_version.'
            }
            if (-not ($manifestJson.PSObject.Properties.Name -contains 'header')) {
                throw 'Manifest JSON is missing header.'
            }
            if (-not ($manifestJson.PSObject.Properties.Name -contains 'modules')) {
                throw 'Manifest JSON is missing modules.'
            }

            $manifestHeader = $manifestJson.header
            if (
                $null -eq $manifestHeader -or
                -not ($manifestHeader.PSObject.Properties.Name -contains 'uuid') -or
                -not ($manifestHeader.PSObject.Properties.Name -contains 'version')
            ) {
                throw 'Manifest header must contain uuid and version.'
            }

            $parsedUuid = [guid]::Empty
            if (-not [guid]::TryParse([string]$manifestHeader.uuid, [ref]$parsedUuid)) {
                throw 'Manifest header uuid is not a valid UUID.'
            }
            if (@($manifestHeader.version).Count -ne 3) {
                throw 'Manifest header version must contain three components.'
            }
            if (@($manifestJson.modules).Count -eq 0) {
                throw 'Manifest modules must not be empty.'
            }
        }
        catch {
            throw "$PackKind pack manifest is not valid BOM-free UTF-8 JSON: $manifestPath. $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $manifestReader) {
                $manifestReader.Dispose()
            }
            elseif ($null -ne $manifestStream) {
                $manifestStream.Dispose()
            }
        }
    }
}

$resolvedSourcePath = Resolve-Path -LiteralPath $settings.SourcePath
$sourceItem = Get-Item -LiteralPath $resolvedSourcePath.Path -Force
if (-not $sourceItem.PSIsContainer) {
    throw "Source path must be a directory: $($sourceItem.FullName)"
}

$sourceRoot = $sourceItem.FullName.TrimEnd([char[]]@('\', '/'))
$archiveRoot = $settings.ArchiveRoot
$packageDirectories = @($settings.IncludeDirectories)
$packageFiles = @($settings.IncludeFiles)
$packageEntries = @($packageDirectories + $packageFiles)
$archiveRootEntries = @($packageEntries | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique)

foreach ($relativePath in $packageDirectories) {
    $requiredPath = Join-Path -Path $sourceRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
        throw "Required package directory is missing or has the wrong type: $requiredPath"
    }
}
foreach ($relativePath in $packageFiles) {
    $requiredPath = Join-Path -Path $sourceRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required package file is missing or has the wrong type: $requiredPath"
    }
}

$excludedPackDirectories = @()
if ($packageDirectories -icontains 'behavior_packs') {
    $excludedPackDirectories += @(
        Assert-PackManifests `
            -PackRoot (Join-Path -Path $sourceRoot -ChildPath 'behavior_packs') `
            -PackKind 'Behavior'
    )
}
if ($packageDirectories -icontains 'resource_packs') {
    $excludedPackDirectories += @(
        Assert-PackManifests `
            -PackRoot (Join-Path -Path $sourceRoot -ChildPath 'resource_packs') `
            -PackKind 'Resource'
    )
}

$sourceSnapshot = Get-MapSourceSnapshot -SourcePath $sourceRoot -Settings $settings -ExcludedRoots $excludedPackDirectories
$identityPlan = New-MapIdentityContents -Snapshot $sourceSnapshot -RequireFresh

$outputCandidatePath = [System.IO.Path]::GetFullPath($settings.OutputDirectory).TrimEnd([char[]]@('\', '/'))
if (
    $outputCandidatePath.Equals($sourceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputCandidatePath.StartsWith($sourceRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Output directory must not be inside the source tree: $outputCandidatePath"
}

if (-not (Test-Path -LiteralPath $outputCandidatePath)) {
    $null = New-Item -ItemType Directory -Path $outputCandidatePath -Force
}
$resolvedOutputPath = Resolve-Path -LiteralPath $outputCandidatePath
$outputItem = Get-Item -LiteralPath $resolvedOutputPath.Path -Force
if (-not $outputItem.PSIsContainer) {
    throw "Output path must be a directory: $($outputItem.FullName)"
}

$outputRoot = $outputItem.FullName.TrimEnd([char[]]@('\', '/'))
if (
    $outputRoot.Equals($sourceRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    $outputRoot.StartsWith($sourceRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw "Output directory must not be inside the source tree: $outputRoot"
}

$packageStem = 'LobbyMap{0}' -f $PackageDate.ToString('yyyy-MM-dd-HH-mm-ss')
$packageName = "$packageStem.zip"
$packagePath = Join-Path -Path $outputRoot -ChildPath $packageName
$packageSuffix = 2
while (Test-Path -LiteralPath $packagePath) {
    $packageName = '{0}-{1}.zip' -f $packageStem, $packageSuffix
    $packagePath = Join-Path -Path $outputRoot -ChildPath $packageName
    $packageSuffix++
}
$temporaryPath = Join-Path -Path $outputRoot -ChildPath ('.{0}.{1}.tmp' -f $packageName, [guid]::NewGuid().ToString('N'))

$packagedFileCount = 0
$packagedByteCount = [long]0
$includedFilePaths = @($sourceSnapshot.Hashes.Keys | Sort-Object)
$excludedFileCount = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force).Count - $includedFilePaths.Count

try {
    $archiveStream = $null
    $archive = $null
    try {
        $archiveStream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $archive = New-Object System.IO.Compression.ZipArchive(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )

        $directoryEntries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        [void]$directoryEntries.Add("$archiveRoot/")
        foreach ($relativeDirectory in @($sourceSnapshot.Directories)) {
            $segments = $relativeDirectory.Split('/')
            $current = $archiveRoot
            for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
                $current = $current + '/' + $segments[$segmentIndex]
                [void]$directoryEntries.Add("$current/")
            }
        }
        foreach ($entryName in @($directoryEntries | Sort-Object)) {
            $null = $archive.CreateEntry($entryName)
        }

        foreach ($relativeFile in $includedFilePaths) {
            $file = Get-Item -LiteralPath (Join-Path -Path $sourceRoot -ChildPath $relativeFile) -Force
            Add-FileToArchive -Archive $archive -File $file -EntryName "$archiveRoot/$relativeFile" -ReplacementBytes $identityPlan.Contents[$relativeFile]
            $packagedFileCount++
            $packagedByteCount += $file.Length
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
        if ($null -ne $archiveStream) {
            $archiveStream.Dispose()
        }
    }

    $validationArchive = [System.IO.Compression.ZipFile]::OpenRead($temporaryPath)
    try {
        $entryNames = @(
            $validationArchive.Entries |
                ForEach-Object { $_.FullName.Replace('\', '/') }
        )

        $outsideEntries = @(
            $entryNames |
                Where-Object { $_ -ne "$archiveRoot/" -and -not $_.StartsWith("$archiveRoot/") }
        )
        if ($outsideEntries.Count -ne 0) {
            throw "Package validation failed: entries exist outside $archiveRoot/."
        }

        $directChildren = @(
            $entryNames |
                Where-Object { $_ -ne "$archiveRoot/" } |
                ForEach-Object {
                    $remainder = $_.Substring(("$archiveRoot/").Length)
                    $remainder.Split('/')[0]
                } |
                Sort-Object -Unique
        )
        $missingChildren = @($archiveRootEntries | Where-Object { $_ -notin $directChildren })
        $unexpectedChildren = @($directChildren | Where-Object { $_ -notin $archiveRootEntries })
        if ($missingChildren.Count -ne 0 -or $unexpectedChildren.Count -ne 0) {
            throw "Package validation failed: root entries differ from the configured whitelist. Missing=[$($missingChildren -join ', ')], Unexpected=[$($unexpectedChildren -join ', ')]"
        }

        $archiveFiles = @(
            $entryNames |
                Where-Object { -not $_.EndsWith('/') } |
                ForEach-Object { $_.Substring(($archiveRoot.Length + 1)) }
        )
        $missingFiles = @($includedFilePaths | Where-Object { $archiveFiles -notcontains $_ })
        $unexpectedFiles = @($archiveFiles | Where-Object { $includedFilePaths -notcontains $_ })
        if ($missingFiles.Count -ne 0 -or $unexpectedFiles.Count -ne 0) {
            throw "Package validation failed: archive files differ from the configured source set. Missing=[$($missingFiles -join ', ')], Unexpected=[$($unexpectedFiles -join ', ')]"
        }

        foreach ($relativePath in $packageDirectories) {
            if ($entryNames -notcontains "$archiveRoot/$relativePath/") {
                throw "Package validation failed: missing directory $archiveRoot/$relativePath/"
            }
        }
        foreach ($relativePath in $packageFiles) {
            if ($entryNames -notcontains "$archiveRoot/$relativePath") {
                throw "Package validation failed: missing file $archiveRoot/$relativePath"
            }
        }

        $readBuffer = New-Object byte[] 81920
        foreach ($entry in $validationArchive.Entries) {
            if ($entry.FullName.EndsWith('/')) {
                continue
            }

            $entryStream = $null
            try {
                $entryStream = $entry.Open()
                while ($entryStream.Read($readBuffer, 0, $readBuffer.Length) -gt 0) {
                }
            }
            finally {
                if ($null -ne $entryStream) {
                    $entryStream.Dispose()
                }
            }
        }
    }
    finally {
        $validationArchive.Dispose()
    }

    $identityVerification = Assert-MapPackageSource -PackagePath $temporaryPath -Snapshot $sourceSnapshot -RequireFresh
    Move-Item -LiteralPath $temporaryPath -Destination $packagePath
}
catch {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    throw
}

$packageInfo = Get-Item -LiteralPath $packagePath
$packageHash = Get-FileSha256 -Path $packagePath
Write-Host ''
Write-Host 'Map package completed.' -ForegroundColor Green
Write-Host "Source:              $sourceRoot"
Write-Host "Package:             $($packageInfo.FullName)"
Write-Host "Archive root:        $archiveRoot/"
Write-Host "Root entries:        $($packageEntries -join ', ')"
Write-Host "Packaged files:      $packagedFileCount"
Write-Host "Source bytes:        $packagedByteCount"
Write-Host "Package bytes:       $($packageInfo.Length)"
Write-Host "Package SHA-256:      $packageHash"
Write-Host "Exclude patterns:    $((@($settings.ExcludePatterns) -join '; '))"
Write-Host "Files not packaged:   $excludedFileCount"
Write-Host "Skipped empty packs:  $($excludedPackDirectories.Count)"
Write-Host "Randomized UUIDs:     $($identityVerification.RandomizedUuidCount) (all versions preserved)"
Write-Host "Source fingerprint:  $($identityVerification.SourceDigest)"

if ($PassThru) {
    [pscustomobject]@{
        Path                = $packageInfo.FullName
        Sha256              = $packageHash
        Length              = $packageInfo.Length
        FileCount           = $packagedFileCount
        SourceDigest        = $identityVerification.SourceDigest
        SourceDigestAlgorithm = $identityVerification.SourceDigestAlgorithm
        RandomizedUuidCount = $identityVerification.RandomizedUuidCount
        ArchiveRoot         = $archiveRoot
        ExcludePatterns     = [string[]]@($settings.ExcludePatterns)
    }
}
