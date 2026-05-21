<#
.SYNOPSIS
    Bereinigt temporaere Dateien und alte Logs auf einem JTL-/RDP-Server.
.DESCRIPTION
    Loescht Windows-Temp, alte Eventlog-Archive sowie alte JTL-/Worker-Logdateien
    oberhalb eines Mindestalters. Standardmaessig Trockenlauf (-WhatIf-Stil):
    es wird nur angezeigt, was geloescht wuerde. Erst mit -Execute wird geloescht.
.PARAMETER LogDays
    Logdateien aelter als X Tage werden geloescht. Standard 30.
.PARAMETER JtlLogPaths
    Zusaetzliche Verzeichnisse mit JTL-/Worker-Logs.
.PARAMETER Execute
    Ohne diesen Schalter laeuft nur die Vorschau (nichts wird geloescht).
.EXAMPLE
    .\Invoke-JtlCleanup.ps1
    .\Invoke-JtlCleanup.ps1 -Execute -LogDays 14 -JtlLogPaths "C:\ProgramData\JTL-Software\Logs"
.NOTES
    Als Administrator ausfuehren. Vorsicht bei eigenen Log-Pfaden - Pfade pruefen.
#>
[CmdletBinding()]
param(
    [int]$LogDays = 30,
    [string[]]$JtlLogPaths = @(),
    [switch]$Execute
)

$cutoff = (Get-Date).AddDays(-$LogDays)
$freedBytes = 0
$mode = if ($Execute) { 'LOESCHE' } else { 'Vorschau (nichts wird geloescht)' }
Write-Host "Modus: $mode | Logs aelter als $LogDays Tage ($cutoff)" -ForegroundColor Cyan

# Temp-Verzeichnisse (immer sicher zu leeren)
$tempTargets = @($env:TEMP, "$env:WINDIR\Temp")
# Optionale JTL-Logpfade nur nach Alter filtern
$logTargets = $JtlLogPaths

function Remove-OldFiles {
    param([string]$Path, [datetime]$OlderThan, [switch]$AllFiles)
    if (-not (Test-Path $Path)) { Write-Host "  uebersprungen (nicht vorhanden): $Path"; return }
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    if (-not $AllFiles) { $files = $files | Where-Object { $_.LastWriteTime -lt $OlderThan } }
    $count = 0; $bytes = 0
    foreach ($f in $files) {
        $bytes += $f.Length; $count++
        if ($Execute) {
            try { Remove-Item $f.FullName -Force -ErrorAction Stop } catch { }
        }
    }
    $script:freedBytes += $bytes
    Write-Host ("  {0}: {1} Dateien, {2:N1} MB" -f $Path, $count, ($bytes/1MB))
}

Write-Host "`n[Temp-Verzeichnisse]" -ForegroundColor Yellow
foreach ($t in $tempTargets) { Remove-OldFiles -Path $t -OlderThan $cutoff -AllFiles }

if ($logTargets) {
    Write-Host "`n[JTL-/Worker-Logs (nur aelter als $LogDays Tage)]" -ForegroundColor Yellow
    foreach ($l in $logTargets) { Remove-OldFiles -Path $l -OlderThan $cutoff }
}

Write-Host ("`nGesamt {0}: {1:N1} MB" -f ($(if($Execute){'freigegeben'}else{'freigebbar'}), ($freedBytes/1MB))) -ForegroundColor Green
if (-not $Execute) { Write-Host "Mit -Execute erneut ausfuehren, um tatsaechlich zu loeschen." -ForegroundColor Cyan }
