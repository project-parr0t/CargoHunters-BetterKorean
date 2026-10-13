[CmdletBinding()]
param(
    [ValidateSet('','0','1','2','3')][string]$Choice = '',
    [string]$PackageRoot = $PSScriptRoot,
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Cargo Hunters',
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$script:NonInteractive = [Environment]::GetCommandLineArgs() -contains '-NonInteractive'
$script:ExplicitGameRoot = $PSBoundParameters.ContainsKey('GameRoot')
$script:DefaultGameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Cargo Hunters'
$script:SelectedGameRoot = $null
$script:LastOutcome = $null
$script:MutationStarted = $false
$script:DelegatedToElevated = $false
$script:PatchId = 'cargo-hunters-ko-v31-r3'
$script:MarkerName = 'last_korean_patch_id.txt'
function Write-PatchMessage([string]$Kind, [string]$Message) {
    $colors = @{ '확인' = 'Cyan'; '주의' = 'Yellow'; '중단' = 'Red'; '완료' = 'Green' }
    Write-Host ("[" + $Kind + "] " + $Message) -ForegroundColor $colors[$Kind]
}
function Read-PatchChoice {
    Write-Host '한국어 패치'
    Write-Host '1. 설치 또는 업데이트 (권장)'
    Write-Host '2. 제거'
    Write-Host '3. 패키지 검사'
    Write-Host '0. 종료'
    while ($true) {
        $selected = (Read-Host '번호를 입력하세요 (Enter: 1)').Trim()
        if ($selected -eq '') { return '1' }
        if ($selected -in @('0','1','2','3')) { return $selected }
        Write-PatchMessage '주의' '0, 1, 2, 3 중 하나를 입력해 주세요.'
    }
}
function Normalize-GamePath([string]$Value) {
    $value = $Value.Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) { $value = $value.Substring(1, $value.Length - 2).Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'E_GAME_PATH_INVALID' }
    try {
        $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($value.Replace('/','\')))
        if ($path -ne [IO.Path]::GetPathRoot($path)) { $path = $path.TrimEnd('\','/') }
        return $path
    } catch { throw 'E_GAME_PATH_INVALID' }
}
function Get-SteamRegistryRoots {
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
            $base = $null; $key = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $key = $base.OpenSubKey('Software\Valve\Steam', $false)
                if ($null -ne $key) {
                    foreach ($name in @('SteamPath','InstallPath')) {
                        $value = $key.GetValue($name)
                        if ($value -is [string] -and ![string]::IsNullOrWhiteSpace($value)) { $value }
                    }
                }
            } catch { } finally { if ($null -ne $key) { $key.Dispose() }; if ($null -ne $base) { $base.Dispose() } }
        }
    }
}
function Get-FixedDriveRoots {
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) { $drive.RootDirectory.FullName }
    }
}
function Convert-VdfString([string]$Value) {
    $builder = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ($Value[$i] -eq '\' -and $i + 1 -lt $Value.Length -and ($Value[$i + 1] -eq '\' -or $Value[$i + 1] -eq '"')) { $i++ }
        [void]$builder.Append($Value[$i])
    }
    return $builder.ToString()
}
function Read-VdfObject([object[]]$Tokens, [ref]$Index, [bool]$Nested) {
    $result = @{}
    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value]; $Index.Value++
        if ($token.Type -eq 'close') {
            if (!$Nested) { throw 'E_STEAM_METADATA_INVALID' }
            return $result
        }
        if ($token.Type -ne 'text' -or $Index.Value -ge $Tokens.Count -or $result.ContainsKey($token.Value)) { throw 'E_STEAM_METADATA_INVALID' }
        $next = $Tokens[$Index.Value]; $Index.Value++
        if ($next.Type -eq 'open') { $result[$token.Value] = Read-VdfObject $Tokens $Index $true }
        elseif ($next.Type -eq 'text') { $result[$token.Value] = $next.Value }
        else { throw 'E_STEAM_METADATA_INVALID' }
    }
    if ($Nested) { throw 'E_STEAM_METADATA_INVALID' }
    return $result
}
function Read-SteamVdf([string]$Path) {
    if ((New-Object IO.FileInfo($Path)).Length -gt 2097152) { throw 'E_STEAM_METADATA_TOO_LARGE' }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $tokens = New-Object 'Collections.Generic.List[object]'
    foreach ($match in [regex]::Matches($text, '//[^\r\n]*|"((?:\\.|[^"\\])*)"|([{}])')) {
        if ($match.Groups[1].Success) { $tokens.Add(@{ Type = 'text'; Value = Convert-VdfString $match.Groups[1].Value }) }
        elseif ($match.Groups[2].Success) { $tokens.Add(@{ Type = $(if ($match.Groups[2].Value -eq '{') { 'open' } else { 'close' }); Value = '' }) }
    }
    $index = 0
    return Read-VdfObject $tokens.ToArray() ([ref]$index) $false
}
function Add-GameCandidate($Map, [string]$Path, [string]$Source) {
    try { $normalized = Normalize-GamePath $Path } catch { return }
    if ($Map.ContainsKey($normalized)) {
        if ($Source -notin $Map[$normalized].Sources) { $Map[$normalized].Sources += $Source }
    } else { $Map[$normalized] = [pscustomobject]@{ Path = $normalized; Sources = @($Source) } }
}
function Get-GameCandidates([string]$ExplicitPath = '') {
    $candidates = @{}; $steamRoots = @{}; $libraries = @{}
    if ($ExplicitPath) { Add-GameCandidate $candidates $ExplicitPath 'explicit' }
    Add-GameCandidate $candidates $script:DefaultGameRoot 'default'
    $defaultSteam = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($script:DefaultGameRoot)))
    Add-GameCandidate $steamRoots $defaultSteam 'default-steam-root'
    foreach ($root in @(Get-SteamRegistryRoots)) { Add-GameCandidate $steamRoots $root 'registry-steam-root' }
    foreach ($drive in @(Get-FixedDriveRoots)) {
        foreach ($relative in @('SteamLibrary','Steam','Program Files\Steam','Program Files (x86)\Steam')) { Add-GameCandidate $steamRoots (Join-Path $drive $relative) 'fixed-drive-standard' }
    }
    foreach ($root in $steamRoots.Values) {
        Add-GameCandidate $libraries $root.Path ($root.Sources -join '+')
        $vdf = Join-Path $root.Path 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            try {
                $data = Read-SteamVdf $vdf
                $folders = $data['libraryfolders']
                if ($folders -is [Collections.IDictionary]) {
                    foreach ($key in $folders.Keys) {
                        if ($key -notmatch '^\d+$') { continue }
                        $entry = $folders[$key]
                        if ($entry -is [Collections.IDictionary]) { $entry = $entry['path'] }
                        if ($entry -is [string]) { Add-GameCandidate $libraries $entry 'libraryfolders-vdf' }
                    }
                }
            } catch { Write-PatchMessage '주의' 'Steam 라이브러리 정보 일부를 읽지 못했습니다. 확인 가능한 위치에서 계속 찾습니다.' }
        }
    }
    foreach ($library in $libraries.Values) {
        $steamapps = [IO.Path]::Combine($library.Path, 'steamapps')
        if (!(Test-Path -LiteralPath $steamapps -PathType Container)) { continue }
        $gamePath = [IO.Path]::Combine($steamapps, 'common', 'Cargo Hunters')
        Add-GameCandidate $candidates $gamePath ($library.Sources -join '+')
        foreach ($file in [IO.Directory]::EnumerateFiles($steamapps, 'appmanifest_*.acf', [IO.SearchOption]::TopDirectoryOnly)) {
            try {
                $manifest = Read-SteamVdf $file
                $state = $manifest['AppState']
                if ($state -is [Collections.IDictionary] -and $state['installdir'] -ieq 'Cargo Hunters') {
                    Add-GameCandidate $candidates (Join-Path $steamapps ('common\' + $state['installdir'])) 'appmanifest-installdir'
                }
            } catch { }
        }
    }
    return @($candidates.Values | Sort-Object Path)
}
function Test-VerifiedGamePath([string]$Package, [string]$Path) {
    try {
        $normalized = Normalize-GamePath $Path
        if (!(Test-Path -LiteralPath $normalized -PathType Container)) { return $false }
        Assert-GameIdentity $Package $normalized
        return $true
    } catch { return $false }
}
function Read-ManualGamePath([string]$Package) {
    while ($true) {
        $value = Read-Host '게임 폴더 경로를 입력하거나 탐색기에서 끌어 놓으세요 (Q: 취소)'
        if ($value.Trim() -ieq 'Q') { throw 'E_USER_CANCELLED' }
        try { $path = Normalize-GamePath $value } catch { $path = $null }
        if ($null -ne $path -and (Test-VerifiedGamePath $Package $path)) { return $path }
        Write-PatchMessage '주의' '이 패치에 맞는 게임 폴더가 아닙니다. 경로를 확인해 다시 입력해 주세요. 아무 파일도 변경하지 않았습니다.'
    }
}
function Resolve-GamePath([string]$Package, [string]$Requested, [bool]$WasExplicit) {
    if ($WasExplicit) {
        try { $path = Normalize-GamePath $Requested } catch { $path = $null }
        if ($null -ne $path -and (Test-VerifiedGamePath $Package $path)) { return $path }
        Write-PatchMessage '중단' '지정한 폴더에서 이 패치에 맞는 게임을 확인하지 못했습니다. 아무 파일도 변경하지 않았습니다.'
        return Read-ManualGamePath $Package
    }
    Write-PatchMessage '확인' 'Steam 설치 위치 찾는 중...'
    $valid = @((Get-GameCandidates) | Where-Object { Test-VerifiedGamePath $Package $_.Path })
    if ($valid.Count -eq 1) { Write-PatchMessage '확인' '게임 설치 위치를 찾았습니다.'; return $valid[0].Path }
    if ($valid.Count -gt 1) {
        Write-PatchMessage '주의' '게임이 여러 위치에 있습니다. 패치를 적용할 위치를 선택해 주세요.'
        for ($i = 0; $i -lt $valid.Count; $i++) { Write-Host (([string]($i + 1)) + '. ' + $valid[$i].Path) }
        while ($true) {
            $answer = (Read-Host '번호를 입력하세요 (Q: 취소)').Trim()
            if ($answer -ieq 'Q') { throw 'E_USER_CANCELLED' }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $valid.Count) { return $valid[$number - 1].Path }
            Write-PatchMessage '주의' '목록에 있는 번호를 입력해 주세요.'
        }
    }
    Write-PatchMessage '주의' '게임 설치 위치를 찾지 못했습니다. 게임 폴더를 직접 선택해 주세요.'
    return Read-ManualGamePath $Package
}
function Get-FriendlyError([string]$Code) {
    $messages = @{
        E_GAME_RUNNING = '게임이 실행 중입니다. 게임을 완전히 종료한 다음 다시 실행해 주세요.'
        E_USER_CANCELLED = '작업을 취소했습니다.'
        E_GAME_PATH_INVALID = '게임 폴더 경로를 확인한 다음 다시 실행해 주세요.'
        E_GAME_ROOT_REQUIRED = '게임 폴더를 찾지 못했습니다. Steam에서 설치 위치를 확인해 주세요.'
        E_GAME_IDENTITY_MISMATCH = '선택한 폴더에서 대상 게임을 확인하지 못했습니다. 게임 설치 폴더를 다시 선택해 주세요.'
        E_GAME_BINDING_MISMATCH = '게임 버전이 이 패치와 맞지 않습니다. 현재 게임 버전에 맞는 패키지를 사용해 주세요.'
        E_UAC_CANCELLED_OR_FAILED = '관리자 권한 요청이 취소되었거나 열리지 않았습니다. 설치하려면 다시 실행해 권한을 허용해 주세요.'
        E_PATCH_NOT_INSTALLED = '설치된 한국어 패치 표시를 찾지 못했습니다.'
        E_INSTALL_INCOMPLETE = '설치가 완료되지 않았습니다. 같은 설치기를 다시 실행해 주세요.'
        E_PACKAGE_FILE_MISSING = '패키지 파일 일부가 없습니다. ZIP을 다시 압축 해제해 주세요.'
        E_PACKAGE_FILE_MISMATCH = '패키지 파일이 손상되었습니다. ZIP을 다시 받아 압축 해제해 주세요.'
    }
    if ($messages.ContainsKey($Code)) { return $messages[$Code] }
    return '작업을 안전하게 마치지 못했습니다. 패키지를 보관하고 아래 문제 코드를 알려 주세요.'
}
function Set-PatchOutcome([string]$Code) { $script:LastOutcome = $Code; if ($script:NonInteractive) { Write-Output $Code } }
function Show-PatchSuccess {
    $labels = @{ I_DRIVER_INSTALLED = '새 설치'; I_DRIVER_UPDATED = '업데이트'; I_ALREADY_INSTALLED = '이미 설치됨'; I_DRIVER_REMOVED = '제거'; I_DRIVER_VERIFIED = '패키지 검사 성공'; I_USER_EXIT = '종료' }
    Write-PatchMessage '완료' $labels[$script:LastOutcome]
    if ($script:SelectedGameRoot) { Write-Host ('게임 위치: ' + $script:SelectedGameRoot) }
}
function Get-Digest([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
function Get-SafePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains(':') -or [IO.Path]::IsPathRooted($Relative) -or ($Relative -split '[\\/]') -contains '..' -or ($Relative -split '[\\/]') -contains '.') { throw 'E_UNSAFE_PATH' }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (!$path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'E_UNSAFE_PATH' }
    $probe = $path
    while ($probe.Length -ge $Root.Length) {
        if ((Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'E_REPARSE_PATH' }
        if ($probe -eq $Root) { break }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
    return $path
}
function Get-InstallMap([string]$Root) {
    $manifestPath = Join-Path $Root 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.strategy -ne 'additive_runtime_only') { throw 'E_PACKAGE_MANIFEST_INVALID' }
    $map = @{}
    foreach ($row in $manifest.files) {
        if ($map.ContainsKey($row.path) -or $row.path -eq 'package-manifest.json') { throw 'E_MANIFEST_DUPLICATE' }
        [void](Get-SafePath $Root $row.path)
        $map[$row.path] = @{ path = [string]$row.path; bytes = [long]$row.bytes; sha256 = [string]$row.sha256 }
    }
    $map['package-manifest.json'] = @{ path = 'package-manifest.json'; bytes = (Get-Item -LiteralPath $manifestPath).Length; sha256 = Get-Digest $manifestPath }
    return $map
}
function Assert-SupportFiles([string]$Root) {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'package-manifest.json') -Raw | ConvertFrom-Json
    $allowed = @('Install-Korean-Patch.bat','Install-Korean-Patch.ps1')
    if (@($manifest.support_files).Count -ne 2) { throw 'E_SUPPORT_INVENTORY_INVALID' }
    $seen = @{}
    foreach ($row in $manifest.support_files) {
        if ($row.path -notin $allowed -or $seen.ContainsKey($row.path)) { throw 'E_SUPPORT_INVENTORY_INVALID' }
        $seen[$row.path] = $true
        $path = Get-SafePath $Root $row.path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $row.bytes -or (Get-Digest $path) -ne $row.sha256) { throw 'E_SUPPORT_HASH_MISMATCH' }
    }
    foreach ($row in $manifest.files) { if ($row.path -in $allowed -or $row.path.StartsWith('upgrade/', [StringComparison]::OrdinalIgnoreCase)) { throw 'E_SUPPORT_INSTALL_FORBIDDEN' } }
}
function Assert-PackageFiles([string]$Package, $Map) {
    foreach ($row in $Map.Values) {
        $path = Get-SafePath $Package $row.path
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'E_PACKAGE_FILE_MISSING' }
        if ((Get-Item -LiteralPath $path).Length -ne $row.bytes -or (Get-Digest $path) -ne $row.sha256) { throw 'E_PACKAGE_FILE_MISMATCH' }
    }
}
function Test-CurrentInstall([string]$Root, $Map) {
    $marker = Get-SafePath $Root $script:MarkerName
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -cne $script:PatchId) { return $false }
    foreach ($row in $Map.Values) {
        $path = Get-SafePath $Root $row.path
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $path).Length -ne $row.bytes -or (Get-Digest $path) -ne $row.sha256) { return $false }
    }
    return $true
}
function Remove-PatchFiles([string]$Root, $Map) {
    $directories = @{}
    foreach ($row in $Map.Values) {
        $path = Get-SafePath $Root $row.path
        if (Test-Path -LiteralPath $path) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'E_TARGET_PATH_INVALID' }
            Remove-Item -LiteralPath $path -Force
        }
        $parent = [IO.Path]::GetDirectoryName($path)
        while ($parent.Length -gt $Root.Length) { $directories[$parent] = $true; $parent = [IO.Path]::GetDirectoryName($parent) }
    }
    $marker = Get-SafePath $Root $script:MarkerName
    if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
    foreach ($directory in @($directories.Keys | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and @([IO.Directory]::EnumerateFileSystemEntries($directory)).Count -eq 0) { Remove-Item -LiteralPath $directory -Force }
    }
}
function Install-PatchFiles([string]$Package, [string]$Root, $Map) {
    try {
        foreach ($row in $Map.Values) {
            $source = Get-SafePath $Package $row.path
            $target = Get-SafePath $Root $row.path
            $parent = [IO.Path]::GetDirectoryName($target)
            [void][IO.Directory]::CreateDirectory($parent)
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        foreach ($row in $Map.Values) {
            $target = Get-SafePath $Root $row.path
            if (!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-Item -LiteralPath $target).Length -ne $row.bytes -or (Get-Digest $target) -ne $row.sha256) { throw 'E_INSTALL_INCOMPLETE' }
        }
        $marker = Get-SafePath $Root $script:MarkerName
        $temporary = Get-SafePath $Root ('.' + $script:MarkerName + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, $script:PatchId + [Environment]::NewLine, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $temporary -Destination $marker -Force
    } catch {
        $marker = Get-SafePath $Root $script:MarkerName
        if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }
        throw 'E_INSTALL_INCOMPLETE'
    }
}
function Assert-GameIdentity([string]$Package, [string]$Root) {
    $bindingPath = Join-Path $Package 'BepInEx\plugins\PrivateStructuredKorean\source-binding.json'
    $bindings = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
    if (@($bindings).Count -ne 3 -or !(Test-Path -LiteralPath (Join-Path $Root 'GameAssembly.dll') -PathType Leaf)) { throw 'E_GAME_IDENTITY_MISMATCH' }
    foreach ($binding in $bindings) {
        $path = Get-SafePath $Root $binding.relative_path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Digest $path) -ne $binding.sha256) { throw 'E_GAME_BINDING_MISMATCH' }
    }
    $interop = Get-Content -LiteralPath (Join-Path $Package 'offline-interop-report.json') -Raw | ConvertFrom-Json
    if (!$interop.input_hashes.game_assembly_sha256 -or !$interop.input_hashes.metadata_sha256) { throw 'E_GAME_IDENTITY_MISMATCH' }
    $metadata = Join-Path $Root 'CargoHunters_Data\il2cpp_data\Metadata\global-metadata.dat'
    if (!(Test-Path -LiteralPath $metadata -PathType Leaf) -or (Get-Digest (Join-Path $Root 'GameAssembly.dll')) -ne $interop.input_hashes.game_assembly_sha256 -or (Get-Digest $metadata) -ne $interop.input_hashes.metadata_sha256) { throw 'E_GAME_BINDING_MISMATCH' }
}
function Assert-GameStopped([string]$Root) {
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('CargoHunters')) {
        try { $path = $process.MainModule.FileName } catch { throw 'E_GAME_RUNNING' }
        if ($path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'E_GAME_RUNNING' }
    }
}
function Test-NeedsElevation([string]$Root) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $false }
    try {
        $ids = @($identity.User.Value) + @($identity.Groups | ForEach-Object { $_.Value })
        $rules = [IO.Directory]::GetAccessControl($Root).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        $allow = [long]0; $deny = [long]0
        foreach ($rule in $rules) {
            if ($rule.IdentityReference.Value -in $ids) {
                if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) { $deny = $deny -bor [long]$rule.FileSystemRights }
                else { $allow = $allow -bor [long]$rule.FileSystemRights }
            }
        }
        $needed = [long][Security.AccessControl.FileSystemRights]::Modify
        return (($deny -band $needed) -ne 0 -or ($allow -band $needed) -ne $needed)
    } catch { return $true }
}
function New-ElevationCommand([string]$Script, [string]$Selected, [string]$Package, [string]$Target) {
    $command = "& '" + $Script.Replace("'", "''") + "' -Choice '" + $Selected.Replace("'", "''") + "' -PackageRoot '" + $Package.Replace("'", "''") + "' -GameRoot '" + $Target.Replace("'", "''") + "' -Elevated"
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}
function Invoke-PatchAction([string]$Selected, [string]$Package, [string]$Target, [bool]$IsElevated) {
    $package = [IO.Path]::GetFullPath($Package).TrimEnd('\','/')
    if ($package -ne [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')) { throw 'E_PACKAGE_ROOT_MISMATCH' }
    Write-PatchMessage '확인' '패키지 확인 중...'
    Assert-SupportFiles $package
    $map = Get-InstallMap $package
    Assert-PackageFiles $package $map
    if ($Selected -eq '3') { Set-PatchOutcome 'I_DRIVER_VERIFIED'; return 0 }
    if ($IsElevated) {
        $target = Normalize-GamePath $Target
        if (!(Test-VerifiedGamePath $package $target)) { throw 'E_GAME_BINDING_MISMATCH' }
    } else { $target = Resolve-GamePath $package $Target $script:ExplicitGameRoot }
    $script:SelectedGameRoot = $target
    Assert-GameIdentity $package $target
    Assert-GameStopped $target
    if (!$IsElevated -and (Test-NeedsElevation $target)) {
        $encoded = New-ElevationCommand (Join-Path $package 'Install-Korean-Patch.ps1') $Selected $package $target
        try { $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -Wait -PassThru -WindowStyle Normal }
        catch { throw 'E_UAC_CANCELLED_OR_FAILED' }
        $script:DelegatedToElevated = $true
        return $process.ExitCode
    }
    $markerPath = Get-SafePath $target $script:MarkerName
    if ($Selected -eq '2') {
        if (!(Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'E_PATCH_NOT_INSTALLED' }
        Write-PatchMessage '확인' '패치 제거 중...'
        $script:MutationStarted = $true
        Remove-PatchFiles $target $map
        Set-PatchOutcome 'I_DRIVER_REMOVED'; return 0
    }
    Write-PatchMessage '확인' '기존 패치 확인 중...'
    if (Test-CurrentInstall $target $map) {
        Set-PatchOutcome 'I_ALREADY_INSTALLED'; return 0
    }
    $hadPrevious = Test-Path -LiteralPath $markerPath -PathType Leaf
    $script:MutationStarted = $true
    if ($hadPrevious) {
        Write-PatchMessage '확인' '이전 패치 제거 중...'
        Remove-PatchFiles $target $map
        Write-PatchMessage '확인' '새 패치 설치 중...'
    } else { Write-PatchMessage '확인' '패치 설치 중...' }
    Install-PatchFiles $package $target $map
    Set-PatchOutcome $(if ($hadPrevious) { 'I_DRIVER_UPDATED' } else { 'I_DRIVER_INSTALLED' })
    return 0
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($Choice -eq '') { if ($script:NonInteractive) { $Choice = '1' } else { $Choice = Read-PatchChoice } }
        if ($Choice -eq '0') { Set-PatchOutcome 'I_USER_EXIT'; if (!$script:NonInteractive) { Show-PatchSuccess }; exit 0 }
        $result = @(Invoke-PatchAction $Choice $PackageRoot $GameRoot ([bool]$Elevated))
        if ($script:NonInteractive) { foreach ($line in $result[0..($result.Count - 2)]) { if ($line -is [string]) { Write-Output $line } } }
        elseif (!$script:DelegatedToElevated) { Show-PatchSuccess; [void](Read-Host 'Enter를 누르면 닫습니다') }
        exit [int]$result[-1]
    } catch {
        $code = $_.Exception.Message
        if (!$code.StartsWith('E_', [StringComparison]::Ordinal)) { $code = 'E_DRIVER_FAILED' }
        Write-PatchMessage '중단' (Get-FriendlyError $code)
        if (!$script:MutationStarted) { Write-Host '아무 파일도 변경하지 않았습니다.' }
        Write-Host ('문제 코드: ' + $code)
        if (!$script:NonInteractive -and [Environment]::UserInteractive) { [void](Read-Host 'Enter를 누르면 닫습니다') }
        exit 1
    }
}
