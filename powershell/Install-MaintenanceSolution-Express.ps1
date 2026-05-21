<#
.SYNOPSIS
    Richtet die Ola-Hallengren-Wartung auf SQL Server EXPRESS ein (ohne SQL Agent).
.DESCRIPTION
    Express hat keinen SQL Server Agent. Diese Loesung installiert die gespeicherten
    Ola-Hallengren-Prozeduren in der master-DB und legt Windows-Aufgaben
    (Task Scheduler) an, die per sqlcmd die Wartung ausfuehren:
      - taegliches FULL-Backup        02:00
      - taegliche Index-/Statistikpflege 03:00
      - woechentlicher CHECKDB          So 04:00
    Idempotent: erneutes Ausfuehren aktualisiert die Aufgaben.
.PARAMETER SqlInstance
    SQL-Express-Instanz, z. B. "localhost\JTLWAWI" oder ".\SQLEXPRESS".
.PARAMETER BackupDirectory
    Vorhandenes Verzeichnis fuer Backups, z. B. "D:\SQLBackup".
.PARAMETER MaintenanceSolutionPath
    Pfad zur heruntergeladenen MaintenanceSolution.sql von https://ola.hallengren.com
.PARAMETER CleanupHours
    Backups aelter als X Stunden loeschen. Standard 168 (7 Tage).
.EXAMPLE
    .\Install-MaintenanceSolution-Express.ps1 -SqlInstance ".\SQLEXPRESS" `
        -BackupDirectory "D:\SQLBackup" -MaintenanceSolutionPath "C:\temp\MaintenanceSolution.sql"
.NOTES
    Als Administrator ausfuehren. Aufgaben laufen unter dem SYSTEM-Konto;
    dieses braucht in SQL die Rechte zum Sichern/Warten (sysadmin oder passend).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SqlInstance,
    [Parameter(Mandatory)] [string]$BackupDirectory,
    [Parameter(Mandatory)] [string]$MaintenanceSolutionPath,
    [int]$CleanupHours = 168
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd nicht gefunden. Bitte 'SQL Server Command Line Utilities' installieren."
}
if (-not (Test-Path $MaintenanceSolutionPath)) {
    throw "MaintenanceSolution.sql nicht gefunden unter: $MaintenanceSolutionPath. Download: https://ola.hallengren.com"
}
if (-not (Test-Path $BackupDirectory)) {
    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    Write-Host "Backup-Verzeichnis angelegt: $BackupDirectory"
}

Write-Host "1/3 Installiere Ola-Hallengren-Prozeduren in master ($SqlInstance) ..." -ForegroundColor Cyan
# Auf Express keine Jobs anlegen lassen (kein Agent vorhanden).
sqlcmd -S $SqlInstance -E -b -v CreateJobs="N" BackupDirectory="$BackupDirectory" -i $MaintenanceSolutionPath
if ($LASTEXITCODE -ne 0) { throw "Installation der Wartungsprozeduren fehlgeschlagen." }

# Wiederverwendbarer Helfer: registriert eine taegliche/woechentliche Aufgabe,
# die sqlcmd mit einem T-SQL-Kommando aufruft.
function Register-SqlMaintenanceTask {
    param([string]$TaskName, [string]$TSql, [datetime]$At, [string]$Weekly)

    $sqlArg = "-S `"$SqlInstance`" -E -b -Q `"$TSql`""
    $action = New-ScheduledTaskAction -Execute 'sqlcmd.exe' -Argument $sqlArg
    if ($Weekly) {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Weekly -At $At
    } else {
        $trigger = New-ScheduledTaskTrigger -Daily -At $At
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  Aufgabe registriert: $TaskName"
}

Write-Host "2/3 Lege Windows-Aufgaben an ..." -ForegroundColor Cyan

$backupCmd = "EXECUTE dbo.DatabaseBackup @Databases='USER_DATABASES', " +
             "@Directory=N'$BackupDirectory', @BackupType='FULL', @Verify='Y', " +
             "@Compress='Y', @CheckSum='Y', @CleanupTime=$CleanupHours"
Register-SqlMaintenanceTask -TaskName 'JTL_SQL_BackupFull' -TSql $backupCmd -At ([datetime]'02:00')

$indexCmd = "EXECUTE dbo.IndexOptimize @Databases='USER_DATABASES', " +
            "@FragmentationLow=NULL, " +
            "@FragmentationMedium='INDEX_REORGANIZE,INDEX_REBUILD_OFFLINE', " +
            "@FragmentationHigh='INDEX_REBUILD_OFFLINE', " +
            "@FragmentationLevel1=5, @FragmentationLevel2=30, " +
            "@UpdateStatistics='ALL', @OnlyModifiedStatistics='Y'"
Register-SqlMaintenanceTask -TaskName 'JTL_SQL_IndexOptimize' -TSql $indexCmd -At ([datetime]'03:00')

$checkCmd = "EXECUTE dbo.DatabaseIntegrityCheck @Databases='USER_DATABASES', @CheckCommands='CHECKDB'"
Register-SqlMaintenanceTask -TaskName 'JTL_SQL_IntegrityCheck' -TSql $checkCmd -At ([datetime]'04:00') -Weekly 'Sunday'

Write-Host "3/3 Fertig." -ForegroundColor Green
Write-Host "Aufgaben pruefen mit:  Get-ScheduledTask -TaskName JTL_SQL_*"
Write-Host "Manuell testen mit:    Start-ScheduledTask -TaskName JTL_SQL_BackupFull"
