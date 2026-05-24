<#
.SYNOPSIS
    Installiert den Dauer-Monitor (Start-JtlMonitor.ps1) als Aufgabenplaner-
    Aufgabe unter SYSTEM, sodass er beim Server-Start automatisch laeuft,
    Logoffs ueberlebt und bei Fehlern neu startet.

.DESCRIPTION
    - Trigger      : beim Systemstart, sofort
    - Konto        : SYSTEM (laeuft auch ohne angemeldeten Benutzer)
    - Ausfuehrung  : unbegrenzt, nicht stoppen bei Leerlauf
    - Selbstheilung: bei Fehlschlag automatischer Neustart der Aufgabe
    - Idempotent   : erneutes Ausfuehren ueberschreibt die Aufgabe.

.PARAMETER InstallDir
    Zielordner, in den die Monitor-Skripte kopiert werden. Standard:
    C:\JTL-Wartung. So liegt der Monitor stabil unabhaengig vom Repo-Ort.

.PARAMETER OutputPath
    Ordner fuer die CSV-Dateien des Monitors. Standard: <InstallDir>\monitor

.PARAMETER IntervalSeconds
    An den Monitor durchgereicht. Standard 60.

.PARAMETER TopProcessCount
    An den Monitor durchgereicht. Standard 10.

.PARAMETER SqlInstance
    Optional. Wird durchgereicht; weglassen, wenn kein lokales SQL vorhanden.

.PARAMETER RetentionDays
    An den Monitor durchgereicht. Standard 14.

.EXAMPLE
    .\Register-JtlMonitorTask.ps1
.EXAMPLE
    .\Register-JtlMonitorTask.ps1 -SqlInstance ".\JTLWAWI" -IntervalSeconds 30

.NOTES
    Als Administrator ausfuehren.
    Pruefen :  Get-ScheduledTask -TaskName JTL_Monitor
    Stoppen :  Stop-ScheduledTask -TaskName JTL_Monitor
    Starten :  Start-ScheduledTask -TaskName JTL_Monitor
    Entfernen: Unregister-ScheduledTask -TaskName JTL_Monitor -Confirm:$false
#>
[CmdletBinding()]
param(
    [string]$InstallDir      = 'C:\JTL-Wartung',
    [string]$OutputPath,
    [int]$IntervalSeconds    = 60,
    [int]$TopProcessCount    = 10,
    [string]$SqlInstance,
    [int]$RetentionDays      = 14
)

$ErrorActionPreference = 'Stop'
$taskName = 'JTL_Monitor'

# --- Skript kopieren, damit es stabil unter $InstallDir liegt -----------------
if (-not (Test-Path $InstallDir))   { New-Item -ItemType Directory -Path $InstallDir   -Force | Out-Null }
if (-not $OutputPath)               { $OutputPath = Join-Path $InstallDir 'monitor' }
if (-not (Test-Path $OutputPath))   { New-Item -ItemType Directory -Path $OutputPath   -Force | Out-Null }

$srcScript = Join-Path $PSScriptRoot 'Start-JtlMonitor.ps1'
if (-not (Test-Path $srcScript)) {
    throw "Start-JtlMonitor.ps1 wurde neben diesem Skript nicht gefunden ($srcScript)."
}
$dstScript = Join-Path $InstallDir 'Start-JtlMonitor.ps1'
Copy-Item $srcScript -Destination $dstScript -Force
Write-Host "Monitor-Skript kopiert nach $dstScript" -ForegroundColor DarkGray

# --- Argumente fuer die Aufgabe zusammensetzen --------------------------------
$argList = @(
    '-ExecutionPolicy', 'Bypass',
    '-NonInteractive',
    '-WindowStyle', 'Hidden',
    '-File', "`"$dstScript`"",
    '-OutputPath', "`"$OutputPath`"",
    '-IntervalSeconds', $IntervalSeconds,
    '-TopProcessCount', $TopProcessCount,
    '-RetentionDays', $RetentionDays
)
if ($SqlInstance) { $argList += @('-SqlInstance', "`"$SqlInstance`"") }

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Unbegrenzte Laufzeit, nicht bei Leerlauf stoppen, bei Fehler neu starten
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -DontStopOnIdleEnd `
                -StartWhenAvailable `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)   # keine Laufzeit-Begrenzung

# --- Registrieren -------------------------------------------------------------
Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Dauer-Monitor: CPU/RAM/Disk/Netz/Top-Prozesse$(if($SqlInstance){' + SQL'}) - CSV in $OutputPath." `
    -Force | Out-Null

Write-Host "Aufgabe '$taskName' registriert." -ForegroundColor Green
Write-Host ("  Skript    : {0}" -f $dstScript)
Write-Host ("  Ausgabe   : {0}" -f $OutputPath)
Write-Host ("  Intervall : {0} s, Top-N: {1}, Aufbewahrung: {2} Tage{3}" -f `
    $IntervalSeconds, $TopProcessCount, $RetentionDays, $(if($SqlInstance){", SQL: $SqlInstance"}else{''}))

# --- Sofort starten -----------------------------------------------------------
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $taskName).State
Write-Host "Status: $state" -ForegroundColor $(if ($state -eq 'Running') {'Green'} else {'Yellow'})

Write-Host ""
Write-Host "Verwaltung:" -ForegroundColor Cyan
Write-Host "  Get-ScheduledTask -TaskName $taskName"
Write-Host "  Stop-ScheduledTask -TaskName $taskName"
Write-Host "  Start-ScheduledTask -TaskName $taskName"
Write-Host "  Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
