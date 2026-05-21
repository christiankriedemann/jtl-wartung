<#
.SYNOPSIS
    Registriert wiederkehrende Wartungsaufgaben (Health-Report + Cleanup) im Task Scheduler.
.DESCRIPTION
    Legt zwei Windows-Aufgaben an, die die mitgelieferten Skripte regelmaessig ausfuehren:
      - JTL_HealthReport   : woechentlich ein HTML-Gesundheitsbericht
      - JTL_Cleanup        : monatlich Temp-/Log-Bereinigung (mit -Execute)
    SQL-Wartung wird hier NICHT angelegt - dafuer:
      - Express:  Install-MaintenanceSolution-Express.ps1
      - Standard: sql/setup/Setup-SqlAgentJobs-Standard.sql
.PARAMETER SqlInstance
    Optional fuer den Health-Report (DB-Groessen). Z. B. ".\SQLEXPRESS".
.PARAMETER ReportPath
    Zielordner fuer die HTML-Reports. Standard: C:\JTL-Wartung\reports
.EXAMPLE
    .\Register-JtlScheduledTasks.ps1 -SqlInstance ".\SQLEXPRESS"
.NOTES
    Als Administrator ausfuehren. Die Skripte sollten an einem festen Ort liegen
    (Standard wird nach C:\JTL-Wartung kopiert, falls von woanders gestartet).
#>
[CmdletBinding()]
param(
    [string]$SqlInstance,
    [string]$ReportPath = 'C:\JTL-Wartung\reports'
)

$ErrorActionPreference = 'Stop'
$installDir = 'C:\JTL-Wartung'
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

# Skripte an festen Ort kopieren, damit die Aufgaben stabil laufen
foreach ($f in 'Get-JtlServerHealthReport.ps1','Invoke-JtlCleanup.ps1') {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) { Copy-Item $src -Destination $installDir -Force }
}
if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$psExe     = 'powershell.exe'

# --- Health-Report: woechentlich Montag 06:00 ---
$sqlPart = if ($SqlInstance) { " -SqlInstance `"$SqlInstance`"" } else { '' }
$healthArgs = "-ExecutionPolicy Bypass -NonInteractive -File `"$installDir\Get-JtlServerHealthReport.ps1`" -OutputPath `"$ReportPath`"$sqlPart"
Register-ScheduledTask -TaskName 'JTL_HealthReport' `
    -Action (New-ScheduledTaskAction -Execute $psExe -Argument $healthArgs) `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '06:00') `
    -Principal $principal -Settings $settings `
    -Description 'Woechentlicher JTL-Server-Gesundheitsbericht (HTML).' -Force | Out-Null
Write-Host "Aufgabe registriert: JTL_HealthReport (Mo 06:00)" -ForegroundColor Green

# --- Cleanup: monatlich am 1. um 05:00 (mit -Execute) ---
$cleanupArgs = "-ExecutionPolicy Bypass -NonInteractive -File `"$installDir\Invoke-JtlCleanup.ps1`" -Execute -LogDays 30"
$cls = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskMonthlyTrigger
$mTrigger = New-CimInstance -CimClass $cls -ClientOnly
$mTrigger.DaysOfMonth   = 1            # Bitmaske: 1 = erster Tag
$mTrigger.MonthsOfYear  = 4095         # alle Monate
$mTrigger.StartBoundary = ([datetime]::Today.ToString('yyyy-MM-dd') + 'T05:00:00')
$mTrigger.Enabled = $true
Register-ScheduledTask -TaskName 'JTL_Cleanup' `
    -Action (New-ScheduledTaskAction -Execute $psExe -Argument $cleanupArgs) `
    -Trigger $mTrigger -Principal $principal -Settings $settings `
    -Description 'Monatliche Temp-/Log-Bereinigung.' -Force | Out-Null
Write-Host "Aufgabe registriert: JTL_Cleanup (monatlich, 1. um 05:00)" -ForegroundColor Green

Write-Host "`nUebersicht:  Get-ScheduledTask -TaskName JTL_*" -ForegroundColor Cyan
