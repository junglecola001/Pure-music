param(
    [string]$ConfigDirectory = (Join-Path $env:APPDATA 'com.follow/clash'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$taskConfigRoot = (Resolve-Path -LiteralPath $ConfigDirectory).Path
$taskProfileRoot = Join-Path $taskConfigRoot 'profiles'
$taskPreferences = Get-Content -LiteralPath (Join-Path $taskConfigRoot 'shared_preferences.json') -Raw | ConvertFrom-Json
$taskAppConfig = $taskPreferences.'flutter.config' | ConvertFrom-Json
if ($taskAppConfig.overrideDns) { throw '当前启用了 DNS 覆写，请在 FlClash 的覆写 DNS 中追加域名；本脚本仅处理当前配置自己的 DNS。' }
$taskProfileId = [string]$taskAppConfig.currentProfileId
if ($taskProfileId -notmatch '^\d+$') { throw '无法确认当前配置 ID，未修改任何文件。' }
$taskProfileFile = (Resolve-Path -LiteralPath (Join-Path $taskProfileRoot ($taskProfileId + '.yaml'))).Path
if (-not $taskProfileFile.StartsWith($taskProfileRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '当前配置路径不在 profiles 目录内。' }

function Add-MusicDnsFilters([string]$Text) {
    $taskLines = [System.Collections.Generic.List[string]]::new()
    foreach ($taskLine in ($Text -split '\r?\n')) { $taskLines.Add($taskLine) }
    $taskDnsStart = -1
    for ($taskIndex = 0; $taskIndex -lt $taskLines.Count; $taskIndex++) {
        if ($taskLines[$taskIndex] -match '^dns:\s*(#.*)?$') { $taskDnsStart = $taskIndex; break }
    }
    if ($taskDnsStart -lt 0) { throw '未找到可安全编辑的 DNS 配置块，未修改任何文件。' }
    $taskDnsEnd = $taskLines.Count
    for ($taskIndex = $taskDnsStart + 1; $taskIndex -lt $taskLines.Count; $taskIndex++) {
        if ($taskLines[$taskIndex] -match '^\S' -and $taskLines[$taskIndex] -notmatch '^#') { $taskDnsEnd = $taskIndex; break }
    }
    $taskFilterStart = -1
    for ($taskIndex = $taskDnsStart + 1; $taskIndex -lt $taskDnsEnd; $taskIndex++) {
        if ($taskLines[$taskIndex] -match '^\s{2}fake-ip-filter-mode:' -and $taskLines[$taskIndex] -match 'whitelist') { throw '当前使用 whitelist 模式，本脚本不会改变 DNS 规则语义。' }
        if ($taskLines[$taskIndex] -match '^\s{2}fake-ip-filter:') {
            if ($taskLines[$taskIndex] -notmatch '^\s{2}fake-ip-filter:\s*(#.*)?$') { throw '当前排除列表为内联或特殊 YAML 形式，请在客户端中编辑。' }
            $taskFilterStart = $taskIndex
        }
    }
    if ($taskFilterStart -lt 0) { $taskLines.Insert($taskDnsStart + 1, '  fake-ip-filter:'); $taskFilterStart = $taskDnsStart + 1; $taskDnsEnd++ }
    $taskFilterEnd = $taskFilterStart + 1
    while ($taskFilterEnd -lt $taskDnsEnd -and ($taskLines[$taskFilterEnd] -match '^\s{4}' -or $taskLines[$taskFilterEnd] -match '^\s*$')) { $taskFilterEnd++ }
    $taskFilterText = ($taskLines.GetRange($taskFilterStart, $taskFilterEnd - $taskFilterStart) -join "`n")
    foreach ($taskDomain in @('music.126.net', 'music.163.com')) {
        if ($taskFilterText -notmatch [regex]::Escape($taskDomain)) { $taskLines.Insert($taskFilterStart + 1, '    - ''+.' + $taskDomain + '''') }
    }
    $taskNewline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return ($taskLines -join $taskNewline)
}

$taskChanges = @()
foreach ($taskFile in @($taskProfileFile, (Join-Path $taskConfigRoot 'config.yaml'))) {
    $taskOriginal = [System.IO.File]::ReadAllText($taskFile)
    $taskUpdated = Add-MusicDnsFilters $taskOriginal
    if ($taskUpdated -ne $taskOriginal) { $taskChanges += [pscustomobject]@{ Path = $taskFile; Original = $taskOriginal; Updated = $taskUpdated } }
}
$taskJsonFile = Join-Path $taskConfigRoot 'config.json'
$taskOriginalJson = [System.IO.File]::ReadAllText($taskJsonFile)
$taskCoreConfig = $taskOriginalJson | ConvertFrom-Json
if ($taskCoreConfig.dns.'fake-ip-filter-mode' -eq 'whitelist') { throw '运行配置使用 whitelist 模式，未修改任何文件。' }
$taskFilterItems = @($taskCoreConfig.dns.'fake-ip-filter')
foreach ($taskDomain in @('+.music.126.net', '+.music.163.com')) { if ($taskFilterItems -notcontains $taskDomain) { $taskFilterItems += $taskDomain } }
if ($taskFilterItems.Count -ne @($taskCoreConfig.dns.'fake-ip-filter').Count) {
    $taskCoreConfig.dns.'fake-ip-filter' = $taskFilterItems
    $taskChanges += [pscustomobject]@{ Path = $taskJsonFile; Original = $taskOriginalJson; Updated = ($taskCoreConfig | ConvertTo-Json -Depth 100) }
}

Write-Output '仅追加 Fake-IP 排除域名：+.music.126.net、+.music.163.com；保留已有 DNS 模式、节点与规则。'
foreach ($taskChange in $taskChanges) { Write-Output ('将更新：' + $taskChange.Path) }
if (-not $taskChanges.Count) { Write-Output '配置已经包含所需域名，无需修改。'; return }
if (-not $Apply) { Write-Output '预览完成，未写入文件。确认后使用 -Apply 执行，并重新载入 FlClash 配置或重启核心。'; return }

# Check concurrent changes before backing up or touching the current files.
foreach ($taskChange in $taskChanges) {
    if ([System.IO.File]::ReadAllText($taskChange.Path) -ne $taskChange.Original) { throw 'FlClash 配置在预览期间发生变化，未写入；请重新运行。' }
}
$taskBackupSuffix = '.sonora-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$taskBackups = @()
try {
    foreach ($taskChange in $taskChanges) {
        $taskBackup = $taskChange.Path + $taskBackupSuffix
        Copy-Item -LiteralPath $taskChange.Path -Destination $taskBackup
        $taskBackups += [pscustomobject]@{ Path = $taskChange.Path; Backup = $taskBackup }
    }
    foreach ($taskChange in $taskChanges) { [System.IO.File]::WriteAllText($taskChange.Path, $taskChange.Updated, [System.Text.UTF8Encoding]::new($false)) }
} catch {
    foreach ($taskBackup in $taskBackups) { Copy-Item -LiteralPath $taskBackup.Backup -Destination $taskBackup.Path -Force }
    throw
}
Write-Output '修改完成，原文件已备份在同目录（.sonora-backup-*）。请重新载入 FlClash 配置或重启核心，清除旧 DNS 缓存，然后运行 npm run verify:live。'
Write-Output '订阅刷新可能覆盖排除项；如需长期保留，请在 FlClash 的订阅覆写/合并配置中保留同样两条域名。'
