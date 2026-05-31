# DiscoDeblo optimizer - safe, version-aware Discord cleanup for modern Windows Discord.
# Profiles: Safe (default) | Balanced (adds old-version, log, crash dump, and locale cleanup).

param(
    [ValidateSet('Safe', 'Balanced')]
    [string]$Profile = 'Safe',

    [ValidateSet('Stable', 'PTB', 'Canary', 'Development')]
    [string]$Channel = 'Stable',

    [string]$DiscordPath = '',
    [string]$DiscordAppData = '',

    [ValidateSet('en', 'fr', 'both')]
    [string]$Lang = 'en',

    [bool]$DoBackup = $false,

    # Removes Service Worker and CacheStorage too. Off by default because those caches
    # help Discord warm-start faster and are not login storage.
    [switch]$DeepCacheClean,

    # Opens and reads launch-critical files into the OS standby file cache. This is a
    # safe prewarm, not an app.asar patch and not a persistent RAM reservation.
    [switch]$WarmLaunchCache,

    # Backs up and disables non-core Vencord plugins/themes plus BetterDiscord
    # plugin/theme files. This is the only path that should noticeably lower RAM
    # on heavily modded installs.
    [switch]$LeanMods,

    # Restores the most recent Lean Mods backup.
    [switch]$RestoreMods
)

$ErrorActionPreference = 'SilentlyContinue'

# Never remove these from the active install/profile. Deleting updater, app.asar,
# modules, or login/storage surfaces is what breaks modern Discord and client mods.
$script:NEVER_PARTS = @(
    'Packages', 'Update.exe', 'RELEASES', 'modules', 'app.asar', '_app.asar',
    'Cookies', 'Local Storage', 'Web Data', 'Databases', 'Session Storage', 'IndexedDB'
)

$script:DISCORD_CHANNELS = @(
    [pscustomobject]@{ Channel = 'Stable';      Name = 'Discord Stable';      InstallDir = 'Discord';            AppDataDir = 'discord';            ExeName = 'Discord.exe';            Process = 'Discord' },
    [pscustomobject]@{ Channel = 'PTB';         Name = 'Discord PTB';         InstallDir = 'DiscordPTB';         AppDataDir = 'discordptb';         ExeName = 'DiscordPTB.exe';         Process = 'DiscordPTB' },
    [pscustomobject]@{ Channel = 'Canary';      Name = 'Discord Canary';      InstallDir = 'DiscordCanary';      AppDataDir = 'discordcanary';      ExeName = 'DiscordCanary.exe';      Process = 'DiscordCanary' },
    [pscustomobject]@{ Channel = 'Development'; Name = 'Discord Development'; InstallDir = 'DiscordDevelopment'; AppDataDir = 'discorddevelopment'; ExeName = 'DiscordDevelopment.exe'; Process = 'DiscordDevelopment' }
)

$script:VENCORD_LEAN_KEEP = @(
    'BadgeAPI', 'CommandsAPI', 'ContextMenuAPI', 'MemberListDecoratorsAPI',
    'MessageAccessoriesAPI', 'MessageDecorationsAPI', 'MessageEventsAPI',
    'MessagePopoverAPI', 'NoticesAPI', 'ServerListAPI', 'SettingsStoreAPI',
    'ChatInputButtonAPI', 'MessageUpdaterAPI', 'UserSettingsAPI',
    'DynamicImageModalAPI', 'MenuItemDemanglerAPI', 'Settings', 'NoTrack',
    'CrashHandler', 'ConsoleJanitor', 'TokenGuard'
)

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'ERR', 'INFO', 'WARN')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Output "[$Level] $Message"
}

function Format-MB([long]$Bytes) {
    "$([math]::Round($Bytes / 1MB, 2)) MB"
}

function Get-ChannelDefinition([string]$WantedChannel) {
    $script:DISCORD_CHANNELS | Where-Object { $_.Channel -eq $WantedChannel } | Select-Object -First 1
}

function Get-InstallCandidates($Definition) {
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA $Definition.InstallDir) }
    if ($env:PROGRAMDATA -and $env:USERNAME) {
        $candidates += (Join-Path (Join-Path $env:PROGRAMDATA $env:USERNAME) $Definition.InstallDir)
    }
    $candidates | Where-Object { $_ } | Select-Object -Unique
}

function Resolve-DefaultInstallPath($Definition) {
    foreach ($candidate in (Get-InstallCandidates $Definition)) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA $Definition.InstallDir) }
    return $Definition.InstallDir
}

function Get-FolderSize($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -EA SilentlyContinue |
            Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
        if ($null -eq $sum) { return 0L }
        return [long]$sum
    } catch {
        return 0L
    }
}

function Get-HighestAppDir([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $best = $null
    $bestVersion = [version]'0.0.0'
    Get-ChildItem -LiteralPath $Root -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -like 'app-*' } |
        ForEach-Object {
            try {
                $version = [version]($_.Name.Substring(4))
                if ($null -eq $best -or $version -gt $bestVersion) {
                    $bestVersion = $version
                    $best = $_
                }
            } catch {}
        }
    if ($null -eq $best) { return $null }
    [pscustomobject]@{ Path = $best.FullName; Version = $bestVersion }
}

function Test-ProtectedPath([string]$Path) {
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -EA Stop).ProviderPath
    } catch {
        $resolved = $Path
    }
    $parts = $resolved -split '[\\/]'
    foreach ($part in $parts) {
        if ($script:NEVER_PARTS -contains $part) { return $true }
        if ($part -like 'Discord_updater*') { return $true }
    }
    return $false
}

function Safe-Remove($Path, [ref]$BytesRef) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (Test-ProtectedPath $Path) {
        Write-Log -Level WARN -Message "Blocked unsafe path: $Path"
        return $false
    }

    $size = Get-FolderSize $Path
    Remove-Item -LiteralPath $Path -Recurse -Force -EA SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) {
        $BytesRef.Value += $size
        return $true
    }

    Write-Log -Level WARN -Message "Could not remove: $Path"
    return $false
}

function Remove-CachePath($Path, [ref]$BytesRef) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $size = Get-FolderSize $Path
    Remove-Item -LiteralPath $Path -Recurse -Force -EA SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) {
        $BytesRef.Value += $size
        return $true
    }
    Write-Log -Level WARN -Message "Could not clear cache path: $Path"
    return $false
}

function Read-FileHeadText([string]$Path, [int]$MaxBytes = 8192) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = [int][math]::Min($MaxBytes, $stream.Length)
        if ($length -le 0) { return '' }
        $buffer = New-Object byte[] $length
        [void]$stream.Read($buffer, 0, $length)
        return [System.Text.Encoding]::UTF8.GetString($buffer)
    } catch {
        return ''
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Add-UniqueSignal([System.Collections.ArrayList]$Signals, [string]$Signal) {
    if ($Signal -and -not $Signals.Contains($Signal)) { [void]$Signals.Add($Signal) }
}

function Get-ClientModSignals($Definition, [string]$Root, [string]$ActiveDir, [string]$AppDataRoot) {
    $signals = New-Object System.Collections.ArrayList

    $vencordRoot = Join-Path $env:APPDATA 'Vencord'
    $vencordDataRoot = Join-Path $env:APPDATA 'VencordData'
    $betterDiscordRoot = Join-Path $env:APPDATA 'BetterDiscord'
    $openAsarRoot = Join-Path $env:APPDATA 'OpenAsar'

    if (Test-Path -LiteralPath $vencordRoot) {
        Add-UniqueSignal $signals 'Vencord data folder present'
        $patcher = Join-Path $vencordRoot 'dist\patcher.js'
        if (Test-Path -LiteralPath $patcher) { Add-UniqueSignal $signals 'Vencord patcher available' }
    }
    if (Test-Path -LiteralPath $vencordDataRoot) { Add-UniqueSignal $signals 'VencordData folder present' }

    if (Test-Path -LiteralPath $betterDiscordRoot) {
        Add-UniqueSignal $signals 'BetterDiscord data folder present'
        $plugins = Join-Path $betterDiscordRoot 'plugins'
        if (Test-Path -LiteralPath $plugins) {
            $pluginCount = @(Get-ChildItem -LiteralPath $plugins -Filter '*.plugin.js' -File -EA SilentlyContinue).Count
            Add-UniqueSignal $signals "BetterDiscord plugins found: $pluginCount"
        }
    }
    if (Test-Path -LiteralPath $openAsarRoot) { Add-UniqueSignal $signals 'OpenAsar data folder present' }

    if ($ActiveDir) {
        $resources = Join-Path $ActiveDir 'resources'
        $appAsar = Join-Path $resources 'app.asar'
        $backupAsar = Join-Path $resources '_app.asar'
        $appDir = Join-Path $resources 'app'

        if (Test-Path -LiteralPath $backupAsar) {
            Add-UniqueSignal $signals 'app.asar patch backup (_app.asar) present'
        }

        $head = Read-FileHeadText $appAsar 8192
        if ($head -match 'Vencord') { Add-UniqueSignal $signals 'Vencord app.asar patch detected' }
        if ($head -match 'BetterDiscord|betterdiscord') { Add-UniqueSignal $signals 'BetterDiscord app.asar patch detected' }
        if ($head -match 'OpenAsar|openasar') { Add-UniqueSignal $signals 'OpenAsar app.asar replacement detected' }

        if (Test-Path -LiteralPath (Join-Path $appDir 'betterdiscord.asar')) {
            Add-UniqueSignal $signals 'BetterDiscord resources app folder detected'
        }
        if (Test-Path -LiteralPath (Join-Path $appDir 'injector.js')) {
            Add-UniqueSignal $signals 'Discord injector resources app folder detected'
        }
    }

    return @($signals)
}

function Get-AltClientSignals {
    $checks = @(
        [pscustomobject]@{ Name = 'Vesktop'; Paths = @((Join-Path $env:APPDATA 'vesktop'), (Join-Path $env:LOCALAPPDATA 'Vesktop'), (Join-Path $env:LOCALAPPDATA 'Programs\Vesktop')) },
        [pscustomobject]@{ Name = 'ArmCord'; Paths = @((Join-Path $env:APPDATA 'ArmCord'), (Join-Path $env:LOCALAPPDATA 'ArmCord')) },
        [pscustomobject]@{ Name = 'Equibop'; Paths = @((Join-Path $env:APPDATA 'Equibop'), (Join-Path $env:LOCALAPPDATA 'Equibop')) },
        [pscustomobject]@{ Name = 'Legcord'; Paths = @((Join-Path $env:APPDATA 'Legcord'), (Join-Path $env:LOCALAPPDATA 'Legcord')) }
    )

    foreach ($check in $checks) {
        foreach ($path in ($check.Paths | Where-Object { $_ })) {
            if (Test-Path -LiteralPath $path) {
                [pscustomobject]@{ Name = $check.Name; Path = $path }
                break
            }
        }
    }
}

function Get-VencordRuntimeSummary {
    $settingsPath = Join-Path $env:APPDATA 'Vencord\settings\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return @() }

    $messages = New-Object System.Collections.ArrayList
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $enabledPlugins = @()
        if ($settings.plugins) {
            $settings.plugins.PSObject.Properties | ForEach-Object {
                if ($_.Value.enabled -eq $true) { $enabledPlugins += $_.Name }
            }
        }
        [void]$messages.Add("Vencord enabled plugins: $($enabledPlugins.Count)")
        if ($enabledPlugins.Count -ge 50) {
            [void]$messages.Add('Vencord has a high enabled-plugin count; disabling unused visual/RPC/media plugins is the safest next RAM/startup win')
        }
        if ($settings.enableReactDevtools -eq $true) {
            [void]$messages.Add('Vencord React DevTools is enabled; turn it off outside debugging')
        }
        if ($settings.eagerPatches -eq $true) {
            [void]$messages.Add('Vencord eagerPatches is enabled; leaving it off usually starts faster')
        }
        if ($settings.enabledThemes) {
            [void]$messages.Add("Vencord enabled themes: $(@($settings.enabledThemes).Count)")
        }
    } catch {
        [void]$messages.Add('Could not parse Vencord settings for runtime audit')
    }
    return @($messages)
}

function Get-BetterDiscordRuntimeSummary {
    $root = Join-Path $env:APPDATA 'BetterDiscord'
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $messages = New-Object System.Collections.ArrayList
    $pluginsDir = Join-Path $root 'plugins'
    $themesDir = Join-Path $root 'themes'

    $plugins = @()
    if (Test-Path -LiteralPath $pluginsDir) {
        $plugins = @(Get-ChildItem -LiteralPath $pluginsDir -Filter '*.plugin.js' -File -EA SilentlyContinue)
    }
    $themes = @()
    if (Test-Path -LiteralPath $themesDir) {
        $themes = @(Get-ChildItem -LiteralPath $themesDir -Filter '*.theme.css' -File -EA SilentlyContinue)
    }

    if ($plugins.Count -gt 0) {
        $totalBytes = [long](($plugins | Measure-Object -Property Length -Sum).Sum)
        [void]$messages.Add("BetterDiscord plugins: $($plugins.Count) ($(Format-MB $totalBytes) on disk)")
        $largest = @($plugins | Sort-Object Length -Descending | Select-Object -First 3 | ForEach-Object { $_.Name })
        if ($largest.Count -gt 0) {
            [void]$messages.Add("Largest BetterDiscord plugin files: $($largest -join ', ')")
        }
        $stale = @($plugins | Where-Object { $_.LastWriteTime -lt (Get-Date).AddYears(-1) })
        if ($stale.Count -gt 0) {
            [void]$messages.Add("BetterDiscord stale plugin files (>1 year): $($stale.Count); update or disable unused plugins for better stability")
        }
    }
    if ($themes.Count -gt 0) {
        [void]$messages.Add("BetterDiscord themes: $($themes.Count)")
    }

    return @($messages)
}

function Write-ModRuntimeAudit {
    $messages = @()
    $messages += Get-VencordRuntimeSummary
    $messages += Get-BetterDiscordRuntimeSummary
    foreach ($message in $messages) {
        if ($message -like '*high enabled-plugin*' -or $message -like '*DevTools*' -or $message -like '*eagerPatches*' -or $message -like '*stale plugin*') {
            Write-Log -Level WARN -Message $message
        } else {
            Write-Log -Level INFO -Message $message
        }
    }
}

function Get-ModBackupRoot {
    $root = Join-Path $env:APPDATA 'DiscordDebloatTool\mod-backups'
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -Path $root -ItemType Directory -Force | Out-Null
    }
    return $root
}

function New-ModBackupDir {
    $root = Get-ModBackupRoot
    $dir = Join-Path $root (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    return $dir
}

function Get-LatestModBackupDir {
    $root = Get-ModBackupRoot
    Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function Set-PropertyValue($Object, [string]$Name, $Value) {
    if ($null -eq $Object) { return }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Apply-LeanVencord([string]$BackupDir, [ref]$ChangedRef) {
    $settingsPath = Join-Path $env:APPDATA 'Vencord\settings\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Write-Log -Level INFO -Message 'Lean Mods: Vencord settings not found'
        return
    }

    $backupPath = Join-Path $BackupDir 'vencord-settings.json'
    Copy-Item -LiteralPath $settingsPath -Destination $backupPath -Force

    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } catch {
        Write-Log -Level WARN -Message 'Lean Mods: could not parse Vencord settings'
        return
    }

    $disabled = 0
    $settingChanges = 0
    if ($settings.plugins) {
        $settings.plugins.PSObject.Properties | ForEach-Object {
            $pluginName = $_.Name
            $pluginSettings = $_.Value
            if ($pluginSettings.enabled -eq $true -and ($script:VENCORD_LEAN_KEEP -notcontains $pluginName)) {
                Set-PropertyValue $pluginSettings 'enabled' $false
                $disabled++
            }
        }
    }

    if ($settings.useQuickCss -eq $true) { $settingChanges++ }
    Set-PropertyValue $settings 'useQuickCss' $false
    if ($settings.enableReactDevtools -eq $true) { $settingChanges++ }
    Set-PropertyValue $settings 'enableReactDevtools' $false
    if ($settings.eagerPatches -eq $true) { $settingChanges++ }
    Set-PropertyValue $settings 'eagerPatches' $false
    if ($settings.themeLinks -and @($settings.themeLinks).Count -gt 0) { $settingChanges++ }
    Set-PropertyValue $settings 'themeLinks' @()
    if ($settings.enabledThemes -and @($settings.enabledThemes).Count -gt 0) { $settingChanges++ }
    Set-PropertyValue $settings 'enabledThemes' @()
    if ($settings.cloud -and $settings.cloud.settingsSync -eq $true) {
        Set-PropertyValue $settings.cloud 'settingsSync' $false
        $settingChanges++
        Write-Log -Level WARN -Message 'Lean Mods: disabled Vencord cloud settings sync so lean settings do not immediately revert'
    }

    $settings | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $settingsPath -Encoding UTF8 -Force
    Write-Log -Level OK -Message "Lean Mods: disabled $disabled Vencord plugin(s), themes, QuickCSS, React DevTools"
    Write-Log -Level INFO -Message "Lean Mods: Vencord backup saved: $backupPath"
    $ChangedRef.Value += ($disabled + $settingChanges)
}

function Disable-BetterDiscordFiles([string]$BackupDir, [ref]$ChangedRef) {
    $root = Join-Path $env:APPDATA 'BetterDiscord'
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Log -Level INFO -Message 'Lean Mods: BetterDiscord folder not found'
        return
    }

    $manifest = New-Object System.Collections.ArrayList
    $count = 0
    foreach ($kind in @('plugins', 'themes')) {
        $dir = Join-Path $root $kind
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $pattern = if ($kind -eq 'plugins') { '*.plugin.js' } else { '*.theme.css' }
        $backupKind = Join-Path $BackupDir "BetterDiscord-$kind"
        New-Item -Path $backupKind -ItemType Directory -Force | Out-Null

        Get-ChildItem -LiteralPath $dir -Filter $pattern -File -EA SilentlyContinue | ForEach-Object {
            $disabledPath = "$($_.FullName).disabled"
            if (-not (Test-Path -LiteralPath $disabledPath)) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $backupKind $_.Name) -Force
                Rename-Item -LiteralPath $_.FullName -NewName "$($_.Name).disabled" -Force
                [void]$manifest.Add([pscustomobject]@{
                    Kind = $kind
                    Original = $_.FullName
                    Disabled = $disabledPath
                    Backup = (Join-Path $backupKind $_.Name)
                })
                $count++
            }
        }
    }

    $manifestPath = Join-Path $BackupDir 'betterdiscord-disabled.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Force
    if ($count -gt 0) {
        Write-Log -Level OK -Message "Lean Mods: disabled $count BetterDiscord plugin/theme file(s)"
        Write-Log -Level INFO -Message "Lean Mods: BetterDiscord manifest saved: $manifestPath"
    } else {
        Write-Log -Level INFO -Message 'Lean Mods: no active BetterDiscord plugin/theme files to disable'
    }
    $ChangedRef.Value += $count
}

function Apply-LeanMods {
    $backupDir = New-ModBackupDir
    Write-Log -Level INFO -Message "Lean Mods: backup folder: $backupDir"
    $changed = [ref]0
    Apply-LeanVencord $backupDir $changed
    Disable-BetterDiscordFiles $backupDir $changed
    Write-Log -Level OK -Message "Lean Mods: $($changed.Value) mod item(s) changed. Restart Discord to measure RAM again."
}

function Restore-LeanMods {
    $backup = Get-LatestModBackupDir
    if (-not $backup) {
        Write-Log -Level WARN -Message 'Restore Mods: no Lean Mods backup found'
        return 1
    }

    Write-Log -Level INFO -Message "Restore Mods: using backup $($backup.FullName)"
    $restored = 0

    $vencordBackup = Join-Path $backup.FullName 'vencord-settings.json'
    $vencordSettings = Join-Path $env:APPDATA 'Vencord\settings\settings.json'
    if (Test-Path -LiteralPath $vencordBackup) {
        $vencordDir = Split-Path $vencordSettings -Parent
        if (-not (Test-Path -LiteralPath $vencordDir)) {
            New-Item -Path $vencordDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $vencordBackup -Destination $vencordSettings -Force
        Write-Log -Level OK -Message 'Restore Mods: Vencord settings restored'
        $restored++
    }

    $manifestPath = Join-Path $backup.FullName 'betterdiscord-disabled.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $entries = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
            foreach ($entry in $entries) {
                if ((Test-Path -LiteralPath $entry.Disabled) -and -not (Test-Path -LiteralPath $entry.Original)) {
                    Rename-Item -LiteralPath $entry.Disabled -NewName (Split-Path $entry.Original -Leaf) -Force
                    $restored++
                } elseif ((Test-Path -LiteralPath $entry.Backup) -and -not (Test-Path -LiteralPath $entry.Original)) {
                    Copy-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force
                    $restored++
                }
            }
            Write-Log -Level OK -Message 'Restore Mods: BetterDiscord plugin/theme files restored'
        } catch {
            Write-Log -Level WARN -Message 'Restore Mods: could not process BetterDiscord manifest'
        }
    }

    Write-Log -Level OK -Message "Restore Mods: $restored item(s) restored. Restart Discord."
    return 0
}

function Write-CompatibilityScan {
    Write-Log -Level INFO -Message 'Compatibility scan: Discord channels and client mods...'
    $foundAny = $false
    foreach ($definition in $script:DISCORD_CHANNELS) {
        foreach ($candidate in (Get-InstallCandidates $definition)) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            $foundAny = $true
            $active = Get-HighestAppDir $candidate
            if ($null -eq $active) {
                Write-Log -Level WARN -Message "$($definition.Name) found without app-* folder: $candidate"
                continue
            }
            $appDataRoot = Join-Path $env:APPDATA $definition.AppDataDir
            Write-Log -Level OK -Message "$($definition.Name): v$($active.Version) at $candidate"
            $signals = @(Get-ClientModSignals $definition $candidate $active.Path $appDataRoot)
            if ($signals.Count -gt 0) {
                Write-Log -Level WARN -Message "$($definition.Name) mod signals: $($signals -join '; ')"
            }
        }
    }

    foreach ($alt in (Get-AltClientSignals)) {
        $foundAny = $true
        Write-Log -Level WARN -Message "$($alt.Name) detected at $($alt.Path) - not modified by this optimizer"
    }

    if (-not $foundAny) {
        Write-Log -Level WARN -Message 'No Discord desktop installs found during compatibility scan'
    }
}

function Stop-DiscordProcesses([string]$Root, [string]$ProcessName) {
    $closed = 0
    $procs = @()
    if (Test-Path -LiteralPath $Root) {
        $procs += Get-Process -EA SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -like "$Root*") } catch { $false }
        }
    }
    if (-not $procs -and $ProcessName) {
        $procs = Get-Process -Name $ProcessName -EA SilentlyContinue
    }
    if ($procs) {
        $ids = @($procs | Select-Object -ExpandProperty Id -Unique)
        $procs | Stop-Process -Force -EA SilentlyContinue
        $closed = $ids.Count
    }
    if ($ProcessName) {
        $null = & taskkill.exe /IM "$ProcessName.exe" /F /T 2>$null
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $deadline) {
            if (-not (Get-Process -Name $ProcessName -EA SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 350
        }
    }
    return $closed
}

function Test-DiscordNewUpdater {
    param([System.Version]$Version, [string]$Root, [string]$AppDataRoot)
    if ($Version -ge [System.Version]'1.0.9000') { return $true }
    if (Test-Path -LiteralPath (Join-Path $Root 'Discord_updater.exe')) { return $true }
    $moduleData = Join-Path $AppDataRoot 'module_data'
    if (Test-Path -LiteralPath $moduleData) {
        if (Get-ChildItem -LiteralPath $moduleData -Directory -EA SilentlyContinue | Where-Object { $_.Name -like '*updater*' }) {
            return $true
        }
    }
    return $false
}

function Get-LocaleKeepList([string]$Language) {
    switch ($Language) {
        'fr' { @('en-US.pak', 'en-GB.pak', 'fr.pak') }
        'both' { @('en-US.pak', 'en-GB.pak', 'fr.pak') }
        default { @('en-US.pak', 'en-GB.pak') }
    }
}

function Test-DiscordHealth {
    param(
        [string]$Root,
        [string]$ActiveDir,
        [System.Version]$Version,
        [string]$ExeName,
        [string]$AppDataRoot
    )
    $issues = @()
    if (-not (Test-Path -LiteralPath $Root)) { $issues += 'Discord install folder missing' }
    if (-not $ActiveDir -or -not (Test-Path -LiteralPath $ActiveDir)) { $issues += 'Active app folder missing' }
    elseif (-not (Test-Path -LiteralPath (Join-Path $ActiveDir $ExeName))) { $issues += "$ExeName missing in active app folder" }

    if ($ActiveDir) {
        $resources = Join-Path $ActiveDir 'resources'
        if (-not (Test-Path -LiteralPath $resources)) { $issues += 'resources folder missing' }
        elseif (-not (Test-Path -LiteralPath (Join-Path $resources 'app.asar')) -and -not (Test-Path -LiteralPath (Join-Path $resources 'app'))) {
            $issues += 'resources app entry missing'
        }
    }

    if (Test-DiscordNewUpdater -Version $Version -Root $Root -AppDataRoot $AppDataRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root 'Packages'))) {
            $issues += 'Packages folder missing (updater may fail - run repair_discord.bat)'
        }
    }
    return $issues
}

function Merge-DiscordSettings([string]$SettingsPath) {
    $existing = @{}
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $parsed = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            $parsed.PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value }
        } catch {
            Write-Log -Level WARN -Message 'Could not parse settings.json; rewriting known optimization keys only'
        }
    }

    $perf = [ordered]@{
        # Keep Discord updating. These were previously set true by older debloat tools.
        SKIP_HOST_UPDATE           = $false
        SKIP_MODULE_UPDATE         = $false
        enableHardwareAcceleration = $false
        OPEN_ON_STARTUP            = $false
        START_MINIMIZED            = $false
        MINIMIZE_TO_TRAY           = $false
        CLOSE_TO_TRAY              = $false
        debugLogging               = $false
    }

    foreach ($key in $perf.Keys) { $existing[$key] = $perf[$key] }
    ($existing | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $SettingsPath -Encoding UTF8 -Force
}

function Warm-LaunchAssets([string]$ActiveDir, [string]$AppDataRoot, [string]$ExeName) {
    $paths = @(
        (Join-Path $ActiveDir $ExeName),
        (Join-Path $ActiveDir 'resources\app.asar'),
        (Join-Path $ActiveDir 'resources\_app.asar'),
        (Join-Path $AppDataRoot 'settings.json')
    )
    $warmed = 0
    foreach ($path in ($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $bufferSize = [int][math]::Min(4MB, [math]::Max(4096, $stream.Length))
            $buffer = New-Object byte[] $bufferSize
            [void]$stream.Read($buffer, 0, $buffer.Length)
            $warmed++
        } catch {
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    Write-Log -Level OK -Message "Launch prewarm touched $warmed file(s)"
}

# --- Resolve target ---
$target = Get-ChannelDefinition $Channel
if (-not $DiscordPath) { $DiscordPath = Resolve-DefaultInstallPath $target }
if (-not $DiscordAppData) { $DiscordAppData = Join-Path $env:APPDATA $target.AppDataDir }

# --- Preflight ---
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$totalBytes = [ref]0L
$totalFiles = 0
$errorCount = 0

Write-Log -Level INFO -Message "Profile: $Profile | Target: $($target.Name) | Path: $DiscordPath"
Write-CompatibilityScan
Write-ModRuntimeAudit

if ($RestoreMods) {
    Write-Log -Level INFO -Message 'Restore Mods requested: closing Discord processes before restore...'
    Get-Process -EA SilentlyContinue |
        Where-Object { $_.ProcessName -like 'Discord*' } |
        Stop-Process -Force -EA SilentlyContinue
    $restoreCode = Restore-LeanMods
    exit $restoreCode
}

if (-not (Test-Path -LiteralPath $DiscordPath)) {
    Write-Log -Level ERR -Message "$($target.Name) not installed at $DiscordPath. Run repair_discord.bat for Stable or choose another -Channel."
    exit 1
}

$active = Get-HighestAppDir $DiscordPath
if ($null -eq $active) {
    Write-Log -Level ERR -Message "No app-* folder found in $DiscordPath. Run repair_discord.bat."
    exit 1
}

$activeDir = $active.Path
$highest = $active.Version
$newUpdater = Test-DiscordNewUpdater -Version $highest -Root $DiscordPath -AppDataRoot $DiscordAppData
$targetSignals = @(Get-ClientModSignals $target $DiscordPath $activeDir $DiscordAppData)

Write-Log -Level OK -Message "Active target: $($target.Name) v$highest | newUpdater=$newUpdater"
Write-Log -Level INFO -Message 'Protected: updater, app.asar, modules, shortcuts, login storage, mod folders.'
if ($targetSignals.Count -gt 0) {
    Write-Log -Level WARN -Message "Active target mod-aware mode: $($targetSignals -join '; ')"
}

$preIssues = Test-DiscordHealth -Root $DiscordPath -ActiveDir $activeDir -Version $highest -ExeName $target.ExeName -AppDataRoot $DiscordAppData
foreach ($issue in $preIssues) { Write-Log -Level WARN -Message "Preflight: $issue" }

$closedCount = Stop-DiscordProcesses -Root $DiscordPath -ProcessName $target.Process
if ($closedCount -gt 0) { Write-Log -Level OK -Message "$closedCount $($target.Name) process(es) closed" }

if ($LeanMods) {
    Apply-LeanMods
}

if ($DoBackup) {
    $safeName = $target.InstallDir -replace '[^A-Za-z0-9_.-]', '_'
    $backupPath = "$([Environment]::GetFolderPath('Desktop'))\${safeName}_Backup_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    try {
        Copy-Item -LiteralPath $DiscordPath -Destination $backupPath -Recurse -Force -EA Stop
        Write-Log -Level OK -Message "Backup saved: $backupPath"
    } catch {
        Write-Log -Level ERR -Message "Backup failed: $($_.Exception.Message)"
        $errorCount++
    }
}

# --- Tier 0: AppData cache (safe; login kept) ---
Write-Log -Level INFO -Message 'Tier 0: Clearing volatile Electron cache (not Cookies / Local Storage / Web Data)...'
$cacheDirs = @(
    'Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache',
    'VideoDecodeStats', 'logs', 'Crashpad', 'debug', 'sentry',
    'blob_storage', 'component_crx_cache', 'DawnCache',
    'DawnGraphiteCache', 'DawnWebGPUCache', 'Shared Dictionary',
    'shared_proto_db'
)
if ($DeepCacheClean) {
    $cacheDirs += @('CacheStorage', 'Service Worker')
    Write-Log -Level WARN -Message 'DeepCacheClean enabled: Service Worker and CacheStorage will be rebuilt on next launch'
} else {
    Write-Log -Level INFO -Message 'Preserving Service Worker and CacheStorage for faster warm starts'
}

if (Test-Path -LiteralPath $DiscordAppData) {
    foreach ($folder in $cacheDirs) {
        $path = Join-Path $DiscordAppData $folder
        if (Remove-CachePath $path $totalBytes) { $totalFiles++ }
    }
    Write-Log -Level OK -Message 'AppData volatile cache cleared'
} else {
    Write-Log -Level WARN -Message "AppData not found: $DiscordAppData"
}

# --- Tier 0: Performance settings (merge, do not wipe) ---
Write-Log -Level INFO -Message 'Tier 0: Merging performance settings.json...'
if (-not (Test-Path -LiteralPath $DiscordAppData)) {
    New-Item -Path $DiscordAppData -ItemType Directory -Force | Out-Null
}
$settingsPath = Join-Path $DiscordAppData 'settings.json'
try {
    Merge-DiscordSettings $settingsPath
    Write-Log -Level OK -Message 'settings.json merged (updates enabled, startup/tray/debug disabled)'
    $totalFiles++
} catch {
    Write-Log -Level ERR -Message "settings.json failed: $($_.Exception.Message)"
    $errorCount++
}

# --- Tier 0: FSO (Windows compatibility flag, safe) ---
$exePath = Join-Path $activeDir $target.ExeName
if (Test-Path -LiteralPath $exePath) {
    $fsoRoot = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (-not (Test-Path $fsoRoot)) { New-Item -Path $fsoRoot -Force | Out-Null }
    try {
        Set-ItemProperty -Path $fsoRoot -Name $exePath -Value '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' -Force -EA Stop
        Write-Log -Level OK -Message 'Fullscreen optimizations flag set'
    } catch {
        Write-Log -Level WARN -Message 'Could not set fullscreen optimizations flag'
        $errorCount++
    }
}

# --- Balanced-only (still safe on modern builds) ---
if ($Profile -eq 'Balanced') {
    Write-Log -Level INFO -Message 'Balanced: extra cleanup...'

    $allApps = @(Get-ChildItem -LiteralPath $DiscordPath -Directory -EA SilentlyContinue | Where-Object { $_.Name -like 'app-*' })
    if ($allApps.Count -gt 1) {
        $removed = 0
        foreach ($dir in ($allApps | Where-Object { $_.FullName -ne $activeDir })) {
            if (Safe-Remove $dir.FullName $totalBytes) { $removed++ }
        }
        Write-Log -Level OK -Message "Old app folders removed: $removed"
    } else {
        Write-Log -Level INFO -Message 'Single app folder - skipping old version removal'
    }

    $logPatterns = @((Join-Path $activeDir '*.log'), (Join-Path $DiscordPath '*.log'))
    foreach ($pattern in $logPatterns) {
        $before = Get-FolderSize (Split-Path $pattern -Parent)
        Remove-Item -Path $pattern -Force -EA SilentlyContinue
        $after = Get-FolderSize (Split-Path $pattern -Parent)
        if ($before -gt $after) { $totalBytes.Value += ($before - $after) }
    }

    $crashpad = Join-Path $DiscordAppData 'module_data\crashpad'
    if (Test-Path -LiteralPath $crashpad) {
        $size = Get-FolderSize $crashpad
        Remove-Item -LiteralPath $crashpad -Recurse -Force -EA SilentlyContinue
        if (-not (Test-Path -LiteralPath $crashpad)) {
            $totalBytes.Value += $size
            Write-Log -Level OK -Message "module_data\crashpad cleared ($(Format-MB $size))"
            $totalFiles++
        }
    }

    $localePath = Join-Path $activeDir 'locales'
    if (Test-Path -LiteralPath $localePath) {
        $keep = Get-LocaleKeepList $Lang
        $removedLocales = 0
        $beforeLocales = Get-FolderSize $localePath
        Get-ChildItem -LiteralPath $localePath -Filter '*.pak' -File -EA SilentlyContinue |
            Where-Object { $keep -notcontains $_.Name } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue
                $removedLocales++
            }
        $freedLocales = Format-MB ($beforeLocales - (Get-FolderSize $localePath))
        Write-Log -Level OK -Message "Locales: $removedLocales removed | kept $($keep -join ', ') | $freedLocales freed"
        $totalFiles += $removedLocales
    }
} else {
    Write-Log -Level INFO -Message 'Safe profile: skipping locales, old app folders, and crashpad dumps'
}

if ($WarmLaunchCache) {
    Write-Log -Level INFO -Message 'Prewarming Discord launch files...'
    Warm-LaunchAssets -ActiveDir $activeDir -AppDataRoot $DiscordAppData -ExeName $target.ExeName
}

# --- Postflight ---
$postIssues = Test-DiscordHealth -Root $DiscordPath -ActiveDir $activeDir -Version $highest -ExeName $target.ExeName -AppDataRoot $DiscordAppData
if ($postIssues.Count -eq 0) {
    Write-Log -Level OK -Message 'Postflight: install structure looks healthy'
} else {
    foreach ($issue in $postIssues) { Write-Log -Level WARN -Message "Postflight: $issue" }
}

$sw.Stop()
Write-Log -Level OK -Message "Done in $([int]$sw.Elapsed.TotalSeconds)s - $totalFiles changes, $(Format-MB $totalBytes.Value) freed, $errorCount error(s)."
Write-Log -Level OK -Message 'Open Discord from Start menu or Desktop (same shortcut as before).'
exit $(if ($postIssues.Count -gt 0 -and $errorCount -gt 0) { 1 } else { 0 })
