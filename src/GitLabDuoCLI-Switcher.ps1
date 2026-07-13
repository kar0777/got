[CmdletBinding()]
param(
    [ValidateSet("Hub", "AddProfile", "Repair", "Doctor", "Shortcut")]
    [string]$Action = "Hub",
    [string]$ProfileName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AppName = "GitLab Duo CLI Switcher"
$AppVersion = "8.3.2"
$Root = Join-Path $env:LOCALAPPDATA "GitLabDuoCLISwitcher"
$ProfilesRoot = Join-Path $Root "profiles"
$CacheRoot = Join-Path $Root "usage-cache"
$SnapshotsRoot = Join-Path $Root "checkpoints"
$ProjectStateRoot = Join-Path $Root "project-state"
$ConfigPath = Join-Path $Root "profiles.json"
$ThisScript = $MyInvocation.MyCommand.Path
$DistributionRoot = Split-Path $ThisScript -Parent
$RecorderSourcePath = Join-Path $DistributionRoot "DuoTerminalRecorder.cs"
$RecorderBinRoot = Join-Path $Root "bin"
$RecorderExePath = Join-Path $RecorderBinRoot "DuoTerminalRecorder.exe"
$RecorderHashPath = Join-Path $RecorderBinRoot "DuoTerminalRecorder.sha256"
$RecorderBuildLogPath = Join-Path $RecorderBinRoot "DuoTerminalRecorder-build.log"
$RecorderRuntimeMarkerPath = Join-Path $RecorderBinRoot "DuoTerminalRecorder.runtime-ok"
$MinimumGlabVersion = [version]"1.107.0"
$DefaultModel = "gpt_5_6_sol"
$ContextSoftLimitCharacters = 100000
$ContextHardLimitCharacters = 300000
$ContextCompressionMinimumCharacters = 2500
$ContextCompressionMinimumRatio = 0.15
$ContextCompressionBackupCount = 10
$script:LastSessionResult = $null

function Write-Rule {
    param([string]$Char = "─")
    $width = 78
    try {
        $width = [Math]::Max(50, [Math]::Min(110, $Host.UI.RawUI.WindowSize.Width - 2))
    }
    catch {}
    Write-Host ($Char * $width) -ForegroundColor DarkGray
}

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Rule
    Write-Host ("  {0}" -f $Text) -ForegroundColor Cyan
    Write-Rule
}

function Pause-Brief {
    Write-Host ""
    [void](Read-Host "Enter — продолжить")
}

function Test-ObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    # Do not use `$Object.PSObject.Properties.Name` here. In Windows
    # PowerShell 5.1 member enumeration throws in StrictMode when the
    # collection is empty (for example, a newly created hooks.json object).
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Initialize-App {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    New-Item -ItemType Directory -Force -Path $ProfilesRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $SnapshotsRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $ProjectStateRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $RecorderBinRoot | Out-Null

    if (-not (Test-Path $ConfigPath)) {
        [ordered]@{
            version = 12
            activeProjectId = ""
            settings = [ordered]@{
                autoApproveTools = $false
                localRecorderEnabled = $true
                recorderRawDiagnostics = $false
            }
            projects = @()
            profiles = @()
        } | ConvertTo-Json -Depth 30 | Set-Content -Path $ConfigPath -Encoding UTF8
    }

    Repair-AllProfilePermissions -Quiet
    Remove-LegacyProfileShortcuts
    [void](Get-AppConfig)
}

function Save-AppConfig {
    param($Config)

    if (Test-ObjectProperty -Object $Config -Name "version") {
        $Config.version = 12
    }
    else {
        $Config | Add-Member -MemberType NoteProperty -Name version -Value 12
    }
    $json = $Config | ConvertTo-Json -Depth 40
    $mutex = New-Object Threading.Mutex($false, "Local\GitLabDuoSwitcher-Config")
    $acquired = $false
    $temporaryPath = "$ConfigPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$ConfigPath.bak"

    try {
        $acquired = $mutex.WaitOne(10000)
        if (-not $acquired) {
            throw "Не удалось получить блокировку конфигурации за 10 секунд."
        }

        $json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        [void](Get-Content -LiteralPath $temporaryPath -Raw -Encoding UTF8 | ConvertFrom-Json)

        if (Test-Path -LiteralPath $ConfigPath) {
            Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        }

        Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
    }
}

function New-DefaultAppConfig {
    return [pscustomobject][ordered]@{
        version = 12
        activeProjectId = ""
        settings = [pscustomobject]@{
            autoApproveTools = $false
            localRecorderEnabled = $true
            recorderRawDiagnostics = $false
        }
        projects = @()
        profiles = @()
    }
}

function Read-AppConfigObject {
    param([string]$Path)

    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        $null -eq $value -or
        -not ($value -is [System.Management.Automation.PSCustomObject])
    ) {
        throw "Корень profiles.json должен быть JSON-объектом."
    }

    return $value
}

function Get-AppConfig {
    $configWasRecovered = $false

    try {
        $config = Read-AppConfigObject -Path $ConfigPath
    }
    catch {
        $backupPath = "$ConfigPath.bak"

        if (Test-Path -LiteralPath $backupPath) {
            try {
                $config = Read-AppConfigObject -Path $backupPath
                Copy-Item -LiteralPath $backupPath -Destination $ConfigPath -Force
                Write-Warning "profiles.json повреждён. Восстановлена резервная копия."
                $configWasRecovered = $true
            }
            catch {
                $config = $null
            }
        }

        if (-not $configWasRecovered) {
            $invalidBackup = "$ConfigPath.invalid-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            if (Test-Path -LiteralPath $ConfigPath) {
                try {
                    Copy-Item -LiteralPath $ConfigPath -Destination $invalidBackup -Force
                }
                catch {}
            }

            Write-Warning "profiles.json повреждён. Создан backup и восстановлена пустая конфигурация."
            $config = New-DefaultAppConfig
            $configWasRecovered = $true
        }
    }

    $changed = [bool]$configWasRecovered

    if (-not (Test-ObjectProperty -Object $config -Name "profiles")) {
        $config | Add-Member -MemberType NoteProperty -Name profiles -Value @()
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config -Name "projects")) {
        $config | Add-Member -MemberType NoteProperty -Name projects -Value @()
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config -Name "activeProjectId")) {
        $config | Add-Member -MemberType NoteProperty -Name activeProjectId -Value ""
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config -Name "settings")) {
        $config | Add-Member `
            -MemberType NoteProperty `
            -Name settings `
            -Value ([pscustomobject]@{
                autoApproveTools = $false
                localRecorderEnabled = $true
                recorderRawDiagnostics = $false
            })
        $changed = $true
    }
    elseif (
        $null -eq $config.settings -or
        -not ($config.settings -is [System.Management.Automation.PSCustomObject])
    ) {
        $config.settings = [pscustomobject]@{
            autoApproveTools = $false
            localRecorderEnabled = $true
            recorderRawDiagnostics = $false
        }
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config.settings -Name "autoApproveTools")) {
        $config.settings | Add-Member `
            -MemberType NoteProperty `
            -Name autoApproveTools `
            -Value $false
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config.settings -Name "localRecorderEnabled")) {
        $config.settings | Add-Member `
            -MemberType NoteProperty `
            -Name localRecorderEnabled `
            -Value $true
        $changed = $true
    }

    if (-not (Test-ObjectProperty -Object $config.settings -Name "recorderRawDiagnostics")) {
        $config.settings | Add-Member `
            -MemberType NoteProperty `
            -Name recorderRawDiagnostics `
            -Value $false
        $changed = $true
    }

    $projects = @()
    foreach ($project in @($config.projects)) {
        if ($null -eq $project) {
            $changed = $true
            continue
        }
        if (-not ($project -is [System.Management.Automation.PSCustomObject])) {
            $changed = $true
            continue
        }
        if (-not (Test-ObjectProperty -Object $project -Name "path")) {
            $changed = $true
            continue
        }

        $projectPath = [string]$project.path
        if ([string]::IsNullOrWhiteSpace($projectPath)) {
            $changed = $true
            continue
        }

        if (-not (Test-ObjectProperty -Object $project -Name "id")) {
            $project | Add-Member NoteProperty id ([guid]::NewGuid().ToString("N"))
            $changed = $true
        }
        if (-not (Test-ObjectProperty -Object $project -Name "name")) {
            $projectName = Split-Path $projectPath -Leaf
            if ([string]::IsNullOrWhiteSpace($projectName)) {
                $projectName = "Project"
            }
            $project | Add-Member NoteProperty name $projectName
            $changed = $true
        }
        if (-not (Test-ObjectProperty -Object $project -Name "lastUsedAt")) {
            $project | Add-Member NoteProperty lastUsedAt ""
            $changed = $true
        }
        $projects = @($projects) + @($project)
    }

    # Миграция проектов из старых версий.
    $legacyPaths = @()

    if (Test-ObjectProperty -Object $config -Name "defaultProjectPath") {
        $legacy = [string]$config.defaultProjectPath
        if (-not [string]::IsNullOrWhiteSpace($legacy)) {
            $legacyPaths = @($legacyPaths) + @([string]$legacy)
        }
    }

    $profiles = @()
    foreach ($profile in @($config.profiles)) {
        if ($null -eq $profile) {
            $changed = $true
            continue
        }
        if (-not ($profile -is [System.Management.Automation.PSCustomObject])) {
            $changed = $true
            continue
        }

        if (
            -not (Test-ObjectProperty -Object $profile -Name "name") -or
            [string]::IsNullOrWhiteSpace([string]$profile.name) -or
            -not (Test-ObjectProperty -Object $profile -Name "configDir") -or
            [string]::IsNullOrWhiteSpace([string]$profile.configDir)
        ) {
            $changed = $true
            continue
        }

        if (-not (Test-ObjectProperty -Object $profile -Name "username")) {
            $profile | Add-Member NoteProperty username ""
            $changed = $true
        }
        if (-not (Test-ObjectProperty -Object $profile -Name "slug")) {
            $profile | Add-Member NoteProperty slug (Get-SafeFileName -Value ([string]$profile.name))
            $changed = $true
        }

        if (Test-ObjectProperty -Object $profile -Name "projectPath") {
            $legacy = [string]$profile.projectPath
            if (-not [string]::IsNullOrWhiteSpace($legacy)) {
                $legacyPaths = @($legacyPaths) + @([string]$legacy)
            }
        }

        foreach ($pair in @(
            @{ Name = "namespace"; Value = "" },
            @{ Name = "namespaceId"; Value = $null },
            @{ Name = "trialEndsOn"; Value = "" },
            @{ Name = "creditLimit"; Value = 24 },
            @{ Name = "model"; Value = $DefaultModel },
            @{ Name = "createdAt"; Value = "" }
        )) {
            if (-not (Test-ObjectProperty -Object $profile -Name $pair.Name)) {
                $profile | Add-Member NoteProperty $pair.Name $pair.Value
                $changed = $true
            }
        }

        $profiles = @($profiles) + @($profile)
    }

    $config.profiles = [object[]]@(
        $profiles | ForEach-Object { $_ }
    )

    foreach ($legacyPath in $legacyPaths) {
        try {
            $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($legacyPath))
        }
        catch {
            continue
        }

        $exists = @($projects | Where-Object {
            [string]::Equals([string]$_.path, $full, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0

        if (-not $exists -and (Test-Path $full -PathType Container)) {
            $project = [pscustomobject][ordered]@{
                id = [guid]::NewGuid().ToString("N")
                name = Split-Path $full -Leaf
                path = $full
                lastUsedAt = (Get-Date -Format o)
            }
            $projects = @($projects) + @($project)
            $changed = $true
        }
    }

    # Native object[] avoids a Windows PowerShell 5.1 binder bug.
    $config.projects = [object[]]@(
        $projects | ForEach-Object { $_ }
    )

    if (
        [string]::IsNullOrWhiteSpace([string]$config.activeProjectId) -and
        @($config.projects).Count -gt 0
    ) {
        $config.activeProjectId = [string]$config.projects[0].id
        $changed = $true
    }

    if ($changed) {
        Save-AppConfig -Config $config
    }

    return $config
}

function Repair-DirectoryPermissions {
    param(
        [string]$Path,
        [switch]$Quiet
    )

    if (-not (Test-Path $Path)) { return }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

        & icacls.exe $Path /inheritance:e /T /C /Q 2>$null | Out-Null
        & icacls.exe $Path /grant:r "${identity}:(OI)(CI)F" /T /C /Q 2>$null | Out-Null

        if (-not $Quiet) {
            Write-Host "Права восстановлены: $Path" -ForegroundColor Green
        }
    }
    catch {
        if (-not $Quiet) {
            Write-Warning "Не удалось восстановить права: $($_.Exception.Message)"
        }
    }
}

function Repair-AllProfilePermissions {
    param([switch]$Quiet)

    if (-not (Test-Path $ProfilesRoot)) { return }

    Get-ChildItem -Path $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Repair-DirectoryPermissions -Path $_.FullName -Quiet:$Quiet
        }
}

function Get-GlabPath {
    foreach ($name in @("glab.exe", "glab")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }

    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\glab.exe"),
        (Join-Path $env:ProgramFiles "glab\bin\glab.exe"),
        (Join-Path $env:ProgramFiles "glab\glab.exe")
    )) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-GlabVersion {
    param([string]$GlabPath)
    try {
        $text = (& $GlabPath version 2>&1 | Out-String)
        $match = [regex]::Match($text, '(\d+\.\d+\.\d+)')
        if ($match.Success) {
            return [version]$match.Groups[1].Value
        }
    }
    catch {}
    return $null
}

function Ensure-Glab {
    $glab = Get-GlabPath

    if (-not $glab) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw "Не найден glab и WinGet."
        }

        Write-Host "Установка GitLab CLI..." -ForegroundColor Cyan
        & $winget.Source install glab `
            --source winget `
            --accept-package-agreements `
            --accept-source-agreements | Out-Host

        $glab = Get-GlabPath
        if (-not $glab) {
            throw "glab установлен, но ещё не появился в PATH. Перезапустите приложение."
        }
    }

    $version = Get-GlabVersion -GlabPath $glab
    if ($null -eq $version -or $version -lt $MinimumGlabVersion) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host "Обновление GitLab CLI..." -ForegroundColor Cyan
            & $winget.Source upgrade glab `
                --source winget `
                --accept-package-agreements `
                --accept-source-agreements | Out-Host

            $glab = Get-GlabPath
            $version = Get-GlabVersion -GlabPath $glab
        }
    }

    if ($null -eq $version -or $version -lt $MinimumGlabVersion) {
        throw "Нужен glab $MinimumGlabVersion или новее."
    }

    return $glab
}

function Write-AtomicTextFile {
    param(
        [string]$Path,
        [string]$Content,
        [ValidateSet("UTF8", "ASCII")]
        [string]$Encoding = "UTF8"
    )

    $directory = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"

    try {
        $Content | Set-Content -LiteralPath $temporary -Encoding $Encoding

        for ($attempt = 1; $attempt -le 4; $attempt++) {
            try {
                Move-Item -LiteralPath $temporary -Destination $Path -Force
                return
            }
            catch {
                if ($attempt -eq 4) { throw }
                Start-Sleep -Milliseconds (75 * $attempt)
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-WindowsBuildNumber {
    try {
        $value = Get-ItemPropertyValue `
            -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
            -Name CurrentBuildNumber `
            -ErrorAction Stop

        $build = 0
        if ([int]::TryParse([string]$value, [ref]$build)) {
            return $build
        }
    }
    catch {}

    try {
        return [Environment]::OSVersion.Version.Build
    }
    catch {
        return 0
    }
}

function Read-KeyValueFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $data = [ordered]@{}
        foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $position = $line.IndexOf("=")
            if ($position -lt 1) { continue }

            $key = $line.Substring(0, $position)
            $value = $line.Substring($position + 1)
            $data[$key] = $value
        }

        return [pscustomobject]$data
    }
    catch {
        return $null
    }
}

function Get-CSharpCompilerPath {
    $candidates = @(
        (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Ensure-DuoTerminalRecorder {
    param(
        [switch]$Quiet,
        [switch]$ForceRebuild
    )

    if (-not (Test-Path -LiteralPath $RecorderSourcePath)) {
        throw "В архиве отсутствует DuoTerminalRecorder.cs. Распакуйте все файлы заново."
    }

    New-Item -ItemType Directory -Force -Path $RecorderBinRoot | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $RecorderSourcePath -Algorithm SHA256).Hash
    $storedHash = ""

    if (Test-Path -LiteralPath $RecorderHashPath) {
        try {
            $storedHash = (Get-Content -LiteralPath $RecorderHashPath -Raw -Encoding UTF8).Trim()
        }
        catch {}
    }

    if (
        -not $ForceRebuild -and
        (Test-Path -LiteralPath $RecorderExePath) -and
        $storedHash -eq $sourceHash
    ) {
        return $RecorderExePath
    }

    if (-not $Quiet) {
        Write-Host "Подготовка локального терминального рекордера..." -ForegroundColor Cyan
    }

    $compiler = Get-CSharpCompilerPath
    $temporaryExe = Join-Path $RecorderBinRoot ("DuoTerminalRecorder-{0}.exe" -f [guid]::NewGuid().ToString("N"))
    $compileOutput = @()
    $selfTestOutput = @()
    $compileCode = -1
    $selfTestCode = -1

    try {
        if ($compiler) {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"

            try {
                $compileOutput = @(
                    & $compiler `
                        /nologo `
                        /target:exe `
                        /platform:anycpu `
                        /optimize+ `
                        /warn:4 `
                        "/out:$temporaryExe" `
                        $RecorderSourcePath 2>&1
                )
                $compileCode = [int]$LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $oldPreference
            }
        }
        else {
            $source = Get-Content -LiteralPath $RecorderSourcePath -Raw -Encoding UTF8
            Add-Type `
                -TypeDefinition $source `
                -Language CSharp `
                -OutputAssembly $temporaryExe `
                -OutputType ConsoleApplication `
                -ErrorAction Stop
            $compileCode = 0
        }

        @(
            "TIME: $(Get-Date -Format o)",
            "SOURCE: $RecorderSourcePath",
            "SOURCE_SHA256: $sourceHash",
            "COMPILER: $compiler",
            "COMPILE_EXIT: $compileCode",
            "",
            "COMPILE_OUTPUT:",
            (($compileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine),
            "",
            "SELF_TEST_EXIT: not-run",
            "SELF_TEST_OUTPUT:"
        ) | Set-Content -LiteralPath $RecorderBuildLogPath -Encoding UTF8

        if (
            $compileCode -ne 0 -or
            -not (Test-Path -LiteralPath $temporaryExe)
        ) {
            throw "Не удалось собрать DuoTerminalRecorder.exe."
        }

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $selfTestOutput = @(& $temporaryExe --self-test 2>&1)
            $selfTestCode = [int]$LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }

        @(
            "TIME: $(Get-Date -Format o)",
            "SOURCE: $RecorderSourcePath",
            "SOURCE_SHA256: $sourceHash",
            "COMPILER: $compiler",
            "COMPILE_EXIT: $compileCode",
            "",
            "COMPILE_OUTPUT:",
            (($compileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine),
            "",
            "SELF_TEST_EXIT: $selfTestCode",
            "SELF_TEST_OUTPUT:",
            (($selfTestOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        ) | Set-Content -LiteralPath $RecorderBuildLogPath -Encoding UTF8

        if ($selfTestCode -ne 0) {
            throw "Рекордер не прошёл внутренний self-test."
        }

        $backupExe = "$RecorderExePath.bak"
        if (Test-Path -LiteralPath $RecorderExePath) {
            Copy-Item -LiteralPath $RecorderExePath -Destination $backupExe -Force
        }

        try {
            Move-Item -LiteralPath $temporaryExe -Destination $RecorderExePath -Force
        }
        catch {
            if (Test-Path -LiteralPath $backupExe) {
                Copy-Item -LiteralPath $backupExe -Destination $RecorderExePath -Force
            }
            throw
        }

        Remove-Item -LiteralPath $backupExe -Force -ErrorAction SilentlyContinue
        Write-AtomicTextFile -Path $RecorderHashPath -Content $sourceHash -Encoding ASCII
        Remove-Item -LiteralPath $RecorderRuntimeMarkerPath -Force -ErrorAction SilentlyContinue
        return $RecorderExePath
    }
    catch {
        Remove-Item -LiteralPath $temporaryExe -Force -ErrorAction SilentlyContinue
        throw "$($_.Exception.Message) Лог: $RecorderBuildLogPath"
    }
}

function Test-DuoTerminalRecorderRuntime {
    param(
        [string]$RecorderPath,
        [switch]$Force
    )

    $build = Get-WindowsBuildNumber
    if ($build -gt 0 -and $build -lt 17763) {
        throw "Windows build $build не поддерживает ConPTY. Нужна Windows 10 1809 (build 17763) или новее."
    }

    $sourceHash = (Get-FileHash -LiteralPath $RecorderSourcePath -Algorithm SHA256).Hash
    $exeHash = (Get-FileHash -LiteralPath $RecorderPath -Algorithm SHA256).Hash
    $markerExpected = "$sourceHash|$exeHash|$build"

    if (-not $Force -and (Test-Path -LiteralPath $RecorderRuntimeMarkerPath)) {
        try {
            $marker = (Get-Content -LiteralPath $RecorderRuntimeMarkerPath -Raw -Encoding UTF8).Trim()
            if ($marker -eq $markerExpected) {
                return $true
            }
        }
        catch {}
    }

    $probeRoot = Join-Path $RecorderBinRoot ("probe-{0}" -f [guid]::NewGuid().ToString("N"))
    $probeLogs = Join-Path $probeRoot "logs"
    $probeBridge = Join-Path $probeRoot "CHAT_BRIDGE.md"
    $probeStatus = Join-Path $probeRoot "run.status"

    New-Item -ItemType Directory -Force -Path $probeLogs | Out-Null

    try {
        $arguments = @(
            "--log-root", $probeLogs,
            "--bridge", $probeBridge,
            "--working-dir", $probeRoot,
            "--profile", "runtime-probe",
            "--username", "runtime-probe",
            "--model", "runtime-probe",
            "--project-name", "runtime-probe",
            "--run-status", $probeStatus,
            "--raw-logs", "false",
            "--present-output", "false",
            "--forward-input", "false",
            "--max-sessions", "2",
            "--max-storage-mb", "25",
            "--",
            $env:ComSpec,
            "/d",
            "/c",
            "echo __DUO_RECORDER_RUNTIME_OK__"
        )

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $probeOutput = @(& $RecorderPath @arguments 2>&1)
            $probeExit = [int]$LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }

        $status = Read-KeyValueFile -Path $probeStatus
        $probeOutputText = (($probeOutput | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                [string]$_.Exception.Message
            }
            else {
                [string]$_
            }
        }) -join [Environment]::NewLine)

        $bridgeText = if (Test-Path -LiteralPath $probeBridge) {
            Get-Content -LiteralPath $probeBridge -Raw -Encoding UTF8
        }
        else {
            ""
        }

        $sessionTranscriptText = ""
        $sessionTranscriptPath = ""

        if (
            $null -ne $status -and
            -not [string]::IsNullOrWhiteSpace([string]$status.sessionDirectory)
        ) {
            $sessionTranscriptPath = Join-Path `
                ([string]$status.sessionDirectory) `
                "TRANSCRIPT.md"

            if (Test-Path -LiteralPath $sessionTranscriptPath) {
                $sessionTranscriptText = Get-Content `
                    -LiteralPath $sessionTranscriptPath `
                    -Raw `
                    -Encoding UTF8
            }
        }

        $marker = "__DUO_RECORDER_RUNTIME_OK__"
        $markerInBridge = $bridgeText -match [regex]::Escape($marker)
        $markerInTranscript = $sessionTranscriptText -match [regex]::Escape($marker)
        $markerInRuntimeOutput = $probeOutputText -match [regex]::Escape($marker)

        $failures = New-Object Collections.Generic.List[string]

        if ($probeExit -ne 0) {
            $failures.Add("recorder exit=$probeExit")
        }

        if ($null -eq $status) {
            $failures.Add("run.status не создан")
        }
        else {
            if ([string]$status.childStarted -ne "true") {
                $failures.Add("childStarted=$([string]$status.childStarted)")
            }

            if ([string]$status.completed -ne "true") {
                $failures.Add("completed=$([string]$status.completed)")
            }

            if ([string]$status.transcriptUpdated -ne "true") {
                $failures.Add("transcriptUpdated=$([string]$status.transcriptUpdated)")
            }

            if (
                -not [string]::IsNullOrWhiteSpace([string]$status.error)
            ) {
                $failures.Add("status error=$([string]$status.error)")
            }
        }

        # A very short cmd.exe probe can finish before its one-line screen
        # becomes a meaningful CHAT_BRIDGE block. For runtime compatibility,
        # accept the marker from any real ConPTY capture channel:
        # cleaned bridge, session transcript, or recorder process output.
        # transcriptUpdated=true is still required, so this does not bypass
        # the recorder's file-writing check.
        if (
            -not $markerInBridge -and
            -not $markerInTranscript -and
            -not $markerInRuntimeOutput
        ) {
            $failures.Add("runtime marker не найден")
        }

        if ($failures.Count -gt 0) {
            $details = if ([string]::IsNullOrWhiteSpace($probeOutputText)) {
                "(вывод пуст)"
            }
            else {
                $probeOutputText.Replace(
                    [Environment]::NewLine,
                    " "
                )
            }

            throw (
                "Runtime probe не пройден: {0}. Exit={1}. Output={2}" -f
                ($failures -join "; "),
                $probeExit,
                $details
            )
        }

        Write-AtomicTextFile `
            -Path $RecorderRuntimeMarkerPath `
            -Content $markerExpected `
            -Encoding ASCII

        return $true
    }
    finally {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Clear-AuthOverrides {
    foreach ($name in @(
        "GITLAB_TOKEN",
        "GITLAB_ACCESS_TOKEN",
        "GITLAB_OAUTH_TOKEN",
        "OAUTH_TOKEN",
        "GITLAB_HOST"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Get-BooleanSetting {
    param(
        [string]$Name,
        [bool]$DefaultValue
    )

    try {
        $config = Get-AppConfig
        if (
            $config.settings -and
            (Test-ObjectProperty -Object $config.settings -Name $Name)
        ) {
            return [bool]$config.settings.$Name
        }
    }
    catch {}

    return $DefaultValue
}

function Set-BooleanSetting {
    param(
        [string]$Name,
        [bool]$Enabled
    )

    $config = Get-AppConfig

    if (-not (Test-ObjectProperty -Object $config.settings -Name $Name)) {
        $config.settings | Add-Member `
            -MemberType NoteProperty `
            -Name $Name `
            -Value $Enabled
    }
    else {
        $config.settings.$Name = $Enabled
    }

    Save-AppConfig -Config $config
}

function Get-AutoApproveTools {
    return (Get-BooleanSetting -Name "autoApproveTools" -DefaultValue $false)
}

function Set-AutoApproveTools {
    param([bool]$Enabled)
    Set-BooleanSetting -Name "autoApproveTools" -Enabled $Enabled
}

function Get-LocalRecorderEnabled {
    return (Get-BooleanSetting -Name "localRecorderEnabled" -DefaultValue $true)
}

function Set-LocalRecorderEnabled {
    param([bool]$Enabled)
    Set-BooleanSetting -Name "localRecorderEnabled" -Enabled $Enabled
}

function Get-RecorderRawDiagnosticsEnabled {
    return (Get-BooleanSetting -Name "recorderRawDiagnostics" -DefaultValue $false)
}

function Set-RecorderRawDiagnosticsEnabled {
    param([bool]$Enabled)
    Set-BooleanSetting -Name "recorderRawDiagnostics" -Enabled $Enabled
}

function Get-SafeFileName {
    param([string]$Value)

    $safe = [regex]::Replace($Value, '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "profile"
    }

    return $safe
}

function Get-ProjectStateInfo {
    param([string]$ProjectPath)

    $normalized = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
        $hashBytes = $sha.ComputeHash($bytes)
        $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }

    $key = $hash.Substring(0, 24)
    $directory = Join-Path $ProjectStateRoot $key
    $logsDirectory = Join-Path $directory "terminal-sessions"
    New-Item -ItemType Directory -Force -Path $logsDirectory | Out-Null

    return [pscustomobject][ordered]@{
        Key = $key
        Directory = $directory
        LogsDirectory = $logsDirectory
        BridgePath = Join-Path $directory "CHAT_BRIDGE.md"
    }
}

function Initialize-ChatBridge {
    param([string]$ProjectPath)

    $state = Get-ProjectStateInfo -ProjectPath $ProjectPath

    if (-not (Test-Path -LiteralPath $state.BridgePath)) {
        @'
# LOCAL CROSS-ACCOUNT TERMINAL TRANSCRIPT

Этот файл автоматически создаётся локальным ConPTY-рекордером.
Это не импорт серверного чата GitLab и не скрытые рассуждения модели.

<!-- CHAT_BRIDGE_BEGIN -->
_Записанных сессий пока нет._
<!-- CHAT_BRIDGE_END -->
'@ | Set-Content -LiteralPath $state.BridgePath -Encoding UTF8
    }

    return $state
}

function Get-ChatBridgeStatus {
    param([string]$ProjectPath)

    try {
        $state = Initialize-ChatBridge -ProjectPath $ProjectPath
        $item = Get-Item -LiteralPath $state.BridgePath

        return [pscustomobject]@{
            Exists = $true
            Path = [string]$state.BridgePath
            UpdatedAt = $item.LastWriteTime
            Text = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $false
            Path = ""
            UpdatedAt = $null
            Text = "ошибка"
        }
    }
}

function Reset-ChatBridge {
    param([string]$ProjectPath)

    $state = Get-ProjectStateInfo -ProjectPath $ProjectPath
    foreach ($path in @(
        $state.BridgePath,
        (Join-Path $state.LogsDirectory "conversation-history.md")
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    Get-ChildItem -LiteralPath $state.LogsDirectory -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    [void](Initialize-ChatBridge -ProjectPath $ProjectPath)
}

function Add-ProgressiveMemoryLine {
    param(
        [Collections.Generic.List[string]]$List,
        [string]$Value
    )

    $cleaned = [regex]::Replace(
        ([string]$Value).Trim(),
        '\s+',
        ' '
    )

    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        return
    }

    for ($i = $List.Count - 1; $i -ge [Math]::Max(0, $List.Count - 12); $i--) {
        $existing = [string]$List[$i]

        if (
            [string]::Equals(
                $existing,
                $cleaned,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return
        }

        if (
            $cleaned.StartsWith(
                $existing,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $existing.StartsWith(
                $cleaned,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            if ($cleaned.Length -gt $existing.Length) {
                $List[$i] = $cleaned
            }
            return
        }
    }

    $List.Add($cleaned)
}

function Convert-LegacyBridgePayload {
    param([string]$Content)

    if (
        [string]::IsNullOrWhiteSpace($Content) -or
        $Content -notmatch '(?m)^#### VISIBLE TERMINAL OUTPUT '
    ) {
        return $Content
    }

    $sessionMatches = [regex]::Matches(
        $Content,
        '(?ms)^## SESSION .*?(?=^## SESSION |\z)'
    )

    $convertedSessions = New-Object Collections.Generic.List[string]

    foreach ($match in $sessionMatches) {
        $session = [string]$match.Value
        $headerMatch = [regex]::Match($session, '(?m)^## SESSION .+$')
        $header = if ($headerMatch.Success) {
            [string]$headerMatch.Value
        }
        else {
            "## SESSION legacy"
        }

        $users = New-Object Collections.Generic.List[string]
        $responses = New-Object Collections.Generic.List[string]
        $diagnostics = New-Object Collections.Generic.List[string]

        foreach ($line in ($session -split '\r?\n')) {
            $trimmed = ([string]$line).Trim()

            if (
                $trimmed -match '^>\s+(.+)$' -and
                $trimmed -notmatch 'Type your message here'
            ) {
                $candidate = [string]$Matches[1]

                if ($candidate -notmatch '^/(exit|sessions|model|mcp|new|copy|feedback|settings|help|compact|doctor)(\s|$)') {
                    Add-ProgressiveMemoryLine -List $users -Value $candidate
                }

                continue
            }

            if ($trimmed -match '^[●•✓✦○◉]\s*(.+)$') {
                Add-ProgressiveMemoryLine `
                    -List $responses `
                    -Value ([string]$Matches[1])
                continue
            }

            $isImportantDiagnostic = (
                ($trimmed -match '(?i)(error|exception|failed|warning|ошибк|сбой|предупреж|build failed|tests? failed|код завершения)') -and
                ($trimmed -notmatch 'Could not find GitLab remote info')
            )

            if ($isImportantDiagnostic) {
                Add-ProgressiveMemoryLine -List $diagnostics -Value $trimmed
            }
        }

        if (
            $users.Count -eq 0 -and
            $responses.Count -eq 0 -and
            $diagnostics.Count -eq 0
        ) {
            continue
        }

        $builder = New-Object Text.StringBuilder
        [void]$builder.AppendLine($header)
        [void]$builder.AppendLine()
        [void]$builder.AppendLine("- Format: locally compacted legacy visible transcript")
        [void]$builder.AppendLine()

        $turnCount = [Math]::Max($users.Count, $responses.Count)

        for ($i = 0; $i -lt $turnCount; $i++) {
            if ($i -lt $users.Count) {
                [void]$builder.AppendLine("#### USER")
                [void]$builder.AppendLine()
                [void]$builder.AppendLine([string]$users[$i])
                [void]$builder.AppendLine()
            }

            if ($i -lt $responses.Count) {
                [void]$builder.AppendLine("#### RESPONSE / RELEVANT OUTPUT")
                [void]$builder.AppendLine()
                [void]$builder.AppendLine([string]$responses[$i])
                [void]$builder.AppendLine()
            }
        }

        if ($diagnostics.Count -gt 0) {
            [void]$builder.AppendLine("### Important terminal diagnostics")
            [void]$builder.AppendLine()

            foreach ($item in $diagnostics) {
                [void]$builder.AppendLine("- $item")
            }

            [void]$builder.AppendLine()
        }

        $convertedSessions.Add($builder.ToString().Trim())
    }

    if ($convertedSessions.Count -eq 0) {
        return $Content
    }

    while ($convertedSessions.Count -gt 14) {
        $convertedSessions.RemoveAt(0)
    }

    return ($convertedSessions -join ([Environment]::NewLine + [Environment]::NewLine))
}

function Get-LocalMemoryHealth {
    param([string]$ProjectPath)

    try {
        $state = Initialize-ChatBridge -ProjectPath $ProjectPath
        $content = Get-Content -LiteralPath $state.BridgePath -Raw -Encoding UTF8
        $payload = Get-BridgePayload `
            -BridgePath $state.BridgePath `
            -MaximumCharacters 60000

        $sessionCount = [regex]::Matches(
            $payload,
            '(?m)^## SESSION '
        ).Count

        $schema = if ($content -match 'optimized-visible-conversation-v3') {
            "v3 compact"
        }
        elseif ($content -match '(?m)^#### VISIBLE TERMINAL OUTPUT ') {
            "legacy, compacted during delivery"
        }
        else {
            "basic"
        }

        return [pscustomobject][ordered]@{
            Ready = -not [string]::IsNullOrWhiteSpace($payload)
            Characters = [long]$payload.Length
            Sessions = [int]$sessionCount
            Schema = $schema
            Path = [string]$state.BridgePath
            Text = if ([string]::IsNullOrWhiteSpace($payload)) {
                "пока пусто"
            }
            else {
                "{0}, {1} знаков, {2} сесс." -f
                    $schema,
                    (Format-Number ([long]$payload.Length)),
                    $sessionCount
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Ready = $false
            Characters = 0
            Sessions = 0
            Schema = "error"
            Path = ""
            Text = "ошибка проверки"
        }
    }
}

function Get-BridgePayload {
    param(
        [string]$BridgePath,
        [int]$MaximumCharacters = 60000
    )

    if (-not (Test-Path -LiteralPath $BridgePath)) {
        return ""
    }

    try {
        $content = Get-Content -LiteralPath $BridgePath -Raw -Encoding UTF8
        $beginMarker = "<!-- CHAT_BRIDGE_BEGIN -->"
        $endMarker = "<!-- CHAT_BRIDGE_END -->"

        $beginIndex = $content.IndexOf(
            $beginMarker,
            [StringComparison]::Ordinal
        )
        $endIndex = $content.LastIndexOf(
            $endMarker,
            [StringComparison]::Ordinal
        )

        if ($beginIndex -ge 0 -and $endIndex -gt $beginIndex) {
            $payloadStart = $beginIndex + $beginMarker.Length
            $content = $content.Substring(
                $payloadStart,
                $endIndex - $payloadStart
            )
        }

        $content = Convert-LegacyBridgePayload -Content $content
        $content = $content.Trim()

        if (
            [string]::IsNullOrWhiteSpace($content) -or
            $content.Contains("_Записанных сессий пока нет._")
        ) {
            return ""
        }

        if ($content.Length -le $MaximumCharacters) {
            return $content
        }

        $notice = @"

[Earlier compact local memory omitted. The newest retained sessions follow.]

"@

        $available = [Math]::Max(
            1000,
            $MaximumCharacters - $notice.Length
        )

        $candidateStart = $content.Length - $available
        $sessionBoundary = $content.IndexOf(
            "## SESSION ",
            $candidateStart,
            [StringComparison]::Ordinal
        )

        if ($sessionBoundary -ge 0) {
            $candidateStart = $sessionBoundary
        }

        return $notice + $content.Substring($candidateStart)
    }
    catch {
        return ""
    }
}

function Set-ProfileAgentsMemory {
    param(
        $Profile,
        [string]$ProjectPath,
        [string]$ProjectName,
        [string]$BridgePath,
        [bool]$Enabled
    )

    $agentsPath = Join-Path ([string]$Profile.configDir) "AGENTS.md"
    $beginMarker = "<!-- GITLAB_DUO_SWITCHER_MEMORY_BEGIN -->"
    $endMarker = "<!-- GITLAB_DUO_SWITCHER_MEMORY_END -->"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path ([string]$Profile.configDir) |
        Out-Null

    $existing = if (Test-Path -LiteralPath $agentsPath) {
        Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8
    }
    else {
        ""
    }

    $pattern = "(?s)" +
        [regex]::Escape($beginMarker) +
        ".*?" +
        [regex]::Escape($endMarker)

    $withoutManagedBlock = [regex]::Replace(
        [string]$existing,
        $pattern,
        ""
    ).TrimEnd()

    $withoutManagedBlock = [regex]::Replace(
        $withoutManagedBlock,
        "(?m)^\s*" + [regex]::Escape($beginMarker) + "\s*$",
        ""
    )
    $withoutManagedBlock = [regex]::Replace(
        $withoutManagedBlock,
        "(?m)^\s*" + [regex]::Escape($endMarker) + "\s*$",
        ""
    ).TrimEnd()

    $payload = if ($Enabled) {
        Get-BridgePayload `
            -BridgePath $BridgePath `
            -MaximumCharacters 60000
    }
    else {
        ""
    }

    if ([string]::IsNullOrWhiteSpace($payload)) {
        if ([string]::IsNullOrWhiteSpace($withoutManagedBlock)) {
            if (Test-Path -LiteralPath $agentsPath) {
                Remove-Item `
                    -LiteralPath $agentsPath `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-AtomicTextFile `
                -Path $agentsPath `
                -Content ($withoutManagedBlock.Trim() + [Environment]::NewLine) `
                -Encoding UTF8
        }

        return [pscustomobject][ordered]@{
            Ready = $false
            Path = $agentsPath
            Characters = 0
            Text = "локальный transcript пока пуст"
        }
    }

    $managedBlock = @"
$beginMarker
# GitLab Duo Switcher: compact cross-account memory

This section is generated automatically for the currently selected project.

Current project: $ProjectName
Current working directory: $ProjectPath

MANDATORY MEMORY RULES:

1. The compact memory below is valid local working context reconstructed from the previous GitLab Duo profile in this same project.
2. Use facts found in it when answering the user's next message.
3. If the user asks what was said, decided, remembered, changed, or tested in the previous account, answer from this local memory.
4. Do not answer that you lack access to the previous account when the requested information is explicitly present below.
5. This is not an imported GitLab server conversation. Do not claim that server chat history or chat bubbles were transferred.
6. The newest user message always has priority over this memory.
7. The recorder removes most TUI redraws and progressive duplicates. Prefer newer complete entries if any uncertainty remains.
8. Never expose or invent private chain-of-thought.
9. Do not repeat this whole memory unless the user explicitly asks for it.
10. Continue naturally without requiring the user to paste anything again.

--- BEGIN COMPACT PREVIOUS-PROFILE MEMORY ---

$payload

--- END COMPACT PREVIOUS-PROFILE MEMORY ---
$endMarker
"@

    $combined = if ([string]::IsNullOrWhiteSpace($withoutManagedBlock)) {
        $managedBlock.Trim() + [Environment]::NewLine
    }
    else {
        $withoutManagedBlock.Trim() +
            [Environment]::NewLine +
            [Environment]::NewLine +
            $managedBlock.Trim() +
            [Environment]::NewLine
    }

    $agentsFileExists = Test-Path -LiteralPath $agentsPath
    $agentsContentUnchanged = $false

    if ($agentsFileExists) {
        $agentsContentUnchanged = [string]::Equals(
            (Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8),
            $combined,
            [StringComparison]::Ordinal
        )
    }

    if ($agentsContentUnchanged) {
        return [pscustomobject][ordered]@{
            Ready = $true
            Path = $agentsPath
            Characters = [long]$payload.Length
            Text = "compact AGENTS.md cached + hook"
        }
    }

    if (Test-Path -LiteralPath $agentsPath) {
        $backupPath = "$agentsPath.switcher-backup"
        Copy-Item `
            -LiteralPath $agentsPath `
            -Destination $backupPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-AtomicTextFile `
        -Path $agentsPath `
        -Content $combined `
        -Encoding UTF8

    $written = Get-Content -LiteralPath $agentsPath -Raw -Encoding UTF8

    if (
        $written.IndexOf($beginMarker, [StringComparison]::Ordinal) -lt 0 -or
        $written.IndexOf($endMarker, [StringComparison]::Ordinal) -lt 0 -or
        $written.IndexOf(
            "--- BEGIN COMPACT PREVIOUS-PROFILE MEMORY ---",
            [StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "Не удалось проверить управляемый блок AGENTS.md."
    }

    return [pscustomobject][ordered]@{
        Ready = $true
        Path = $agentsPath
        Characters = [long]$payload.Length
        Text = "compact AGENTS.md + hook"
    }
}

function Set-ProfileEnvironment {
    param($Profile)
    Clear-AuthOverrides
    Repair-DirectoryPermissions -Path (Split-Path ([string]$Profile.configDir) -Parent) -Quiet
    $env:GLAB_CONFIG_DIR = [string]$Profile.configDir
    $env:GITLAB_DUO_MODEL = [string]$Profile.model
    $env:GITLAB_ENABLE_PROJECT_HOOKS = "true"

    if (Get-AutoApproveTools) {
        $env:GITLAB_DANGEROUSLY_SKIP_PERMISSIONS = "true"
    }
    else {
        Remove-Item Env:GITLAB_DANGEROUSLY_SKIP_PERMISSIONS -ErrorAction SilentlyContinue
    }
}

function Get-Profile {
    param([string]$Name)
    $config = Get-AppConfig
    $profile = @($config.profiles | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($profile.Count -eq 0) {
        throw "Профиль '$Name' не найден."
    }
    return $profile[0]
}

function Get-StoredUsername {
    param($Profile)

    $file = Join-Path ([string]$Profile.configDir) "config.yml"
    if (-not (Test-Path $file)) { return $null }

    try {
        $text = Get-Content -Path $file -Raw -Encoding UTF8
        $match = [regex]::Match(
            $text,
            '(?im)^\s*user:\s*["'']?([A-Za-z0-9_.-]+)["'']?\s*$'
        )
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }
    catch {}

    return $null
}

function Invoke-GlabJson {
    param(
        $Profile,
        [string]$Endpoint
    )

    $glab = Ensure-Glab
    Set-ProfileEnvironment -Profile $Profile

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $raw = @(& $glab api $Endpoint --hostname gitlab.com 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()

    if ($code -ne 0) {
        throw $text
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ($text | ConvertFrom-Json)
}

function Test-ProfileAuth {
    param($Profile)

    $file = Join-Path ([string]$Profile.configDir) "config.yml"
    if (-not (Test-Path $file)) { return $false }

    try {
        [void](Invoke-GlabJson -Profile $Profile -Endpoint "/user")
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-ProfileLogin {
    param($Profile)

    $glab = Ensure-Glab
    New-Item -ItemType Directory -Force -Path $Profile.configDir | Out-Null
    Repair-DirectoryPermissions -Path (Split-Path ([string]$Profile.configDir) -Parent) -Quiet
    Set-ProfileEnvironment -Profile $Profile

    Write-Host ""
    Write-Host "Откроется GitLab OAuth. Войдите в нужный аккаунт." -ForegroundColor Cyan

    & $glab auth login `
        --hostname gitlab.com `
        --web `
        --git-protocol https | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "Авторизация не завершилась."
    }

    $username = Get-StoredUsername -Profile $Profile
    if ([string]::IsNullOrWhiteSpace($username)) {
        try {
            $user = Invoke-GlabJson -Profile $Profile -Endpoint "/user"
            $username = [string]$user.username
        }
        catch {}
    }

    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = Read-Host "Введите GitLab username"
    }

    if ([string]::IsNullOrWhiteSpace($username)) {
        throw "Username не может быть пустым."
    }

    return $username
}

function Install-Duo {
    param($Profile)

    $glab = Ensure-Glab
    Set-ProfileEnvironment -Profile $Profile

    Write-Host "Установка/обновление GitLab Duo CLI..." -ForegroundColor Cyan
    & $glab duo cli --install --yes | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось установить GitLab Duo CLI."
    }
}

function Get-OwnedGroups {
    param($Profile)

    try {
        $groups = Invoke-GlabJson `
            -Profile $Profile `
            -Endpoint "groups?owned=true&top_level_only=true&per_page=100"
        return @($groups)
    }
    catch {
        return @()
    }
}

function Choose-Namespace {
    param($Profile)

    if (-not [string]::IsNullOrWhiteSpace([string]$Profile.namespace)) {
        return [string]$Profile.namespace
    }

    $groups = @(Get-OwnedGroups -Profile $Profile)
    if ($groups.Count -eq 0) {
        Write-Warning "Top-level group не найдена. Namespace можно настроить позже."
        return ""
    }

    if ($groups.Count -eq 1) {
        $selected = $groups[0]
    }
    else {
        Write-Title "Выбор GitLab Duo namespace"
        for ($i = 0; $i -lt $groups.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $groups[$i].full_path)
        }

        do {
            $choice = Read-Host "Номер группы"
            $index = 0
            $ok = [int]::TryParse($choice, [ref]$index)
        } until ($ok -and $index -ge 1 -and $index -le $groups.Count)

        $selected = $groups[$index - 1]
    }

    $Profile.namespace = [string]$selected.full_path
    $Profile.namespaceId = $selected.id

    if (Test-ObjectProperty -Object $selected -Name "trial_ends_on") {
        $Profile.trialEndsOn = [string]$selected.trial_ends_on
    }

    return [string]$selected.full_path
}

function Get-ProjectById {
    param(
        $Config,
        [string]$Id
    )
    return @($Config.projects | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Get-ActiveProject {
    $config = Get-AppConfig
    $project = Get-ProjectById -Config $config -Id ([string]$config.activeProjectId)

    if (
        @($project).Count -eq 0 -or
        -not (Test-Path -LiteralPath ([string]$project[0].path) -PathType Container)
    ) {
        return $null
    }

    return $project[0]
}

function Add-ProjectPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Путь проекта не может быть пустым."
    }

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim('" '))
        $full = [IO.Path]::GetFullPath($expanded)
    }
    catch {
        throw "Некорректный путь проекта: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Папка не существует: $full"
    }

    $config = Get-AppConfig
    $existing = @($config.projects | Where-Object {
        [string]::Equals([string]$_.path, $full, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)

    if ($existing.Count -gt 0) {
        $config.activeProjectId = [string]$existing[0].id
        $existing[0].lastUsedAt = (Get-Date -Format o)
        Save-AppConfig -Config $config
        return $existing[0]
    }

    $defaultName = Split-Path $full -Leaf
    $name = Read-Host "Название проекта [Enter = $defaultName]"
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $defaultName
    }

    $project = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString("N")
        name = $name
        path = $full
        lastUsedAt = (Get-Date -Format o)
    }

    $config.projects = @($config.projects) + @($project)
    $config.activeProjectId = [string]$project.id
    Save-AppConfig -Config $config

    Ensure-ContextFiles -Path $full
    return $project
}

function Browse-ProjectFolder {
    $initialPath = ""

    try {
        $activeProject = Get-ActiveProject
        if ($activeProject -and (Test-Path -LiteralPath ([string]$activeProject.path) -PathType Container)) {
            $initialPath = [string]$activeProject.path
        }
    }
    catch {}

    Write-Host "Открываю окно выбора папки..." -ForegroundColor Cyan

    $owner = $null
    $dialog = $null
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()

        # A tiny topmost owner prevents the folder dialog from opening
        # behind Windows Terminal.
        $owner = New-Object System.Windows.Forms.Form
        $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $owner.ShowInTaskbar = $false
        $owner.TopMost = $true
        $owner.Width = 1
        $owner.Height = 1
        $owner.Opacity = 0.01
        $owner.Text = "GitLab Duo CLI Switcher"
        $owner.Show()
        $owner.Activate()
        $owner.BringToFront()

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Выберите папку проекта"
        $dialog.ShowNewFolderButton = $true

        if (-not [string]::IsNullOrWhiteSpace($initialPath)) {
            $dialog.SelectedPath = $initialPath
        }

        $result = $dialog.ShowDialog($owner)

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = [string]$dialog.SelectedPath

            if (-not [string]::IsNullOrWhiteSpace($selected)) {
                return $selected
            }
        }

        if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
            Write-Host "Выбор папки отменён." -ForegroundColor DarkGray
            return ""
        }
    }
    catch {
        Write-Warning "Стандартное окно выбора папки не открылось. Пробую Explorer."
    }
    finally {
        if ($dialog) {
            $dialog.Dispose()
        }

        if ($owner) {
            $owner.Close()
            $owner.Dispose()
        }

        $ErrorActionPreference = $oldPreference
    }

    # Fallback for systems where Windows Forms FolderBrowserDialog fails.
    try {
        $shell = New-Object -ComObject Shell.Application
        $flags = 0x00000001 + 0x00000040
        $folder = $shell.BrowseForFolder(
            0,
            "Выберите папку проекта",
            $flags,
            $initialPath
        )

        if ($folder -and $folder.Self -and $folder.Self.Path) {
            return [string]$folder.Self.Path
        }

        Write-Host "Выбор папки отменён." -ForegroundColor DarkGray
        return ""
    }
    catch {
        Write-Warning "Не удалось открыть окно выбора папки: $($_.Exception.Message)"
        Write-Host "Используйте N и вставьте полный путь вручную." -ForegroundColor Yellow
        return ""
    }
}

function Select-Project {
    param(
        [string]$Heading = "Выбор проекта",
        [switch]$AllowCancel
    )

    while ($true) {
        $config = Get-AppConfig
        $projects = @($config.projects)
        $active = Get-ActiveProject

        Write-Title $Heading

        if ($projects.Count -eq 0) {
            Write-Host "  Сохранённых проектов пока нет." -ForegroundColor Yellow
        }
        else {
            for ($i = 0; $i -lt $projects.Count; $i++) {
                $mark = if ($active -and $projects[$i].id -eq $active.id) { "●" } else { " " }
                Write-Host ("  {0} {1}. {2}" -f $mark, ($i + 1), $projects[$i].name) -ForegroundColor White
                Write-Host ("      {0}" -f $projects[$i].path) -ForegroundColor DarkGray
            }
        }

        Write-Host ""
        Write-Host "  N — вставить новый путь" -ForegroundColor Cyan
        Write-Host "  B — выбрать папку окном" -ForegroundColor Cyan
        if ($active) {
            Write-Host "  Enter — оставить активный проект" -ForegroundColor Cyan
        }
        if ($AllowCancel) {
            Write-Host "  Q — отмена" -ForegroundColor Cyan
        }

        $choice = Read-Host "Выбор"

        if ([string]::IsNullOrWhiteSpace($choice) -and $active) {
            return $active
        }

        if ($AllowCancel -and $choice -match '^(q|quit|отмена)$') {
            return $null
        }

        if ($choice -match '^(n|new|новый)$') {
            $path = Read-Host "Вставьте полный путь к папке"
            try {
                return (Add-ProjectPath -Path $path)
            }
            catch {
                Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
                Pause-Brief
                continue
            }
        }

        if ($choice -match '^(b|browse|обзор)$') {
            $path = Browse-ProjectFolder
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                try {
                    return (Add-ProjectPath -Path $path)
                }
                catch {
                    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
                    Pause-Brief
                }
            }
            continue
        }

        $index = 0
        if (
            [int]::TryParse($choice, [ref]$index) -and
            $index -ge 1 -and
            $index -le $projects.Count
        ) {
            try {
                $project = $projects[$index - 1]
                $config.activeProjectId = [string]$project.id
                $project.lastUsedAt = (Get-Date -Format o)
                Save-AppConfig -Config $config
                Ensure-ContextFiles -Path ([string]$project.path)
                return $project
            }
            catch {
                Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
                Pause-Brief
                continue
            }
        }
    }
}

function Move-LegacyContextFiles {
    param([string]$Path)

    $legacyNames = @(
        "CURRENT_TASK.md",
        "AI_HANDOFF.md",
        "AI_CONTEXT_PACK.md"
    )

    $legacyRoot = Join-Path $Path ".gitlab\duo\legacy-context"

    foreach ($name in $legacyNames) {
        $source = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }

        New-Item -ItemType Directory -Force -Path $legacyRoot | Out-Null
        $destination = Join-Path $legacyRoot $name

        if (Test-Path -LiteralPath $destination) {
            $base = [IO.Path]::GetFileNameWithoutExtension($name)
            $extension = [IO.Path]::GetExtension($name)
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $destination = Join-Path $legacyRoot ("{0}-{1}{2}" -f $base, $stamp, $extension)
        }

        try {
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
        catch {
            Write-Warning "Не удалось убрать старый файл '$name'."
        }
    }
}

function Set-SwitcherProjectHook {
    param([string]$ProjectPath)

    $duoDir = Join-Path $ProjectPath ".gitlab\duo"
    $hooksPath = Join-Path $duoDir "hooks.json"
    $backupPath = "$hooksPath.switcher-backup"
    New-Item -ItemType Directory -Force -Path $duoDir | Out-Null

    $config = $null

    if (Test-Path -LiteralPath $hooksPath) {
        try {
            $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            if (
                $null -eq $config -or
                -not ($config -is [System.Management.Automation.PSCustomObject])
            ) {
                throw "Корень hooks.json должен быть JSON-объектом."
            }
            Copy-Item -LiteralPath $hooksPath -Destination $backupPath -Force
        }
        catch {
            $invalidBackup = "$hooksPath.invalid-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Copy-Item -LiteralPath $hooksPath -Destination $invalidBackup -Force
            Write-Warning "Существующий hooks.json повреждён. Создан backup: $invalidBackup"
            $config = [pscustomobject]@{}
        }
    }
    else {
        $config = [pscustomobject]@{}
    }

    if (-not (Test-ObjectProperty -Object $config -Name "hooks")) {
        $config | Add-Member -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{})
    }
    elseif (
        $null -eq $config.hooks -or
        -not ($config.hooks -is [System.Management.Automation.PSCustomObject])
    ) {
        $config.hooks = [pscustomobject]@{}
    }

    if (-not (Test-ObjectProperty -Object $config.hooks -Name "SessionStart")) {
        $config.hooks | Add-Member -MemberType NoteProperty -Name SessionStart -Value @()
    }

    $groups = @()
    foreach ($group in @($config.hooks.SessionStart)) {
        if ($null -eq $group) { continue }

        if (-not (Test-ObjectProperty -Object $group -Name "hooks")) {
            $groups = @($groups) + @($group)
            continue
        }

        $isSwitcherGroup = $false
        foreach ($hook in @($group.hooks)) {
            if (
                $hook -and
                (Test-ObjectProperty -Object $hook -Name "command") -and
                ([string]$hook.command) -match 'switcher-context\.ps1'
            ) {
                $isSwitcherGroup = $true
                break
            }
        }

        if (-not $isSwitcherGroup) {
            $groups = @($groups) + @($group)
        }
    }

    $switcherGroup = [pscustomobject][ordered]@{
        matcher = "startup|resume"
        hooks = @(
            [pscustomobject][ordered]@{
                type = "command"
                command = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".gitlab\duo\switcher-context.ps1"'
                timeout = 30
            }
        )
    }

    $groups = @($groups) + @($switcherGroup)
    $config.hooks.SessionStart = [object[]]@(
        $groups | ForEach-Object { $_ }
    )

    $json = $config | ConvertTo-Json -Depth 30
    [void]($json | ConvertFrom-Json)
    Write-AtomicTextFile -Path $hooksPath -Content $json -Encoding UTF8
}

function Ensure-ContextFiles {
    param([string]$Path)

    $target = Join-Path $Path "PROJECT_CONTEXT.md"

    if (-not (Test-Path -LiteralPath $target)) {
        @'
# PROJECT CONTEXT

Этот файл — постоянный контекст конкретного проекта для всех GitLab Duo аккаунтов.

## Заметки владельца

Здесь можно вручную записывать важные требования, ограничения и пожелания.
ИИ не должен удалять или переписывать этот раздел без прямой просьбы.

<!-- AI_CONTEXT_BEGIN -->
_Контекст проекта ещё не создан. В GitLab Duo CLI Switcher нажмите `T`._
<!-- AI_CONTEXT_END -->
'@ | Set-Content -LiteralPath $target -Encoding UTF8
    }

    Move-LegacyContextFiles -Path $Path
    [void](Initialize-ChatBridge -ProjectPath $Path)

    $duoDir = Join-Path $Path ".gitlab\duo"
    New-Item -ItemType Directory -Force -Path $duoDir | Out-Null

    $hookScript = Join-Path $duoDir "switcher-context.ps1"
    @'
$ErrorActionPreference = "SilentlyContinue"
$project = if ($env:DUO_PROJECT_DIR) { $env:DUO_PROJECT_DIR } else { (Get-Location).Path }

function Get-LimitedText {
    param(
        [string]$Path,
        [int]$MaximumCharacters
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($text.Length -le $MaximumCharacters) {
            return $text
        }

        $notice = @"

[... middle section omitted by GitLab Duo CLI Switcher because the file exceeds the emergency safety limit ...]

"@

        $available = [Math]::Max(1000, $MaximumCharacters - $notice.Length)
        $headLength = [int][Math]::Floor($available * 0.40)
        $tailLength = $available - $headLength

        return $text.Substring(0, $headLength) +
            $notice +
            $text.Substring($text.Length - $tailLength)
    }
    catch {
        return ""
    }
}

function Invoke-GitText {
    param([string[]]$Arguments)

    try {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = @(& git -c core.safecrlf=false -c core.quotepath=false -C $project @Arguments 2>&1)
        $ErrorActionPreference = $oldPreference

        return (($output | Select-Object -First 200 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                [string]$_.Exception.Message
            }
            else {
                [string]$_
            }
        }) -join [Environment]::NewLine)
    }
    catch {
        return ""
    }
}

Write-Output "=== PROJECT MEMORY FROM GITLAB DUO SWITCHER ==="

$contextFile = Join-Path $project "PROJECT_CONTEXT.md"
$context = Get-LimitedText -Path $contextFile -MaximumCharacters 300000
if (-not [string]::IsNullOrWhiteSpace($context)) {
    Write-Output ""
    Write-Output "--- PROJECT_CONTEXT.md ---"
    Write-Output $context
}

if (
    $env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED -eq "true" -and
    $env:SWITCHER_LOCAL_TRANSCRIPT_FILE
) {
    $transcript = Get-LimitedText `
        -Path $env:SWITCHER_LOCAL_TRANSCRIPT_FILE `
        -MaximumCharacters 180000

    if (-not [string]::IsNullOrWhiteSpace($transcript)) {
        Write-Output ""
        Write-Output "--- LOCAL CROSS-ACCOUNT TERMINAL TRANSCRIPT ---"
        Write-Output $transcript

        Write-Output ""
        Write-Output "LOCAL TRANSCRIPT RULES:"
        Write-Output "This is valid local working memory from a previous GitLab Duo profile in this project."
        Write-Output "Use facts found here when answering the user's next message."
        Write-Output "If asked what the previous account said or remembered, answer from this transcript when the answer is present."
        Write-Output "Do not say you lack access to the previous account when the requested fact is explicitly present here."
        Write-Output "This is not a GitLab server chat import and can contain terminal noise."
        Write-Output "Prefer complete later entries over partial earlier TUI redraws."
        Write-Output "The newest user message has priority."
        Write-Output "Do not claim that server chat bubbles were transferred."
        Write-Output "Do not repeat the full transcript unless asked."
        Write-Output "Never expose or invent private chain-of-thought."
    }
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Output ""
    Write-Output "--- CURRENT GIT STATE ---"

    $status = Invoke-GitText -Arguments @("status", "--short", "--untracked-files=no")
    if ($status) {
        Write-Output ""
        Write-Output "git status --short --untracked-files=no"
        Write-Output $status
    }

    $diff = Invoke-GitText -Arguments @("diff", "--stat")
    if ($diff) {
        Write-Output ""
        Write-Output "git diff --stat"
        Write-Output $diff
    }

    $log = Invoke-GitText -Arguments @("log", "-5", "--oneline")
    if ($log) {
        Write-Output ""
        Write-Output "last commits"
        Write-Output $log
    }
}

Write-Output ""
Write-Output "PROJECT_CONTEXT.md is durable project knowledge."
Write-Output "The latest user message is the active task."
Write-Output "Do not create CURRENT_TASK.md, AI_HANDOFF.md, or AI_CONTEXT_PACK.md."
Write-Output "Refresh PROJECT_CONTEXT.md only when explicitly requested."
'@ | Set-Content -LiteralPath $hookScript -Encoding UTF8

    Set-SwitcherProjectHook -ProjectPath $Path
}

function Format-ContextCharacterCount {
    param([long]$Characters)

    if ($Characters -ge 1000000) {
        return ("{0:0.00} млн знаков" -f ($Characters / 1000000.0))
    }

    if ($Characters -ge 1000) {
        return ("{0:0.0} тыс. знаков" -f ($Characters / 1000.0))
    }

    return ("{0} знаков" -f $Characters)
}

function Get-ContextSegments {
    param([string]$Content)

    $beginMarker = "<!-- AI_CONTEXT_BEGIN -->"
    $endMarker = "<!-- AI_CONTEXT_END -->"

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "PROJECT_CONTEXT.md пуст."
    }

    $beginIndex = $Content.IndexOf(
        $beginMarker,
        [StringComparison]::Ordinal
    )
    $endIndex = $Content.IndexOf(
        $endMarker,
        [StringComparison]::Ordinal
    )

    if ($beginIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -le $beginIndex) {
        throw "В PROJECT_CONTEXT.md отсутствуют корректные AI_CONTEXT-маркеры."
    }

    if (
        $Content.IndexOf(
            $beginMarker,
            $beginIndex + $beginMarker.Length,
            [StringComparison]::Ordinal
        ) -ge 0 -or
        $Content.IndexOf(
            $endMarker,
            $endIndex + $endMarker.Length,
            [StringComparison]::Ordinal
        ) -ge 0
    ) {
        throw "В PROJECT_CONTEXT.md найдено несколько наборов AI_CONTEXT-маркеров."
    }

    $managedStart = $beginIndex + $beginMarker.Length
    $managedLength = $endIndex - $managedStart

    return [pscustomobject][ordered]@{
        BeginMarker = $beginMarker
        EndMarker = $endMarker
        Prefix = $Content.Substring(0, $managedStart)
        Managed = $Content.Substring($managedStart, $managedLength)
        Suffix = $Content.Substring($endIndex)
    }
}

function Get-ProjectContextStatus {
    param([string]$Path)

    $file = Join-Path $Path "PROJECT_CONTEXT.md"
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject][ordered]@{
            Ready = $false
            Length = 0
            State = "missing"
            NeedsCompression = $false
            HardLimited = $false
            Text = "не создан"
        }
    }

    try {
        $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $length = [long]$content.Length
        $sizeText = Format-ContextCharacterCount -Characters $length

        if (
            [string]::IsNullOrWhiteSpace($content) -or
            $content.Contains("_Контекст проекта ещё не создан.")
        ) {
            return [pscustomobject][ordered]@{
                Ready = $false
                Length = $length
                State = "empty"
                NeedsCompression = $false
                HardLimited = $false
                Text = "не заполнен — нажмите T"
            }
        }

        $stamp = (Get-Item -LiteralPath $file).LastWriteTime.ToString("yyyy-MM-dd HH:mm")

        if ($length -gt $ContextHardLimitCharacters) {
            return [pscustomobject][ordered]@{
                Ready = $true
                Length = $length
                State = "hard"
                NeedsCompression = $true
                HardLimited = $true
                Text = "слишком большой: $sizeText; в сессию попадёт начало и конец — нажмите C"
            }
        }

        if ($length -gt $ContextSoftLimitCharacters) {
            return [pscustomobject][ordered]@{
                Ready = $true
                Length = $length
                State = "soft"
                NeedsCompression = $true
                HardLimited = $false
                Text = "большой: $sizeText — рекомендуется C"
            }
        }

        return [pscustomobject][ordered]@{
            Ready = $true
            Length = $length
            State = "ok"
            NeedsCompression = $false
            HardLimited = $false
            Text = "готов, $sizeText, обновлён $stamp"
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Ready = $false
            Length = 0
            State = "error"
            NeedsCompression = $false
            HardLimited = $false
            Text = "ошибка чтения"
        }
    }
}

function Get-ContextBackupDirectory {
    param([string]$ProjectPath)

    $directory = Join-Path $ProjectPath ".gitlab\duo\context-backups"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    $ignoreFile = Join-Path $directory ".gitignore"
    if (-not (Test-Path -LiteralPath $ignoreFile)) {
        @'
*
!.gitignore
'@ | Set-Content -LiteralPath $ignoreFile -Encoding UTF8
    }

    return $directory
}

function Remove-OldContextBackups {
    param([string]$BackupDirectory)

    $backups = @(
        Get-ChildItem `
            -LiteralPath $BackupDirectory `
            -Filter "PROJECT_CONTEXT-*.md" `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    )

    if ($backups.Count -le $ContextCompressionBackupCount) {
        return
    }

    foreach ($item in @($backups | Select-Object -Skip $ContextCompressionBackupCount)) {
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
    }
}

function New-ContextBackup {
    param(
        [string]$ProjectPath,
        [string]$ContextPath
    )

    $directory = Get-ContextBackupDirectory -ProjectPath $ProjectPath
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Join-Path $directory "PROJECT_CONTEXT-$stamp.md"

    Copy-Item -LiteralPath $ContextPath -Destination $backupPath -Force
    Remove-OldContextBackups -BackupDirectory $directory

    return $backupPath
}

function Select-ProfileForContextCompression {
    $config = Get-AppConfig
    $profiles = @($config.profiles)

    if ($profiles.Count -eq 0) {
        Write-Warning "Сначала добавьте хотя бы один GitLab-аккаунт через A."
        return $null
    }

    Clear-Host
    Write-Title "Выбор аккаунта для сжатия контекста"

    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host ("  {0}. {1}  @{2}" -f ($i + 1), $profiles[$i].name, $profiles[$i].username)
        Write-Host ("     модель: {0}" -f $profiles[$i].model) -ForegroundColor DarkGray
    }

    Write-Host ""
    $choice = Read-Host "Номер или Enter для отмены"
    $index = 0

    if (-not [int]::TryParse($choice, [ref]$index)) {
        return $null
    }

    if ($index -lt 1 -or $index -gt $profiles.Count) {
        return $null
    }

    return $profiles[$index - 1]
}

function Test-CompressedManagedContext {
    param(
        [string]$OriginalContent,
        [string]$CandidateManaged
    )

    $result = [pscustomobject][ordered]@{
        Valid = $false
        Message = ""
        CandidateContent = ""
        OriginalLength = 0
        CandidateLength = 0
        Ratio = 0.0
    }

    try {
        $segments = Get-ContextSegments -Content $OriginalContent
        $managed = [string]$CandidateManaged

        if ([string]::IsNullOrWhiteSpace($managed)) {
            throw "GitLab Duo вернул пустой контекст."
        }

        $managed = $managed.Trim()

        if (
            $managed.Contains($segments.BeginMarker) -or
            $managed.Contains($segments.EndMarker)
        ) {
            throw "Сжатая часть не должна содержать AI_CONTEXT-маркеры."
        }

        if ($managed.Length -lt $ContextCompressionMinimumCharacters) {
            throw "Результат слишком короткий и может потерять важные сведения."
        }

        $originalHeadingCount = [regex]::Matches(
            $segments.Managed,
            '(?m)^\s*##\s+\S'
        ).Count

        $candidateHeadingCount = [regex]::Matches(
            $managed,
            '(?m)^\s*##\s+\S'
        ).Count

        $requiredHeadingCount = [Math]::Max(
            3,
            [Math]::Min(8, [int][Math]::Floor($originalHeadingCount * 0.50))
        )

        if (
            $originalHeadingCount -ge 3 -and
            $candidateHeadingCount -lt $requiredHeadingCount
        ) {
            throw "Сжатый контекст потерял слишком много структурных разделов."
        }

        $candidate = $segments.Prefix +
            [Environment]::NewLine +
            $managed +
            [Environment]::NewLine +
            $segments.Suffix

        $originalLength = [long]$OriginalContent.Length
        $candidateLength = [long]$candidate.Length
        $ratio = if ($originalLength -gt 0) {
            [double]$candidateLength / [double]$originalLength
        }
        else {
            1.0
        }

        if ($candidateLength -ge $originalLength) {
            throw "GitLab Duo не уменьшил размер файла."
        }

        if ($candidateLength -gt $ContextSoftLimitCharacters) {
            throw "Результат всё ещё больше мягкого лимита в $ContextSoftLimitCharacters знаков."
        }

        if ($ratio -lt $ContextCompressionMinimumRatio) {
            throw "Результат сжат слишком сильно. Switcher не применил его из-за риска потери данных."
        }

        $candidateSegments = Get-ContextSegments -Content $candidate

        if (
            -not [string]::Equals(
                $candidateSegments.Prefix,
                $segments.Prefix,
                [StringComparison]::Ordinal
            ) -or
            -not [string]::Equals(
                $candidateSegments.Suffix,
                $segments.Suffix,
                [StringComparison]::Ordinal
            )
        ) {
            throw "Защищённая часть файла изменилась."
        }

        $result.Valid = $true
        $result.Message = "OK"
        $result.CandidateContent = $candidate
        $result.OriginalLength = $originalLength
        $result.CandidateLength = $candidateLength
        $result.Ratio = $ratio
    }
    catch {
        $result.Message = [string]$_.Exception.Message
    }

    return $result
}

function Test-ContextCompressionLogic {
    $ownerPrefix = @'
# PROJECT CONTEXT

## Заметки владельца

НЕ МЕНЯТЬ.

<!-- AI_CONTEXT_BEGIN -->
'@

    $managedSections = New-Object Collections.Generic.List[string]
    for ($i = 1; $i -le 10; $i++) {
        $managedSections.Add(
            ("## Раздел {0}`r`n{1}" -f $i, ("Полезный контекст. " * 850))
        )
    }

    $original = $ownerPrefix +
        [Environment]::NewLine +
        ($managedSections -join [Environment]::NewLine) +
        [Environment]::NewLine +
        "<!-- AI_CONTEXT_END -->"

    $candidateParts = New-Object Collections.Generic.List[string]
    for ($i = 1; $i -le 6; $i++) {
        $candidateParts.Add(
            ("## Раздел {0}`r`n{1}" -f $i, ("Сохранённая важная информация. " * 260))
        )
    }

    $candidateManaged = $candidateParts -join [Environment]::NewLine
    $valid = Test-CompressedManagedContext `
        -OriginalContent $original `
        -CandidateManaged $candidateManaged

    if (-not $valid.Valid) {
        throw "Положительный compression self-test не пройден: $($valid.Message)"
    }

    $invalid = Test-CompressedManagedContext `
        -OriginalContent $original `
        -CandidateManaged "слишком коротко"

    if ($invalid.Valid) {
        throw "Отрицательный compression self-test не пройден."
    }

    return $true
}

function Invoke-ProjectContextCompression {
    $project = Get-ActiveProject
    if (-not $project) {
        Write-Warning "Сначала выберите проект."
        Pause-Brief
        return
    }

    $projectPath = [string]$project.path
    Ensure-ContextFiles -Path $projectPath

    $contextPath = Join-Path $projectPath "PROJECT_CONTEXT.md"
    $status = Get-ProjectContextStatus -Path $projectPath

    if (-not $status.Ready) {
        Write-Warning "Сначала создайте контекст через T."
        Pause-Brief
        return
    }

    if (-not $status.NeedsCompression) {
        Write-Host ""
        Write-Host ("Контекст занимает {0}." -f (Format-ContextCharacterCount -Characters $status.Length)) -ForegroundColor Green
        Write-Host "Сжатие пока не требуется." -ForegroundColor Green
        Pause-Brief
        return
    }

    $profile = Select-ProfileForContextCompression
    if (-not $profile) {
        return
    }

    if (-not (Test-ProfileAuth -Profile $profile)) {
        Write-Warning "Профиль '$($profile.name)' требует повторной авторизации."
        Write-Host "Откройте M → 3 и авторизуйте профиль заново." -ForegroundColor Yellow
        Pause-Brief
        return
    }

    Clear-Host
    Write-Title "Безопасное сжатие PROJECT_CONTEXT.md"

    Write-Host ("  Проект:      {0}" -f $project.name)
    Write-Host ("  Аккаунт:     {0}  @{1}" -f $profile.name, $profile.username)
    Write-Host ("  Размер:      {0}" -f (Format-ContextCharacterCount -Characters $status.Length))
    Write-Host "  Цель:        не более 100 тыс. знаков"
    Write-Host ""
    Write-Host "  Switcher выполнит один дополнительный headless-запрос GitLab Duo." -ForegroundColor Yellow
    Write-Host "  Исходный файл будет сохранён в резервную копию." -ForegroundColor Green
    Write-Host "  ИИ получит только управляемую часть контекста, без кода проекта" -ForegroundColor Green
    Write-Host "  и без раздела «Заметки владельца»." -ForegroundColor Green
    Write-Host "  Оригинал заменится только после автоматической проверки результата." -ForegroundColor Green
    Write-Host ""

    $confirm = Read-Host "Введите COMPRESS для запуска"
    if ($confirm -cne "COMPRESS") {
        Write-Host "Сжатие отменено." -ForegroundColor Yellow
        Pause-Brief
        return
    }

    $originalContent = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8
    $segments = Get-ContextSegments -Content $originalContent
    $backupPath = New-ContextBackup `
        -ProjectPath $projectPath `
        -ContextPath $contextPath

    $workRoot = Join-Path $Root "context-compression"
    $workDirectory = Join-Path $workRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workDirectory | Out-Null

    $managedPath = Join-Path $workDirectory "CONTEXT_TO_COMPRESS.md"
    $instructionPath = Join-Path $workDirectory "README_FIRST.txt"
    $logPath = Join-Path (Get-ContextBackupDirectory -ProjectPath $projectPath) "last-compression.log"
    $failedCandidatePath = Join-Path (Get-ContextBackupDirectory -ProjectPath $projectPath) "last-failed-candidate.md"

    Write-AtomicTextFile `
        -Path $managedPath `
        -Content ([string]$segments.Managed.Trim()) `
        -Encoding UTF8

    @"
This isolated folder contains only a copy of the AI-managed project context.
Do not inspect parent folders or any other location.
Edit only CONTEXT_TO_COMPRESS.md.
"@ | Set-Content -LiteralPath $instructionPath -Encoding UTF8

    $goal = @"
Работай только внутри текущей временной папки.

Твоя единственная задача: безопасно сжать файл CONTEXT_TO_COMPRESS.md.

Обязательные правила:
1. Прочитай только CONTEXT_TO_COMPRESS.md.
2. Не открывай родительские папки, другие диски, репозитории или пользовательские файлы.
3. Не создавай и не изменяй никакие файлы, кроме CONTEXT_TO_COMPRESS.md.
4. Сохрани все уникальные факты, версии, архитектурные решения, команды, ограничения, ошибки, незавершённую работу и инструкции следующему ИИ.
5. Удали повторы, устаревшие формулировки, длинные пересказы и несущественные детали.
6. Не добавляй факты, которых нет в исходном тексте.
7. Сохрани Markdown-структуру и понятные заголовки второго уровня.
8. Не добавляй маркеры AI_CONTEXT_BEGIN или AI_CONTEXT_END.
9. Итоговый файл должен быть от 2500 до 95000 символов.
10. Не пиши результат только в ответе: обязательно перезапиши CONTEXT_TO_COMPRESS.md.
11. Не запускай сборки, тесты, Git-команды и сетевые запросы.
12. После записи ответь только: CONTEXT_COMPRESSED
"@

    $glab = Ensure-Glab
    $oldPreference = $ErrorActionPreference
    $oldHooks = [string]$env:GITLAB_ENABLE_PROJECT_HOOKS
    $oldProjectDir = [string]$env:DUO_PROJECT_DIR
    $oldTranscript = [string]$env:SWITCHER_LOCAL_TRANSCRIPT_FILE
    $oldTranscriptEnabled = [string]$env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED
    $exitCode = -1
    $outputText = ""

    try {
        Set-ProfileEnvironment -Profile $profile
        $env:GITLAB_ENABLE_PROJECT_HOOKS = "false"
        Remove-Item Env:DUO_PROJECT_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:SWITCHER_LOCAL_TRANSCRIPT_FILE -ErrorAction SilentlyContinue
        $env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED = "false"

        $ErrorActionPreference = "Continue"
        Push-Location $workDirectory

        try {
            $output = @(
                & $glab duo cli `
                    --yes `
                    -C $workDirectory `
                    --model ([string]$profile.model) `
                    run `
                    --goal $goal `
                    --output-format text 2>&1
            )
            $exitCode = [int]$LASTEXITCODE
            $outputText = ($output | ForEach-Object {
                if ($_ -is [Management.Automation.ErrorRecord]) {
                    [string]$_.Exception.Message
                }
                else {
                    [string]$_
                }
            }) -join [Environment]::NewLine
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference

        if ([string]::IsNullOrWhiteSpace($oldHooks)) {
            Remove-Item Env:GITLAB_ENABLE_PROJECT_HOOKS -ErrorAction SilentlyContinue
        }
        else {
            $env:GITLAB_ENABLE_PROJECT_HOOKS = $oldHooks
        }

        if ([string]::IsNullOrWhiteSpace($oldProjectDir)) {
            Remove-Item Env:DUO_PROJECT_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:DUO_PROJECT_DIR = $oldProjectDir
        }

        if ([string]::IsNullOrWhiteSpace($oldTranscript)) {
            Remove-Item Env:SWITCHER_LOCAL_TRANSCRIPT_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:SWITCHER_LOCAL_TRANSCRIPT_FILE = $oldTranscript
        }

        if ([string]::IsNullOrWhiteSpace($oldTranscriptEnabled)) {
            Remove-Item Env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED -ErrorAction SilentlyContinue
        }
        else {
            $env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED = $oldTranscriptEnabled
        }
    }

    $logContent = @"
TIME: $(Get-Date -Format o)
PROJECT: $($project.name)
PROFILE: $($profile.name)
EXIT_CODE: $exitCode
ORIGINAL_LENGTH: $($originalContent.Length)
BACKUP: $backupPath

OUTPUT:
$outputText
"@

    Write-AtomicTextFile -Path $logPath -Content $logContent -Encoding UTF8

    try {
        if ($exitCode -ne 0) {
            throw "GitLab Duo завершил сжатие с кодом $exitCode."
        }

        if (-not (Test-Path -LiteralPath $managedPath)) {
            throw "GitLab Duo не создал итоговый файл."
        }

        $candidateManaged = Get-Content -LiteralPath $managedPath -Raw -Encoding UTF8
        $validation = Test-CompressedManagedContext `
            -OriginalContent $originalContent `
            -CandidateManaged $candidateManaged

        if (-not $validation.Valid) {
            Write-AtomicTextFile `
                -Path $failedCandidatePath `
                -Content ([string]$candidateManaged) `
                -Encoding UTF8

            throw $validation.Message
        }

        $currentContent = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8
        if (
            -not [string]::Equals(
                $currentContent,
                $originalContent,
                [StringComparison]::Ordinal
            )
        ) {
            throw "PROJECT_CONTEXT.md изменился во время сжатия. Результат не применён."
        }

        Write-AtomicTextFile `
            -Path $contextPath `
            -Content ([string]$validation.CandidateContent) `
            -Encoding UTF8

        $applied = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8
        $appliedValidation = Test-CompressedManagedContext `
            -OriginalContent $originalContent `
            -CandidateManaged (Get-ContextSegments -Content $applied).Managed

        if (-not $appliedValidation.Valid) {
            Copy-Item -LiteralPath $backupPath -Destination $contextPath -Force
            throw "Проверка после записи не пройдена. Оригинал восстановлен."
        }

        Remove-Item -LiteralPath $failedCandidatePath -Force -ErrorAction SilentlyContinue

        Clear-Host
        Write-Title "Контекст безопасно сжат"
        Write-Host ("  Было:  {0}" -f (Format-ContextCharacterCount -Characters $validation.OriginalLength))
        Write-Host ("  Стало: {0}" -f (Format-ContextCharacterCount -Characters $validation.CandidateLength)) -ForegroundColor Green
        Write-Host ("  Сжато: {0:0.0}%" -f ((1.0 - $validation.Ratio) * 100.0)) -ForegroundColor Green
        Write-Host ""
        Write-Host "  Резервная копия:" -ForegroundColor Cyan
        Write-Host "  $backupPath" -ForegroundColor DarkGray
    }
    catch {
        Clear-Host
        Write-Title "Сжатие не применено"
        Write-Host ("  Причина: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
        Write-Host "  Оригинальный PROJECT_CONTEXT.md не был заменён." -ForegroundColor Green
        Write-Host "  Резервная копия:" -ForegroundColor Cyan
        Write-Host "  $backupPath" -ForegroundColor DarkGray
        Write-Host "  Лог:" -ForegroundColor Cyan
        Write-Host "  $logPath" -ForegroundColor DarkGray
    }
    finally {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Pause-Brief
}

function New-ProjectContextPrompt {
    param($Project)

    $projectPath = [string]$Project.path
    $projectName = [string]$Project.name

    return @"
Ты работаешь локально в проекте:

Название: $projectName
Путь: $projectPath

Создай или качественно обнови единственный постоянный контекст проекта.

1. Сначала ничего не меняй в исходном коде.
2. Прочитай PROJECT_CONTEXT.md.
3. Изучи README, документацию, сборку, конфигурацию и структуру исходного кода.
4. Проверь git status, git diff --stat и последние коммиты.
5. Папку .gitlab/duo/legacy-context используй только как историческую подсказку.
6. Напрямую отредактируй PROJECT_CONTEXT.md.
7. Не удаляй раздел «Заметки владельца».
8. Замени только содержимое между:
   <!-- AI_CONTEXT_BEGIN -->
   <!-- AI_CONTEXT_END -->
9. Внутри создай компактный, но полный контекст:

   ## Назначение проекта
   ## Технологии и версии
   ## Архитектура и основные подсистемы
   ## Важные папки и файлы
   ## Команды сборки, запуска и тестирования
   ## Реализованные возможности
   ## Текущее состояние проекта
   ## Недавние важные изменения
   ## Незавершённая работа
   ## Известные ошибки, риски и технический долг
   ## Правила и соглашения проекта
   ## Рекомендуемые следующие шаги
   ## Инструкции следующему ИИ

10. Не создавай CURRENT_TASK.md, AI_HANDOFF.md или AI_CONTEXT_PACK.md.
11. Текущая задача всегда берётся из последнего сообщения пользователя.
12. Не копируй огромные файлы целиком.
13. Не сохраняй секреты, токены, ключи, cookies или OAuth-данные.
14. Не выдумывай факты.
15. После сохранения ответь только:

CONTEXT_SAVED: <одно предложение>

Изменения обязательно должны быть записаны в PROJECT_CONTEXT.md.
"@
}

function Copy-TextToClipboard {
    param([string]$Text)

    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text
            return $true
        }
    }
    catch {}

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($Text)
        return $true
    }
    catch {}

    try {
        $temporary = Join-Path $env:TEMP ("duo-context-{0}.txt" -f [guid]::NewGuid().ToString("N"))
        [IO.File]::WriteAllText(
            $temporary,
            $Text,
            (New-Object Text.UTF8Encoding($true))
        )
        cmd.exe /d /c "type `"$temporary`" | clip.exe" | Out-Null
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Start-ProjectContextWizard {
    $project = Get-ActiveProject
    if (-not $project) {
        $project = Select-Project -Heading "Выберите проект"
    }

    $projectPath = [string]$project.path
    Ensure-ContextFiles -Path $projectPath

    $contextFile = Join-Path $projectPath "PROJECT_CONTEXT.md"
    $promptFile = Join-Path (Join-Path $projectPath ".gitlab\duo") "PROJECT_CONTEXT_PROMPT.txt"
    $prompt = New-ProjectContextPrompt -Project $project

    $prompt | Set-Content -LiteralPath $promptFile -Encoding UTF8
    $copied = Copy-TextToClipboard -Text $prompt

    try {
        Start-Process notepad.exe -ArgumentList ("`"{0}`"" -f $contextFile)
    }
    catch {
        Write-Warning "Не удалось открыть PROJECT_CONTEXT.md автоматически."
    }

    Clear-Host
    Write-Title "Мастер контекста проекта"
    Write-Host "  Открыт файл:" -ForegroundColor White
    Write-Host "  $contextFile" -ForegroundColor DarkGray
    Write-Host ""

    if ($copied) {
        Write-Host "  ✓ Промпт скопирован в буфер обмена." -ForegroundColor Green
    }
    else {
        Write-Host "  ! Промпт сохранён здесь:" -ForegroundColor Yellow
        Write-Host "    $promptFile" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  1. Вернитесь в Hub."
    Write-Host "  2. Откройте любой профиль."
    Write-Host "  3. Нажмите Ctrl+V и отправьте промпт."
    Write-Host "  4. Дождитесь CONTEXT_SAVED."
    Write-Host "  5. Агент сам обновит PROJECT_CONTEXT.md."
    Write-Host ""
    Write-Host "  Отдельного файла текущей задачи больше нет." -ForegroundColor Green
    Write-Host "  Новую задачу просто пишите агенту сообщением." -ForegroundColor Green
    Pause-Brief
}

function Invoke-GitCapture {
    param(
        [string]$RepositoryPath,
        [string[]]$Arguments
    )

    $result = [pscustomobject][ordered]@{
        ExitCode = -1
        Output = @()
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $result.Output = @("git is not installed")
        return $result
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        # core.safecrlf=false prevents harmless LF/CRLF warnings from
        # becoming NativeCommandError records in Windows PowerShell 5.1.
        $nativeOutput = @(
            & git `
                -c core.safecrlf=false `
                -c core.quotepath=false `
                -C $RepositoryPath `
                @Arguments 2>&1
        )

        $result.ExitCode = [int]$LASTEXITCODE
        $result.Output = [object[]]@(
            $nativeOutput | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    [string]$_.Exception.Message
                }
                else {
                    [string]$_
                }
            }
        )
    }
    catch {
        # Git diagnostics are supplementary. They must never block Duo CLI.
        $result.ExitCode = -1
        $result.Output = @([string]$_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    return $result
}

function Save-GitSnapshot {
    param(
        [string]$Path,
        [string]$ProfileSlug
    )

    $dir = Join-Path $SnapshotsRoot $ProfileSlug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir ("{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("PROJECT: $Path")
    $lines.Add("TIME: $(Get-Date -Format o)")
    $lines.Add("")

    if (Get-Command git -ErrorAction SilentlyContinue) {
        foreach ($args in @(
            @("status", "--short"),
            @("diff", "--stat"),
            @("log", "-5", "--oneline")
        )) {
            $gitResult = Invoke-GitCapture `
                -RepositoryPath $Path `
                -Arguments ([string[]]$args)

            foreach ($gitLine in @($gitResult.Output)) {
                $lines.Add([string]$gitLine)
            }

            if ($gitResult.ExitCode -ne 0) {
                $lines.Add("[git exit code: $($gitResult.ExitCode)]")
            }

            $lines.Add("")
        }
    }

    $lines | Set-Content -Path $file -Encoding UTF8
}

function Invoke-GraphQL {
    param(
        $Profile,
        [string]$Query,
        [string]$Namespace
    )

    $glab = Ensure-Glab
    Set-ProfileEnvironment -Profile $Profile

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $raw = @(
            & $glab api graphql `
                --hostname gitlab.com `
                -f "query=$Query" `
                -F "namespacePath=$Namespace" 2>&1
        )
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()

    if ($code -ne 0) {
        throw $text
    }

    $result = $text | ConvertFrom-Json
    if ($result.errors) {
        $messages = @($result.errors | ForEach-Object { $_.message }) -join "; "
        throw $messages
    }

    return $result
}

function Get-UsageCacheFile {
    param($Profile)
    return (Join-Path $CacheRoot ("{0}.json" -f $Profile.slug))
}

function Save-UsageResult {
    param(
        $Profile,
        $Result
    )
    $Result | ConvertTo-Json -Depth 20 |
        Set-Content -Path (Get-UsageCacheFile -Profile $Profile) -Encoding UTF8
}

function Read-UsageResult {
    param(
        $Profile,
        [int]$MaxMinutes = 20
    )

    $file = Get-UsageCacheFile -Profile $Profile
    if (-not (Test-Path $file)) { return $null }

    try {
        $age = (Get-Date) - (Get-Item $file).LastWriteTime
        if ($age.TotalMinutes -gt $MaxMinutes) { return $null }

        return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-ProfileUsage {
    param(
        $Profile,
        [switch]$Refresh
    )

    if (-not $Refresh) {
        $cached = Read-UsageResult -Profile $Profile
        if ($cached) { return $cached }
    }

    $result = [pscustomobject][ordered]@{
        known = $false
        used = $null
        total = [double]$Profile.creditLimit
        remaining = $null
        status = "GitLab API не вернул usage"
        checkedAt = (Get-Date -Format o)
    }

    if ([string]::IsNullOrWhiteSpace([string]$Profile.namespace)) {
        $result.status = "namespace не настроен"
        Save-UsageResult -Profile $Profile -Result $result
        return $result
    }

    $query = @'
query Usage($namespacePath: ID) {
  subscriptionUsage(namespacePath: $namespacePath) {
    dailyUsage {
      date
      creditsUsed
    }
    monthlyWaiver {
      totalCredits
      creditsUsed
    }
    monthlyCommitment {
      totalCredits
      creditsUsed
    }
  }
}
'@

    try {
        $response = Invoke-GraphQL `
            -Profile $Profile `
            -Query $query `
            -Namespace ([string]$Profile.namespace)

        $usage = $response.data.subscriptionUsage
        if ($null -eq $usage) {
            throw "subscriptionUsage = null"
        }

        $used = 0.0
        $total = 0.0
        $poolFound = $false

        foreach ($poolName in @("monthlyWaiver", "monthlyCommitment")) {
            if (
                (Test-ObjectProperty -Object $usage -Name $poolName) -and
                $null -ne $usage.$poolName
            ) {
                $used += [double]$usage.$poolName.creditsUsed
                $total += [double]$usage.$poolName.totalCredits
                $poolFound = $true
            }
        }

        if (-not $poolFound) {
            foreach ($day in @($usage.dailyUsage)) {
                $used += [double]$day.creditsUsed
            }

            $total = [double]$Profile.creditLimit
        }

        if ($total -gt 0) {
            $result.known = $true
            $result.used = [math]::Round($used, 3)
            $result.total = [math]::Round($total, 3)
            $result.remaining = [math]::Round([math]::Max(0, $total - $used), 3)
            $result.status = "OK"
        }
    }
    catch {
        $result.status = [string]$_.Exception.Message
    }

    Save-UsageResult -Profile $Profile -Result $result
    return $result
}

function Format-Number {
    param($Value)
    if ($null -eq $Value) { return "—" }
    return ([string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        "{0:0.###}",
        [double]$Value
    ))
}

function Get-UsageBar {
    param(
        $Usage,
        [int]$Width = 16
    )

    if (-not $Usage.known) {
        return ("[" + ("·" * $Width) + "]")
    }

    $ratio = 0.0
    if ([double]$Usage.total -gt 0) {
        $ratio = [math]::Min(1, [math]::Max(0, [double]$Usage.used / [double]$Usage.total))
    }

    $filled = [int][math]::Round($ratio * $Width)
    return ("[" + ("█" * $filled) + ("░" * ($Width - $filled)) + "]")
}

function Show-AccountRows {
    param([switch]$Refresh)

    $config = Get-AppConfig
    $profiles = @($config.profiles)

    if ($profiles.Count -eq 0) {
        Write-Host "  Аккаунтов пока нет." -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $profile = $profiles[$i]
        $usage = Get-ProfileUsage -Profile $profile -Refresh:$Refresh
        $bar = Get-UsageBar -Usage $usage
        $usageText = if ($usage.known) {
            "{0} {1}/{2}  осталось {3}" -f
                $bar,
                (Format-Number $usage.used),
                (Format-Number $usage.total),
                (Format-Number $usage.remaining)
        }
        else {
            "{0} usage недоступен" -f $bar
        }

        Write-Host ("  {0}. {1}  @{2}" -f ($i + 1), $profile.name, $profile.username) -ForegroundColor White
        Write-Host ("     {0}  [{1}]" -f $usageText, $profile.namespace) -ForegroundColor DarkGray
    }
}

function Add-Profile {
    $config = Get-AppConfig
    [void](Select-Project -Heading "Проект для нового аккаунта")

    Write-Title "Добавление GitLab-аккаунта"

    $name = Read-Host "Название профиля, например Account-1 или Guest-Alex"
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Название профиля не может быть пустым."
    }

    $existingSaved = @($config.profiles | Where-Object { $_.name -eq $name } | Select-Object -First 1)
    if ($existingSaved.Count -gt 0) {
        throw "Профиль '$name' уже есть."
    }

    $slug = ($name.Trim() -replace '[<>:"/\\|?*\s]+', '_')
    $configDir = Join-Path (Join-Path $ProfilesRoot $slug) "glab-config"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    Repair-DirectoryPermissions -Path (Split-Path $configDir -Parent) -Quiet

    $profile = [pscustomobject][ordered]@{
        name = $name
        slug = $slug
        username = ""
        namespace = ""
        namespaceId = $null
        trialEndsOn = ""
        creditLimit = 24
        configDir = $configDir
        model = $DefaultModel
        createdAt = (Get-Date -Format o)
    }

    $storedUsername = Get-StoredUsername -Profile $profile

    if (-not [string]::IsNullOrWhiteSpace($storedUsername)) {
        Write-Host "Найдена сохранённая авторизация: @$storedUsername" -ForegroundColor Green
        $answer = Read-Host "Использовать её? [Y/n]"
        if ($answer -match '^(n|no|нет)$') {
            $glab = Ensure-Glab
            Set-ProfileEnvironment -Profile $profile
            & $glab auth logout --hostname gitlab.com | Out-Host
            $storedUsername = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($storedUsername)) {
        $storedUsername = Invoke-ProfileLogin -Profile $profile
    }

    $profile.username = $storedUsername
    [void](Choose-Namespace -Profile $profile)
    Install-Duo -Profile $profile

    $config = Get-AppConfig
    $config.profiles = @($config.profiles) + @($profile)
    Save-AppConfig -Config $config


    Write-Host ""
    Write-Host "Готово: $($profile.name) / @$($profile.username)" -ForegroundColor Green
    Pause-Brief
}

function Remove-LegacyProfileShortcuts {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) {
        return
    }

    foreach ($pattern in @(
        "GitLab Duo - *.lnk",
        "GitLab Duo CLI - *.lnk"
    )) {
        Get-ChildItem -LiteralPath $desktop -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "GitLab Duo CLI Hub.lnk" } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function New-HubShortcut {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $powershellExe = "powershell.exe"
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path $desktop "GitLab Duo CLI Hub.lnk"
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellExe
    $shortcut.Arguments = "-NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File `"$ThisScript`" -Action Hub"
    $shortcut.WorkingDirectory = Split-Path $ThisScript -Parent
    $shortcut.Description = "GitLab Duo CLI Switcher"
    $shortcut.Save()

    Write-Host "Создан один ярлык Hub:" -ForegroundColor Green
    Write-Host $shortcutPath -ForegroundColor DarkGray
}

function Invoke-DuoSession {
    param(
        [string]$Name,
        $Project
    )

    $script:LastSessionResult = $null
    $profile = Get-Profile -Name $Name
    $glab = Ensure-Glab

    Repair-DirectoryPermissions -Path (Split-Path ([string]$profile.configDir) -Parent) -Quiet

    if (-not (Test-ProfileAuth -Profile $profile)) {
        Write-Warning "Авторизация профиля потеряна."
        $username = Invoke-ProfileLogin -Profile $profile

        $config = Get-AppConfig
        foreach ($item in @($config.profiles)) {
            if ($item.name -eq $profile.name) {
                $item.username = $username
            }
        }
        Save-AppConfig -Config $config
        $profile = Get-Profile -Name $Name
    }

    $projectPath = [string]$Project.path
    $state = Initialize-ChatBridge -ProjectPath $projectPath
    $recorderEnabled = Get-LocalRecorderEnabled
    $rawDiagnostics = Get-RecorderRawDiagnosticsEnabled
    $env:SWITCHER_LOCAL_TRANSCRIPT_FILE = [string]$state.BridgePath
    $env:SWITCHER_LOCAL_TRANSCRIPT_ENABLED = if ($recorderEnabled) { "true" } else { "false" }

    try {
        Ensure-ContextFiles -Path $projectPath
    }
    catch {
        Write-Warning "Не удалось подготовить context-файлы: $($_.Exception.Message)"
    }

    try {
        Save-GitSnapshot -Path $projectPath -ProfileSlug ([string]$profile.slug)
    }
    catch {
        Write-Warning "Не удалось сохранить Git-снимок. Duo всё равно будет запущен."
    }

    Set-ProfileEnvironment -Profile $profile

    $memoryDelivery = $null
    try {
        $memoryDelivery = Set-ProfileAgentsMemory `
            -Profile $profile `
            -ProjectPath $projectPath `
            -ProjectName ([string]$Project.name) `
            -BridgePath ([string]$state.BridgePath) `
            -Enabled $recorderEnabled
    }
    catch {
        Write-Warning "Не удалось подготовить AGENTS.md для переноса: $($_.Exception.Message)"
        $memoryDelivery = [pscustomobject][ordered]@{
            Ready = $false
            Path = ""
            Characters = 0
            Text = "ошибка AGENTS.md; остаётся project hook"
        }
    }

    $usage = Get-ProfileUsage -Profile $profile
    $remainingTitle = if ($usage.known) {
        " | left $(Format-Number $usage.remaining)"
    }
    else {
        ""
    }

    try {
        $Host.UI.RawUI.WindowTitle = "$AppName | $Name | $($Project.name)$remainingTitle"
    }
    catch {}

    Clear-Host
    Write-Title "$Name  →  $($Project.name)"
    Write-Host "  GitLab:    @$($profile.username)" -ForegroundColor White
    Write-Host "  Namespace: $($profile.namespace)" -ForegroundColor White
    Write-Host "  Model:     $($profile.model)" -ForegroundColor White
    Write-Host "  Folder:    $projectPath" -ForegroundColor White

    if (Get-AutoApproveTools) {
        Write-Host "  Approvals: AUTO — без вопросов" -ForegroundColor Red
    }
    else {
        Write-Host "  Approvals: ASK — с подтверждениями" -ForegroundColor Green
    }

    if ($recorderEnabled) {
        Write-Host "  Memory:    компактный transcript + автоперенос" -ForegroundColor Cyan

        if ($memoryDelivery -and $memoryDelivery.Ready) {
            Write-Host ("  Delivery:  {0}, {1} знаков" -f
                $memoryDelivery.Text,
                (Format-Number ([long]$memoryDelivery.Characters))
            ) -ForegroundColor Green
        }
        else {
            Write-Host ("  Delivery:  {0}" -f
                $(if ($memoryDelivery) { $memoryDelivery.Text } else { "project hook" })
            ) -ForegroundColor Yellow
        }

        Write-Host "  Reality:   это transcript видимого терминала, не копия серверного чата" -ForegroundColor DarkGray
        Write-Host ("  Privacy:   сырые VT-логи {0}" -f $(if ($rawDiagnostics) { "ВКЛЮЧЕНЫ" } else { "выключены" })) `
            -ForegroundColor $(if ($rawDiagnostics) { "Yellow" } else { "Green" })
    }
    else {
        Write-Host "  Memory:    локальная запись выключена" -ForegroundColor DarkGray
    }

    if ($usage.known) {
        Write-Host ("  Usage:     {0} {1}/{2}, осталось {3}" -f
            (Get-UsageBar -Usage $usage),
            (Format-Number $usage.used),
            (Format-Number $usage.total),
            (Format-Number $usage.remaining)
        ) -ForegroundColor Yellow
    }
    else {
        Write-Host "  Usage:     GitLab API не отдал данные" -ForegroundColor DarkYellow
    }

    Write-Host ""
    Write-Host "  /exit — вернуться в Hub   /sessions — серверные чаты этого аккаунта" -ForegroundColor DarkGray
    Write-Host "  Tab — Plan/Build          /model — модель" -ForegroundColor DarkGray
    Write-Rule
    Write-Host ""

    $duoArguments = @(
        "duo",
        "cli",
        "--yes",
        "--model",
        ([string]$profile.model),
        "--enable-project-hooks",
        "-C",
        $projectPath
    )

    $exitCode = 0
    $captureSucceeded = $false
    $oldPreference = $ErrorActionPreference
    Push-Location $projectPath

    try {
        $ErrorActionPreference = "Continue"

        if ($recorderEnabled) {
            $runStatusPath = Join-Path $state.Directory ("recorder-run-{0}.status" -f [guid]::NewGuid().ToString("N"))
            $childStarted = $false

            try {
                $recorder = Ensure-DuoTerminalRecorder
                [void](Test-DuoTerminalRecorderRuntime -RecorderPath $recorder)

                $bridgeBefore = if (Test-Path -LiteralPath $state.BridgePath) {
                    (Get-Item -LiteralPath $state.BridgePath).LastWriteTimeUtc
                }
                else {
                    [datetime]::MinValue
                }

                $recorderArguments = @(
                    "--log-root", ([string]$state.LogsDirectory),
                    "--bridge", ([string]$state.BridgePath),
                    "--working-dir", $projectPath,
                    "--profile", ([string]$profile.name),
                    "--username", ([string]$profile.username),
                    "--model", ([string]$profile.model),
                    "--project-name", ([string]$Project.name),
                    "--run-status", $runStatusPath,
                    "--raw-logs", ([string]$rawDiagnostics).ToLowerInvariant(),
                    "--present-output", "true",
                    "--forward-input", "true",
                    "--max-sessions", "25",
                    "--max-storage-mb", "300",
                    "--",
                    $glab
                ) + $duoArguments

                & $recorder @recorderArguments
                $exitCode = [int]$LASTEXITCODE

                $runStatus = Read-KeyValueFile -Path $runStatusPath
                if ($runStatus) {
                    $childStarted = [string]$runStatus.childStarted -eq "true"
                    $captureSucceeded = [string]$runStatus.transcriptUpdated -eq "true"
                }
                else {
                    # Не запускаем Duo второй раз при неопределённом статусе:
                    # рекордер мог уже завершить настоящую сессию, но не суметь записать status.
                    $childStarted = $exitCode -notin @(210, 211)
                }

                if (-not $childStarted -and $exitCode -in @(210, 211)) {
                    throw "ConPTY-рекордер завершился до запуска GitLab Duo."
                }

                if (-not $captureSucceeded -and (Test-Path -LiteralPath $state.BridgePath)) {
                    $bridgeAfter = (Get-Item -LiteralPath $state.BridgePath).LastWriteTimeUtc
                    $captureSucceeded = $bridgeAfter -gt $bridgeBefore
                }
            }
            catch {
                if (-not $childStarted) {
                    Write-Warning "Локальная запись недоступна: $($_.Exception.Message)"
                    Write-Warning "Запускаю GitLab Duo напрямую. Работа не блокируется."
                    & $glab @duoArguments
                    $exitCode = [int]$LASTEXITCODE
                }
                else {
                    Write-Warning "Duo уже запускался через рекордер, но transcript сохранить не удалось."
                }
            }
            finally {
                Remove-Item -LiteralPath $runStatusPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            & $glab @duoArguments
            $exitCode = [int]$LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }

    if ($recorderEnabled -and $captureSucceeded) {
        $updatedMemory = Get-LocalMemoryHealth -ProjectPath $projectPath
        Write-Host ("  Компактная память обновлена: {0}" -f $updatedMemory.Text) -ForegroundColor Green
    }
    elseif ($recorderEnabled) {
        Write-Warning "Transcript не обновился. Подробности: $($state.LogsDirectory)"
    }

    $script:LastSessionResult = [pscustomobject][ordered]@{
        ProfileName = $Name
        ProjectPath = $projectPath
        ExitCode = [int]$exitCode
        TranscriptCaptured = [bool]$captureSucceeded
    }
}

function Get-NextProfileName {
    param([string]$CurrentName)

    $profiles = @((Get-AppConfig).profiles)
    if ($profiles.Count -lt 2) { return "" }

    $index = 0
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ($profiles[$i].name -eq $CurrentName) {
            $index = $i
            break
        }
    }

    return [string]$profiles[(($index + 1) % $profiles.Count)].name
}

function Edit-CurrentTask {
    Start-ProjectContextWizard
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Host
        Write-Title "Настройки"

        $autoApprove = Get-AutoApproveTools
        $recorderEnabled = Get-LocalRecorderEnabled
        $rawDiagnostics = Get-RecorderRawDiagnosticsEnabled
        $project = Get-ActiveProject

        Write-Host ("  1. Автоподтверждение инструментов: {0}" -f `
            $(if ($autoApprove) { "ВКЛЮЧЕНО" } else { "ВЫКЛЮЧЕНО" })) `
            -ForegroundColor $(if ($autoApprove) { "Red" } else { "Green" })

        Write-Host ("  2. Локальный перенос видимого диалога: {0}" -f `
            $(if ($recorderEnabled) { "ВКЛЮЧЕН" } else { "ВЫКЛЮЧЕН" })) `
            -ForegroundColor $(if ($recorderEnabled) { "Green" } else { "DarkGray" })

        Write-Host ("  3. Сырые диагностические VT-логи: {0}" -f `
            $(if ($rawDiagnostics) { "ВКЛЮЧЕНЫ" } else { "ВЫКЛЮЧЕНЫ" })) `
            -ForegroundColor $(if ($rawDiagnostics) { "Yellow" } else { "Green" })

        Write-Host "  4. Открыть transcript текущего проекта"
        Write-Host "  5. Открыть папку записей текущего проекта"
        Write-Host "  6. Очистить локальную историю текущего проекта"
        Write-Host "  7. Проверить и пересобрать рекордер"
        Write-Host ""
        Write-Host "  Серверные чаты разных GitLab-аккаунтов не объединяются." -ForegroundColor DarkGray
        Write-Host "  По умолчанию сохраняются только очищенные transcript и snapshots." -ForegroundColor DarkGray
        Write-Host "  Сырые VT-логи могут содержать секреты, поэтому по умолчанию выключены." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  0. Назад"

        $choice = Read-Host "Выбор"

        switch ($choice) {
            "0" { return }
            "1" {
                if ($autoApprove) {
                    Set-AutoApproveTools -Enabled $false
                    Write-Host "Автоподтверждение выключено." -ForegroundColor Green
                    Pause-Brief
                    continue
                }

                Clear-Host
                Write-Title "Опасный режим"
                Write-Host "GitLab Duo сможет без вопросов изменять файлы и выполнять команды." -ForegroundColor Yellow
                Write-Host "Включайте только для доверенного проекта." -ForegroundColor Red
                $confirm = Read-Host "Введите AUTO для включения"

                if ($confirm -ceq "AUTO") {
                    Set-AutoApproveTools -Enabled $true
                    Write-Host "Автоподтверждение включено." -ForegroundColor Red
                }
                else {
                    Write-Host "Изменение отменено." -ForegroundColor Yellow
                }
                Pause-Brief
            }
            "2" {
                Set-LocalRecorderEnabled -Enabled (-not $recorderEnabled)
                Write-Host ("Локальный перенос: {0}" -f $(if (-not $recorderEnabled) { "включён" } else { "выключен" }))
                Pause-Brief
            }
            "3" {
                if ($rawDiagnostics) {
                    Set-RecorderRawDiagnosticsEnabled -Enabled $false
                    Write-Host "Сырые VT-логи выключены." -ForegroundColor Green
                }
                else {
                    Clear-Host
                    Write-Title "Сырые диагностические логи"
                    Write-Host "Они могут содержать вставленные токены, команды и полный вывод терминала." -ForegroundColor Yellow
                    $confirm = Read-Host "Введите RAW для включения"
                    if ($confirm -ceq "RAW") {
                        Set-RecorderRawDiagnosticsEnabled -Enabled $true
                        Write-Host "Сырые VT-логи включены." -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "Изменение отменено." -ForegroundColor Green
                    }
                }
                Pause-Brief
            }
            "4" {
                if (-not $project) {
                    Write-Warning "Сначала выберите проект."
                    Pause-Brief
                    continue
                }

                $state = Initialize-ChatBridge -ProjectPath ([string]$project.path)
                Start-Process notepad.exe -ArgumentList ("`"{0}`"" -f $state.BridgePath)
            }
            "5" {
                if (-not $project) {
                    Write-Warning "Сначала выберите проект."
                    Pause-Brief
                    continue
                }

                $state = Get-ProjectStateInfo -ProjectPath ([string]$project.path)
                Start-Process explorer.exe -ArgumentList ("`"{0}`"" -f $state.LogsDirectory)
            }
            "6" {
                if (-not $project) {
                    Write-Warning "Сначала выберите проект."
                    Pause-Brief
                    continue
                }

                $confirm = Read-Host "Введите CLEAR для удаления локальной истории проекта"
                if ($confirm -ceq "CLEAR") {
                    Reset-ChatBridge -ProjectPath ([string]$project.path)
                    Write-Host "Локальная история очищена." -ForegroundColor Green
                }
                else {
                    Write-Host "Очистка отменена." -ForegroundColor Yellow
                }
                Pause-Brief
            }
            "7" {
                try {
                    $path = Ensure-DuoTerminalRecorder -ForceRebuild
                    [void](Test-DuoTerminalRecorderRuntime -RecorderPath $path -Force)
                    Write-Host "Рекордер собран и прошёл полный runtime probe." -ForegroundColor Green
                }
                catch {
                    Write-Warning $_.Exception.Message
                }
                Pause-Brief
            }
        }
    }
}

function Show-ManagementMenu {
    while ($true) {
        Clear-Host
        Write-Title "Управление"
        Write-Host "  1. Добавить аккаунт"
        Write-Host "  2. Удалить аккаунт"
        Write-Host "  3. Повторная авторизация"
        Write-Host "  4. Проекты: добавить / удалить"
        Write-Host "  5. Обновить glab и Duo CLI"
        Write-Host "  6. Диагностика"
        Write-Host "  7. Исправить права профилей"
        Write-Host "  8. Открыть папку данных"
        Write-Host "  9. Создать один ярлык Hub"
        Write-Host "  0. Назад"

        $choice = Read-Host "Выбор"

        try {
            switch ($choice) {
                "1" { Add-Profile }
                "2" { Remove-Profile }
                "3" { Reauthenticate-Profile }
                "4" { Manage-Projects }
                "5" { Update-Tools }
                "6" { Invoke-Doctor; Pause-Brief }
                "7" { Repair-AllProfilePermissions; Pause-Brief }
                "8" { Start-Process explorer.exe -ArgumentList "`"$Root`"" }
                "9" { New-HubShortcut; Pause-Brief }
                "0" { return }
            }
        }
        catch {
            Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
            Pause-Brief
        }
    }
}

function Remove-Profile {
    $config = Get-AppConfig
    $profiles = @($config.profiles)
    if ($profiles.Count -eq 0) { return }

    Write-Title "Удаление аккаунта"
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host ("  {0}. {1}  @{2}" -f ($i + 1), $profiles[$i].name, $profiles[$i].username)
    }

    $choice = Read-Host "Номер или Enter для отмены"
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) { return }
    if ($index -lt 1 -or $index -gt $profiles.Count) { return }

    $profile = $profiles[$index - 1]
    $confirm = Read-Host "Введите DELETE для удаления '$($profile.name)'"
    if ($confirm -ne "DELETE") { return }

    $folder = Split-Path ([string]$profile.configDir) -Parent
    if (Test-Path $folder) {
        Remove-Item $folder -Recurse -Force
    }

    $config.profiles = @($config.profiles | Where-Object { $_.name -ne $profile.name })
    Save-AppConfig -Config $config
}

function Reauthenticate-Profile {
    $config = Get-AppConfig
    $profiles = @($config.profiles)
    if ($profiles.Count -eq 0) { return }

    Write-Title "Повторная авторизация"
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host ("  {0}. {1}  @{2}" -f ($i + 1), $profiles[$i].name, $profiles[$i].username)
    }

    $choice = Read-Host "Номер"
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) { return }
    if ($index -lt 1 -or $index -gt $profiles.Count) { return }

    $profile = $profiles[$index - 1]
    $glab = Ensure-Glab
    Set-ProfileEnvironment -Profile $profile
    & $glab auth logout --hostname gitlab.com | Out-Host
    $username = Invoke-ProfileLogin -Profile $profile

    foreach ($item in @($config.profiles)) {
        if ($item.name -eq $profile.name) {
            $item.username = $username
            $item.namespace = ""
            [void](Choose-Namespace -Profile $item)
        }
    }

    Save-AppConfig -Config $config
}

function Manage-Projects {
    while ($true) {
        $config = Get-AppConfig
        $projects = @($config.projects)
        $active = Get-ActiveProject

        Clear-Host
        Write-Title "Проекты"

        for ($i = 0; $i -lt $projects.Count; $i++) {
            $mark = if ($active -and $active.id -eq $projects[$i].id) { "●" } else { " " }
            Write-Host ("  {0} {1}. {2}" -f $mark, ($i + 1), $projects[$i].name)
            Write-Host ("      {0}" -f $projects[$i].path) -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  A — добавить путь"
        Write-Host "  D — удалить путь"
        Write-Host "  0 — назад"

        $choice = Read-Host "Выбор"

        if ($choice -eq "0") { return }

        if ($choice -match '^(a|add)$') {
            $path = Read-Host "Полный путь"
            try {
                [void](Add-ProjectPath -Path $path)
            }
            catch {
                Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
                Pause-Brief
            }
            continue
        }

        if ($choice -match '^(d|delete)$') {
            $number = Read-Host "Номер проекта"
            $index = 0
            if (
                [int]::TryParse($number, [ref]$index) -and
                $index -ge 1 -and
                $index -le $projects.Count
            ) {
                $target = $projects[$index - 1]
                $config.projects = @($config.projects | Where-Object { $_.id -ne $target.id })

                if ($config.activeProjectId -eq $target.id) {
                    $config.activeProjectId = if (@($config.projects).Count -gt 0) {
                        [string]$config.projects[0].id
                    }
                    else {
                        ""
                    }
                }

                Save-AppConfig -Config $config
            }
        }
    }
}

function Update-Tools {
    $glab = Ensure-Glab
    $config = Get-AppConfig
    if (@($config.profiles).Count -gt 0) {
        $profile = $config.profiles[0]
        Set-ProfileEnvironment -Profile $profile
        & $glab duo cli --update | Out-Host
    }
}

function Invoke-Doctor {
    Write-Title "Диагностика"

    $glab = Ensure-Glab
    $build = Get-WindowsBuildNumber

    Write-Host "  Switcher:       $AppVersion"
    Write-Host "  Windows build:  $build"
    Write-Host "  glab:           $glab"
    Write-Host "  Config:         $ConfigPath"
    Write-Host ("  Local recorder: {0}" -f (Get-LocalRecorderEnabled))
    Write-Host ("  Raw VT logs:    {0}" -f (Get-RecorderRawDiagnosticsEnabled))
    Write-Host "  Recorder source: $RecorderSourcePath"
    Write-Host "  Recorder exe:    $RecorderExePath"
    Write-Host "  Context soft limit: $ContextSoftLimitCharacters"
    Write-Host "  Context hard limit: $ContextHardLimitCharacters"

    try {
        [void](Test-ContextCompressionLogic)
        Write-Host "  Context validator: OK" -ForegroundColor Green
    }
    catch {
        Write-Host "  Context validator: FAIL" -ForegroundColor Red
        Write-Host ("                     {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
    }

    try {
        $recorder = Ensure-DuoTerminalRecorder -Quiet
        Write-Host "  Build/self-test: OK" -ForegroundColor Green

        [void](Test-DuoTerminalRecorderRuntime -RecorderPath $recorder -Force)
        Write-Host "  ConPTY runtime:  OK" -ForegroundColor Green
    }
    catch {
        Write-Host "  Recorder check:  FAIL" -ForegroundColor Red
        Write-Host ("                   {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        Write-Host "  GitLab Duo всё равно сможет запускаться напрямую без записи." -ForegroundColor Yellow
    }

    $project = Get-ActiveProject
    if ($project) {
        Write-Host ""
        Write-Host ("  Active project:  {0}" -f $project.path)

        $memoryHealth = Get-LocalMemoryHealth -ProjectPath ([string]$project.path)
        Write-Host ("  Memory schema:   {0}" -f $memoryHealth.Schema)
        Write-Host ("  Memory size:     {0}" -f (Format-Number ([long]$memoryHealth.Characters)))
        Write-Host ("  Memory sessions: {0}" -f $memoryHealth.Sessions)

        try {
            Ensure-ContextFiles -Path ([string]$project.path)
            Write-Host "  Project hook:    OK" -ForegroundColor Green
        }
        catch {
            Write-Host "  Project hook:    FAIL" -ForegroundColor Red
            Write-Host ("                   {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        }
    }

    foreach ($profile in @((Get-AppConfig).profiles)) {
        $auth = if (Test-ProfileAuth -Profile $profile) { "OK" } else { "LOGIN REQUIRED" }
        Write-Host ""
        Write-Host ("  [{0}] {1}" -f $profile.name, $auth)
        Write-Host ("     @{0} / {1}" -f $profile.username, $profile.namespace)
        Write-Host ("     {0}" -f $profile.configDir) -ForegroundColor DarkGray
    }
}

function Show-Hub {
    param([string]$InitialProfile = "")

    $nextProfile = $InitialProfile

    while ($true) {
        $project = Get-ActiveProject
        if (-not $project) {
            $project = Select-Project -Heading "Первичная настройка проекта"
        }

        if (-not [string]::IsNullOrWhiteSpace($nextProfile)) {
            Invoke-DuoSession -Name $nextProfile -Project $project
            $result = $script:LastSessionResult
            $nextProfile = ""

            if ($result -and $result.ExitCode -ne 0) {
                $candidate = Get-NextProfileName -CurrentName $result.ProfileName

                Write-Host ""
                Write-Warning "CLI завершился с кодом $($result.ExitCode). Можно открыть следующий аккаунт."

                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $answer = Read-Host "Enter — открыть следующий аккаунт '$candidate'; N — Hub"
                    if ($answer -notmatch '^(n|no|нет)$') {
                        $nextProfile = $candidate
                        continue
                    }
                }
            }
        }

        Clear-Host
        $config = Get-AppConfig
        $project = Get-ActiveProject

        Write-Title "$AppName  v$AppVersion"
        Write-Host ("  Проект:   {0}" -f $project.name) -ForegroundColor White
        Write-Host ("  Папка:    {0}" -f $project.path) -ForegroundColor DarkGray

        if (Get-AutoApproveTools) {
            Write-Host "  Команды:  без подтверждений" -ForegroundColor Red
        }
        else {
            Write-Host "  Команды:  с подтверждением" -ForegroundColor Green
        }

        $recorderText = if (Get-LocalRecorderEnabled) { "компактный transcript включён" } else { "transcript выключен" }
        Write-Host ("  Диалоги:  {0}" -f $recorderText) -ForegroundColor Cyan

        if (Get-LocalRecorderEnabled) {
            $memoryHealth = Get-LocalMemoryHealth -ProjectPath ([string]$project.path)
            Write-Host ("  Память:   {0}" -f $memoryHealth.Text) `
                -ForegroundColor $(if ($memoryHealth.Ready) { "Green" } else { "DarkGray" })
        }

        if (Get-RecorderRawDiagnosticsEnabled) {
            Write-Host "  Privacy:   сырые VT-логи включены" -ForegroundColor Yellow
        }

        $contextStatus = $null
        try {
            Ensure-ContextFiles -Path ([string]$project.path)
            $contextStatus = Get-ProjectContextStatus -Path ([string]$project.path)

            if ($contextStatus.State -eq "ok") {
                Write-Host ("  Контекст: {0}" -f $contextStatus.Text) -ForegroundColor Green
            }
            elseif ($contextStatus.State -eq "hard") {
                Write-Host ("  Контекст: {0}" -f $contextStatus.Text) -ForegroundColor Red
            }
            else {
                Write-Host ("  Контекст: {0}" -f $contextStatus.Text) -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  Контекст: не удалось проверить" -ForegroundColor Yellow
        }

        Write-Host ""
        Show-AccountRows
        Write-Host ""
        Write-Rule
        Write-Host "  [номер] Запустить аккаунт   [A] Добавить аккаунт" -ForegroundColor Cyan
        Write-Host "  [P]   Выбрать проект       [T] Контекст проекта" -ForegroundColor Cyan

        if ($contextStatus -and $contextStatus.NeedsCompression) {
            Write-Host "  [C]   Безопасно сжать контекст" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [C]   Проверить размер контекста" -ForegroundColor DarkGray
        }

        Write-Host "  [S]   Настройки            [M] Управление" -ForegroundColor Cyan
        Write-Host "  [U]   Обновить usage       [Q] Выход" -ForegroundColor Cyan
        Write-Rule

        $choice = Read-Host "Команда"

        if ($choice -match '^(q|quit|выход)$') { return }
        if ($choice -match '^(a|add)$') {
            try { Add-Profile } catch {
                Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
                Pause-Brief
            }
            continue
        }
        if ($choice -match '^(p|project)$') {
            [void](Select-Project -Heading "Смена проекта" -AllowCancel)
            continue
        }
        if ($choice -match '^(t|task)$') {
            Edit-CurrentTask
            continue
        }
        if ($choice -match '^(c|compress|сжать)$') {
            Invoke-ProjectContextCompression
            continue
        }
        if ($choice -match '^(s|settings|настройки)$') {
            Show-SettingsMenu
            continue
        }
        if ($choice -match '^(u|usage)$') {
            Clear-Host
            Write-Title "Обновление usage"
            Show-AccountRows -Refresh
            Write-Host ""
            Write-Host "GitLab обновляет usage не в реальном времени." -ForegroundColor DarkGray
            Pause-Brief
            continue
        }
        if ($choice -match '^(m|manage)$') {
            Show-ManagementMenu
            continue
        }

        $index = 0
        $profiles = @($config.profiles)
        if (
            [int]::TryParse($choice, [ref]$index) -and
            $index -ge 1 -and
            $index -le $profiles.Count
        ) {
            $nextProfile = [string]$profiles[$index - 1].name
        }
    }
}

try {
    # Windows PowerShell 5.1 runtime compatibility smoke test.
    $smokeConfig = [pscustomobject]@{ projects = @() }
    $smokeProjects = @(
        [pscustomobject]@{
            id = "smoke"
            name = "smoke"
            path = $Root
            lastUsedAt = ""
        }
    )
    $smokeConfig.projects = [object[]]@(
        $smokeProjects | ForEach-Object { $_ }
    )
    [void]($smokeConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json)

    Initialize-App

    switch ($Action) {
        "AddProfile" { Add-Profile }
        "Repair" {
            Repair-AllProfilePermissions
            Pause-Brief
        }
        "Doctor" {
            Invoke-Doctor
            Pause-Brief
        }
        "Shortcut" {
            New-HubShortcut
            Pause-Brief
        }
        default {
            Show-Hub -InitialProfile $ProfileName
        }
    }

    exit 0
}
catch {
    try {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        $logPath = Join-Path $Root "crash.log"

        @(
            "TIME: $(Get-Date -Format o)"
            "VERSION: $AppVersion"
            "ACTION: $Action"
            "MESSAGE: $($_.Exception.Message)"
            "TYPE: $($_.Exception.GetType().FullName)"
            ""
            "SCRIPT STACK:"
            $_.ScriptStackTrace
            ""
            "FULL ERROR:"
            ($_ | Out-String)
            ""
            ("=" * 80)
        ) | Add-Content -Path $logPath -Encoding UTF8
    }
    catch {
        $logPath = "(не удалось создать лог)"
    }

    Write-Host ""
    Write-Host "GitLab Duo CLI Switcher завершился с ошибкой." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Лог: $logPath" -ForegroundColor DarkGray
    Write-Host ""
    [void](Read-Host "Enter — закрыть окно")
    exit 1
}
