# Shared, offline-only packaging model and source/UUID validation.
# All changes are archive contents; source projects are never modified.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:MapDefaultIncludeDirectories = @('behavior_packs', 'db', 'resource_packs')
$script:MapDefaultIncludeFiles = @(
    'level.dat',
    'level.dat_old',
    'levelname.txt',
    'world_behavior_packs.json',
    'world_icon.jpeg',
    'world_resource_packs.json'
)
$script:MapDefaultExcludePatterns = @(
    '**/*.pyc',
    '**/__pycache__/**',
    '**/.gitignore'
)

function ConvertTo-MapRelativePath {
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowEmpty
    )

    $value = ([string]$Path).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($AllowEmpty) { return '' }
        throw "$Label 不能为空。"
    }
    $value = $value.Replace('\', '/').TrimStart([char[]]@('/'))
    $value = $value.TrimEnd([char[]]@('/'))
    if ([string]::IsNullOrWhiteSpace($value)) { throw "$Label 不是有效的相对路径。" }
    if ($value -match '[\x00-\x1f\x7f]') { throw "$Label 不能包含控制字符。" }
    if ($value -match '^[A-Za-z]:') { throw "$Label 必须是相对路径，不能包含盘符。" }
    if ($value -match '(^|/)\.\.(/|$)' -or $value -match '(^|/)\.(/|$)') { throw "$Label 不能包含 . 或 .. 路径段。" }
    if ($value -match '[*?]') { throw "$Label 不能包含通配符。" }
    return $value
}

function ConvertTo-MapExcludePattern {
    param(
        [AllowEmptyString()][string]$Pattern,
        [int]$Index = 0
    )

    $value = ([string]$Pattern).Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($value)) { throw "第 $($Index + 1) 条剔除规则为空。" }
    if ($value.Length -gt 512) { throw "第 $($Index + 1) 条剔除规则超过 512 字符。" }
    if ($value -match '[\x00-\x1f\x7f]') { throw "第 $($Index + 1) 条剔除规则包含控制字符。" }
    $body = $value
    if ($body.StartsWith('!')) { $body = $body.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($body)) { throw "第 $($Index + 1) 条剔除规则缺少匹配内容。" }
    if ($body.StartsWith('/') -or $body -match '^[A-Za-z]:') { throw "第 $($Index + 1) 条剔除规则必须使用相对路径。" }
    if ($body -match '(^|/)\.\.(/|$)') { throw "第 $($Index + 1) 条剔除规则不能包含 .. 路径段。" }
    return $value
}

function New-MapPackagerSettings {
    param(
        [AllowEmptyString()][string]$SourcePath = '',
        [AllowEmptyString()][string]$OutputDirectory = '',
        [AllowEmptyString()][string]$ArchiveRoot = 'map',
        [string[]]$IncludeDirectories = $null,
        [string[]]$IncludeFiles = $null,
        [string[]]$ExcludePatterns = $null
    )

    $cleanSource = [Environment]::ExpandEnvironmentVariables(([string]$SourcePath).Trim())
    $cleanOutput = [Environment]::ExpandEnvironmentVariables(([string]$OutputDirectory).Trim())
    $cleanRoot = if ([string]::IsNullOrWhiteSpace([string]$ArchiveRoot)) { 'map' } else { ([string]$ArchiveRoot).Trim() }
    $cleanRoot = $cleanRoot.Replace('\', '/').Trim([char[]]@('/'))
    if ([string]::IsNullOrWhiteSpace($cleanRoot)) { throw '归档根目录不能为空。' }
    if ($cleanRoot -match '[\x00-\x1f\x7f]' -or $cleanRoot -match '(^|/)\.\.?(/|$)') { throw '归档根目录不是安全路径。' }

    if ($null -eq $IncludeDirectories) { $IncludeDirectories = $script:MapDefaultIncludeDirectories }
    if ($null -eq $IncludeFiles) { $IncludeFiles = $script:MapDefaultIncludeFiles }
    if ($null -eq $ExcludePatterns) { $ExcludePatterns = $script:MapDefaultExcludePatterns }

    $directories = @(
        for ($i = 0; $i -lt @($IncludeDirectories).Count; $i++) {
            ConvertTo-MapRelativePath -Path ([string]@($IncludeDirectories)[$i]) -Label "包含目录 #$($i + 1)"
        }
    )
    $files = @(
        for ($i = 0; $i -lt @($IncludeFiles).Count; $i++) {
            ConvertTo-MapRelativePath -Path ([string]@($IncludeFiles)[$i]) -Label "包含文件 #$($i + 1)"
        }
    )
    if ($directories.Count -eq 0 -and $files.Count -eq 0) { throw '包含目录和包含文件不能同时为空。' }

    $patterns = @(
        for ($i = 0; $i -lt @($ExcludePatterns).Count; $i++) {
            ConvertTo-MapExcludePattern -Pattern ([string]@($ExcludePatterns)[$i]) -Index $i
        }
    )

    return [pscustomobject]@{
        SourcePath         = $cleanSource
        OutputDirectory    = $cleanOutput
        ArchiveRoot        = $cleanRoot
        IncludeDirectories = [string[]]$directories
        IncludeFiles       = [string[]]$files
        ExcludePatterns    = [string[]]$patterns
    }
}

function Resolve-MapPackagerSettings {
    param($Settings)

    if ($null -eq $Settings) { return New-MapPackagerSettings }

    $source = ''
    $output = ''
    $root = 'map'
    $directories = $null
    $files = $null
    $patterns = $null

    $property = $Settings.PSObject.Properties['SourcePath']
    if ($null -ne $property -and $null -ne $property.Value) { $source = [string]$property.Value }
    $property = $Settings.PSObject.Properties['OutputDirectory']
    if ($null -ne $property -and $null -ne $property.Value) { $output = [string]$property.Value }
    $property = $Settings.PSObject.Properties['ArchiveRoot']
    if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $root = [string]$property.Value }
    $property = $Settings.PSObject.Properties['IncludeDirectories']
    if ($null -ne $property) { $directories = [string[]]@($property.Value) }
    $property = $Settings.PSObject.Properties['IncludeFiles']
    if ($null -ne $property) { $files = [string[]]@($property.Value) }
    $property = $Settings.PSObject.Properties['ExcludePatterns']
    if ($null -ne $property) { $patterns = [string[]]@($property.Value) }

    return New-MapPackagerSettings `
        -SourcePath $source `
        -OutputDirectory $output `
        -ArchiveRoot $root `
        -IncludeDirectories $directories `
        -IncludeFiles $files `
        -ExcludePatterns $patterns
}

function ConvertTo-MapGlobRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('^')
    $index = 0
    while ($index -lt $Pattern.Length) {
        $character = $Pattern[$index]
        if ($character -eq [char]'*') {
            if ($index + 1 -lt $Pattern.Length -and $Pattern[$index + 1] -eq [char]'*') {
                if ($index + 2 -lt $Pattern.Length -and $Pattern[$index + 2] -eq [char]'/') {
                    [void]$builder.Append('(?:.*/)?')
                    $index += 3
                    continue
                }
                [void]$builder.Append('.*')
                $index += 2
                continue
            }
            [void]$builder.Append('[^/]*')
            $index++
            continue
        }
        if ($character -eq [char]'?') {
            [void]$builder.Append('[^/]')
            $index++
            continue
        }
        [void]$builder.Append([regex]::Escape([string]$character))
        $index++
    }
    [void]$builder.Append('$')
    return $builder.ToString()
}

function Test-MapGlobMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $relative = $Path.Replace('\', '/').TrimStart([char[]]@('/'))
    $patternText = $Pattern.Replace('\', '/')
    if ($patternText.StartsWith('!')) { $patternText = $patternText.Substring(1) }
    $regex = ConvertTo-MapGlobRegex -Pattern $patternText
    return [regex]::IsMatch($relative, $regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-MapPathExcluded {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Patterns = @()
    )

    $excluded = $false
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        if (Test-MapGlobMatch -Path $Path -Pattern ([string]$pattern)) {
            # A leading ! re-includes a path matched by an earlier rule.
            $excluded = -not ([string]$pattern).TrimStart().StartsWith('!')
        }
    }
    return $excluded
}

function Get-MapIdentityProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-MapStreamHash {
    param([System.IO.Stream]$Stream)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Stream)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Test-MapExcludedRoot {
    param([string]$RelativePath, [string[]]$Roots = @())
    foreach ($excludedRoot in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace([string]$excludedRoot)) { continue }
        if (
            $RelativePath.Equals([string]$excludedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $RelativePath.StartsWith([string]$excludedRoot + '/', [StringComparison]::OrdinalIgnoreCase)
        ) { return $true }
    }
    return $false
}

function Get-MapSourceSnapshot {
    param(
        [string]$SourcePath,
        $Settings = $null,
        [string[]]$ExcludedRoots = @()
    )

    if ($null -eq $Settings) { $Settings = New-MapPackagerSettings }
    $root = (Get-Item -LiteralPath $SourcePath -Force).FullName.TrimEnd([char[]]@('\', '/'))
    $paths = New-Object System.Collections.ArrayList
    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $seen = @{}

    foreach ($relativeDirectory in @($Settings.IncludeDirectories)) {
        $directory = Get-Item -LiteralPath (Join-Path $root $relativeDirectory) -Force
        if (-not $directory.PSIsContainer) { throw "Expected source directory: $relativeDirectory" }
        [void]$directories.Add($relativeDirectory)
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Recurse -Force)) {
            $relativeChild = $child.FullName.Substring($root.Length + 1).Replace('\', '/')
            if (Test-MapExcludedRoot -RelativePath $relativeChild -Roots $ExcludedRoots) { continue }
            if (Test-MapPathExcluded -Path ($relativeChild + '/') -Patterns $Settings.ExcludePatterns) { continue }
            [void]$directories.Add($relativeChild)
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force)) {
            $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            if (Test-MapExcludedRoot -RelativePath $relative -Roots $ExcludedRoots) { continue }
            if (Test-MapPathExcluded -Path $relative -Patterns $Settings.ExcludePatterns) { continue }
            if (-not $seen.ContainsKey($relative)) {
                $seen[$relative] = $true
                [void]$paths.Add($file)
            }
        }
    }

    foreach ($relativeFile in @($Settings.IncludeFiles)) {
        $file = Get-Item -LiteralPath (Join-Path $root $relativeFile) -Force
        if ($file.PSIsContainer) { throw "Expected source file: $relativeFile" }
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if (Test-MapPathExcluded -Path $relative -Patterns $Settings.ExcludePatterns) {
            throw "包含文件被剔除规则排除：$relative"
        }
        if (-not $seen.ContainsKey($relative)) {
            $seen[$relative] = $true
            [void]$paths.Add($file)
        }
    }

    $hashes = @{}
    foreach ($file in $paths) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $stream = [System.IO.File]::OpenRead($file.FullName)
        try { $hashes[$relative] = Get-MapStreamHash $stream }
        finally { $stream.Dispose() }
    }
    # Unambiguous UTF-8 path + NUL + uppercase SHA-256 + LF, ordinal path order.
    [string[]]$names = @($hashes.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $builder = New-Object System.Text.StringBuilder
    foreach ($name in $names) { [void]$builder.Append($name).Append([char]0).Append($hashes[$name]).Append([char]10) }
    $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $memory = New-Object System.IO.MemoryStream(, $bytes)
    try { $digest = Get-MapStreamHash $memory }
    finally { $memory.Dispose() }
    return [pscustomobject]@{
        Source         = $root
        Hashes         = $hashes
        Directories    = [string[]]@($directories)
        ExcludedRoots  = [string[]]@($ExcludedRoots)
        Digest         = $digest
        DigestAlgorithm = 'sha256-path-nul-sha256-lf-v1'
        Settings       = $Settings
    }
}

function Convert-MapIdentityJson {
    param([string]$Text)
    $value = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    if ($Text.TrimStart().StartsWith('[')) { return , @($value) }
    if ($null -eq $value -or $value -is [array]) { throw 'Expected a JSON object or array.' }
    return $value
}

function Get-MapCanonicalUuid {
    param($Value)
    $parsed = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw "Invalid pack UUID: $Value" }
    return $parsed.ToString()
}

function Get-MapIdentityDocuments {
    param($Snapshot)
    $documents = @{}
    $definitions = New-Object System.Collections.ArrayList
    $owned = @{}
    $headers = @{}
    foreach ($path in @($Snapshot.Hashes.Keys | Sort-Object)) {
        if ($path -notmatch '^(behavior_packs|resource_packs)/[^/]+/manifest\.json$') { continue }
        $data = Convert-MapIdentityJson ([IO.File]::ReadAllText((Join-Path $Snapshot.Source $path)))
        $documents[$path] = $data
        $header = Get-MapIdentityProperty $data 'header'
        $modules = @(Get-MapIdentityProperty $data 'modules')
        if ($null -eq $header -or $modules.Count -eq 0) { throw "Missing header/modules: $path" }
        $nodes = @($header) + @($modules)
        for ($i = 0; $i -lt $nodes.Count; $i++) {
            $id = Get-MapCanonicalUuid (Get-MapIdentityProperty $nodes[$i] 'uuid')
            if ($owned.ContainsKey($id)) { throw "Duplicate source UUID: $id" }
            $owned[$id] = $true
            [void]$definitions.Add([pscustomobject]@{ Path = $path; Index = $i; Id = $id; Node = $nodes[$i] })
            if ($i -eq 0) { $headers[$id] = $path.Split('/')[0] }
        }
    }
    foreach ($name in @('world_behavior_packs.json', 'world_resource_packs.json')) {
        if (-not $Snapshot.Hashes.ContainsKey($name)) {
            throw "包含文件缺少 $name，无法同步地图的世界包引用。请把该文件加入 includeFiles。"
        }
        $documents[$name] = Convert-MapIdentityJson ([IO.File]::ReadAllText((Join-Path $Snapshot.Source $name)))
        if ($documents[$name] -isnot [array]) { throw "World pack list must be an array: $name" }
    }
    return [pscustomobject]@{ Documents = $documents; Definitions = $definitions; Headers = $headers }
}

function New-MapIdentityContents {
    param($Snapshot, $UuidMap = $null, [switch]$RequireFresh)
    $identity = Get-MapIdentityDocuments $Snapshot
    if ($null -eq $UuidMap) {
        $UuidMap = @{}
        $newIds = @{}
        foreach ($definition in $identity.Definitions) {
            do { $id = [guid]::NewGuid().ToString() } while ($newIds.ContainsKey($id) -or @($identity.Definitions.Id) -contains $id)
            $UuidMap[$definition.Id] = $id
            $newIds[$id] = $true
        }
    }
    if ($UuidMap.Count -ne $identity.Definitions.Count) { throw 'UUID mapping does not cover every definition.' }
    $targets = @{}
    $changed = 0
    foreach ($definition in $identity.Definitions) {
        if (-not $UuidMap.ContainsKey($definition.Id)) { throw 'Incomplete UUID mapping.' }
        $id = Get-MapCanonicalUuid $UuidMap[$definition.Id]
        if ($targets.ContainsKey($id)) { throw "Duplicate package UUID: $id" }
        $targets[$id] = $true
        if ($id -ne $definition.Id) { $changed++ }
        if ($RequireFresh -and ($id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or @($identity.Definitions.Id) -contains $id)) { throw "Package UUID is not a fresh version-4 UUID: $id" }
        $definition.Node.uuid = $UuidMap[$definition.Id]
    }
    foreach ($path in @($identity.Documents.Keys)) {
        $data = $identity.Documents[$path]
        if ($path -match '/manifest\.json$') {
            foreach ($dependency in @(Get-MapIdentityProperty $data 'dependencies')) {
                $value = Get-MapIdentityProperty $dependency 'uuid'
                if ($null -eq $value) { continue } # Native module_name dependencies are unchanged.
                $old = Get-MapCanonicalUuid $value
                if ($UuidMap.ContainsKey($old)) {
                    if (-not $identity.Headers.ContainsKey($old)) { throw 'A dependency refers to a module UUID, not a pack header.' }
                    $dependency.uuid = $UuidMap[$old]
                }
            }
        }
        else {
            $kind = if ($path -eq 'world_behavior_packs.json') { 'behavior_packs' } else { 'resource_packs' }
            foreach ($entry in @($data)) {
                $old = Get-MapCanonicalUuid (Get-MapIdentityProperty $entry 'pack_id')
                if (-not $identity.Headers.ContainsKey($old) -or $identity.Headers[$old] -ne $kind) { throw "World list references a missing or wrong-kind pack: $path / $old" }
                $entry.pack_id = $UuidMap[$old]
            }
        }
    }
    $contents = @{}
    foreach ($path in $identity.Documents.Keys) {
        $text = (ConvertTo-Json -InputObject $identity.Documents[$path] -Depth 100) + "`n"
        $contents[$path] = [Text.Encoding]::UTF8.GetBytes($text)
    }
    return [pscustomobject]@{ Contents = $contents; Map = $UuidMap; Count = $changed; Documents = $identity.Documents }
}

function Read-MapArchiveText {
    param($Entry)
    $stream = $Entry.Open()
    $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Test-MapArchiveRelativePathIncluded {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$Settings
    )

    $relative = $RelativePath.Replace('\', '/').TrimStart([char[]]@('/')).TrimEnd([char[]]@('/'))
    if ([string]::IsNullOrWhiteSpace($relative)) { return $true }
    foreach ($directory in @($Settings.IncludeDirectories)) {
        if ($relative.Equals($directory, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($relative.StartsWith($directory + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($directory.StartsWith($relative + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($file in @($Settings.IncludeFiles)) {
        if ($relative.Equals($file, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($file.StartsWith($relative + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-MapPackageSource {
    param(
        [string]$SourcePath,
        [string]$PackagePath,
        $Snapshot = $null,
        [string]$ExpectedSourceDigest = '',
        [switch]$RequireFresh,
        $Settings = $null
    )
    if ($null -eq $Settings) {
        if ($null -ne $Snapshot -and $null -ne $Snapshot.Settings) { $Settings = $Snapshot.Settings }
        else { $Settings = New-MapPackagerSettings }
    }
    $Settings = Resolve-MapPackagerSettings -Settings $Settings
    if ($null -eq $Snapshot) { $Snapshot = Get-MapSourceSnapshot -SourcePath $SourcePath -Settings $Settings }
    if ($ExpectedSourceDigest -and $Snapshot.Digest -cne $ExpectedSourceDigest) { throw 'Source changed since packaging.' }
    $identity = Get-MapIdentityDocuments $Snapshot
    $archiveRoot = ([string]$Settings.ArchiveRoot).Trim('/')
    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $files = @{}
        $seen = @{}
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ($name -ne "$archiveRoot/" -and -not $name.StartsWith("$archiveRoot/", [StringComparison]::Ordinal)) { throw "Unexpected ZIP path: $name" }
            if ($name -match '\\|(^|/)\.\.?(/|$)|//' -or $name.Contains([string][char]0)) { throw 'Invalid ZIP path.' }
            $key = $name.TrimEnd('/')
            if ($seen.ContainsKey($key)) { throw "Duplicate ZIP path: $name" }
            $seen[$key] = $true
            if ($name -eq "$archiveRoot/") { continue }
            $relative = $name.Substring($archiveRoot.Length + 1)
            if (-not (Test-MapArchiveRelativePathIncluded -RelativePath $relative -Settings $Settings)) { throw "Unexpected ZIP path: $name" }
            if (-not $name.EndsWith('/')) { $files[$relative] = $entry }
        }
        if ($files.Count -ne $Snapshot.Hashes.Count) { throw 'ZIP/source file count mismatch.' }
        foreach ($path in $Snapshot.Hashes.Keys) { if (-not $files.ContainsKey($path)) { throw "Missing ZIP file: $path" } }
        $candidateDocuments = @{}
        foreach ($path in $identity.Documents.Keys) { $candidateDocuments[$path] = Convert-MapIdentityJson (Read-MapArchiveText $files[$path]) }
        $mapping = @{}
        foreach ($definition in $identity.Definitions) {
            $document = $candidateDocuments[$definition.Path]
            $node = if ($definition.Index -eq 0) { Get-MapIdentityProperty $document 'header' } else {
                $modules = @(Get-MapIdentityProperty $document 'modules')
                if ($definition.Index -gt $modules.Count) { throw 'Missing package module.' }
                $modules[$definition.Index - 1]
            }
            $mapping[$definition.Id] = Get-MapIdentityProperty $node 'uuid'
        }
        $expected = New-MapIdentityContents -Snapshot $Snapshot -UuidMap $mapping -RequireFresh:$RequireFresh
        foreach ($path in $Snapshot.Hashes.Keys) {
            if ($expected.Documents.ContainsKey($path)) {
                $actualJson = ConvertTo-Json -InputObject $candidateDocuments[$path] -Depth 100 -Compress
                $expectedJson = ConvertTo-Json -InputObject $expected.Documents[$path] -Depth 100 -Compress
                if ($actualJson -cne $expectedJson) { throw "Metadata changed beyond UUID fields (including versions/references): $path" }
            }
            else {
                $stream = $files[$path].Open()
                try { $hash = Get-MapStreamHash $stream }
                finally { $stream.Dispose() }
                if ($hash -cne $Snapshot.Hashes[$path]) { throw "ZIP/source content mismatch: $path" }
            }
        }
    }
    finally { $archive.Dispose() }
    $after = Get-MapSourceSnapshot -SourcePath $Snapshot.Source -Settings $Settings -ExcludedRoots $Snapshot.ExcludedRoots
    if ($after.Digest -cne $Snapshot.Digest) { throw 'Source changed during package verification.' }
    return [pscustomobject]@{ SourceDigest = $Snapshot.Digest; SourceDigestAlgorithm = $Snapshot.DigestAlgorithm; RandomizedUuidCount = $expected.Count }
}
