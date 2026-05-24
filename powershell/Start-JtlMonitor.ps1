<#
.SYNOPSIS
    Dauer-Monitor fuer Systemlast und Verursacher (CPU, RAM, Disk, Netzwerk,
    Top-Prozesse, optional SQL Live-Abfragen + Blocking).

.DESCRIPTION
    Laeuft als Dauerschleife - typischerweise via Aufgabenplaner unter SYSTEM
    gestartet (siehe Register-JtlMonitorTask.ps1). Schreibt pro Intervall (Standard
    60 s) Zeilen in tagesweise rotierende CSV-Dateien, damit man auch nach Tagen
    rueckwirkend sehen kann, was zu Stosszeiten oder gemeldeten Haengern los war.

    Erfasste Bereiche je Stichprobe:
      - System  : CPU%, RAM, Disk-Latenz/Queue/IOps, Netzwerk-Durchsatz, Sitzungen
      - Top-Prozesse : Top-N nach CPU% (Delta-berechnet) und nach RAM, mit PID
      - SQL (optional) : laufende Abfragen + Blocking (-SqlInstance setzen)

    Ausgabe (eine Datei je Tag und Bereich):
      monitor_<HOST>_<JJJJ-MM-TT>_system.csv
      monitor_<HOST>_<JJJJ-MM-TT>_topprocesses.csv
      monitor_<HOST>_<JJJJ-MM-TT>_sql.csv          (nur mit -SqlInstance)
      monitor_<HOST>_errors.log                    (falls Sammelfehler auftreten)

    Read-only auf das System - schreibt nur in den Ausgabe-Ordner.
    Sprachunabhaengig: nutzt Win32_PerfFormattedData_*-Klassen statt lokalisierter
    Get-Counter-Pfade.

.PARAMETER OutputPath
    Ordner fuer die CSV-Dateien. Standard: <Skriptordner>\monitor

.PARAMETER IntervalSeconds
    Sampling-Intervall in Sekunden. Standard 60. Sinnvoller Bereich 30-300.

.PARAMETER TopProcessCount
    Anzahl Top-Prozesse je Stichprobe (nach CPU UND nach RAM). Standard 10.

.PARAMETER SqlInstance
    Optional, z. B. ".\JTLWAWI". Aktiviert die SQL-Live-Abfrage je Intervall.
    Auf Servern ohne lokales SQL weglassen.

.PARAMETER RetentionDays
    Dateien aelter als X Tage werden automatisch geloescht. Standard 14.

.EXAMPLE
    .\Start-JtlMonitor.ps1
.EXAMPLE
    .\Start-JtlMonitor.ps1 -SqlInstance ".\JTLWAWI" -IntervalSeconds 30 -TopProcessCount 15

.NOTES
    Stoppen:
      - als Aufgabe :  Stop-ScheduledTask -TaskName JTL_Monitor
      - im Vordergrund: Strg-C
    Auswerten:
      - CSV-Dateien per Excel/Power Query oeffnen (Semikolon-getrennt, UTF-8).
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [ValidateRange(10, 3600)] [int]$IntervalSeconds = 60,
    [ValidateRange(1, 50)]    [int]$TopProcessCount = 10,
    [string]$SqlInstance,
    [ValidateRange(1, 365)]   [int]$RetentionDays = 14
)

$ErrorActionPreference = 'Continue'

# --- Ausgabe-Ordner robust ermitteln -----------------------------------------
if (-not $OutputPath) {
    $scriptDir = if ($PSScriptRoot)               { $PSScriptRoot }
                 elseif ($PSCommandPath)          { Split-Path -Parent $PSCommandPath }
                 elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
                 else                             { (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'monitor'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$hostName  = $env:COMPUTERNAME
$errorFile = Join-Path $OutputPath ("monitor_${hostName}_errors.log")

Write-Host "JTL-Monitor gestartet auf '$hostName'." -ForegroundColor Cyan
Write-Host "  Ausgabe   : $OutputPath"
Write-Host "  Intervall : $IntervalSeconds s, Top-N : $TopProcessCount, Aufbewahrung : $RetentionDays Tage"
if ($SqlInstance) { Write-Host "  SQL       : $SqlInstance (mit Live-Abfrage)" -ForegroundColor Cyan }
Write-Host "Stoppen mit Strg-C bzw. Stop-ScheduledTask -TaskName JTL_Monitor." -ForegroundColor DarkGray

# --- Helfer -------------------------------------------------------------------
function Get-DailyFile {
    param([string]$Bereich)
    $day = Get-Date -Format 'yyyy-MM-dd'
    Join-Path $OutputPath "monitor_${hostName}_${day}_${Bereich}.csv"
}

function Add-CsvRows {
    param([Parameter(Mandatory)][string]$Path, $Rows)
    if (-not $Rows) { return }
    # Export-Csv -Append legt bei Bedarf den Header an
    $Rows | Export-Csv -Path $Path -NoTypeInformation -Append -Encoding UTF8 -Delimiter ';'
}

function Write-MonitorError {
    param([string]$Message)
    Add-Content -Path $errorFile -Value ("{0}`t{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function Invoke-Cleanup {
    param([int]$Days)
    $cutoff = (Get-Date).AddDays(-$Days)
    Get-ChildItem -Path $OutputPath -File -Filter "monitor_${hostName}_*.csv" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# --- Priming der WMI-Perf-Klassen (erster Aufruf liefert sonst 0) -------------
try { Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk     -ErrorAction Stop | Out-Null } catch {}
try { Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface    -ErrorAction Stop | Out-Null } catch {}

$prevProc  = @{}
$prevSnap  = Get-Date
$coreCount = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfLogicalProcessors
if (-not $coreCount -or $coreCount -lt 1) { $coreCount = 1 }

# --- Hauptschleife ------------------------------------------------------------
while ($true) {
    $iterStart = Get-Date
    $ts = $iterStart.ToString('yyyy-MM-dd HH:mm:ss')

    # ============= System: CPU, RAM, Disk, Netzwerk, Sessions =================
    try {
        $os      = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpuLoad = (Get-CimInstance Win32_Processor -ErrorAction Stop |
                    Measure-Object LoadPercentage -Average).Average

        $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        $netIf = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch '(Loopback|isatap|Teredo)' }

        $sessions = 0
        try {
            $q = quser 2>$null
            if ($q) { $sessions = ($q | Select-Object -Skip 1).Count }
        } catch {}

        $sysRow = [pscustomobject]@{
            Zeitpunkt        = $ts
            CPU_Prozent      = $cpuLoad
            RAM_gesamt_MB    = [math]::Round($os.TotalVisibleMemorySize / 1024)
            RAM_belegt_MB    = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
            RAM_frei_MB      = [math]::Round($os.FreePhysicalMemory / 1024)
            Disk_Read_ms     = if ($disk) { [math]::Round($disk.AvgDisksecPerRead  * 1000, 1) } else { $null }
            Disk_Write_ms    = if ($disk) { [math]::Round($disk.AvgDisksecPerWrite * 1000, 1) } else { $null }
            Disk_Queue       = if ($disk) { $disk.CurrentDiskQueueLength } else { $null }
            Disk_Read_IOps   = if ($disk) { [int]$disk.DiskReadsPerSec  } else { $null }
            Disk_Write_IOps  = if ($disk) { [int]$disk.DiskWritesPerSec } else { $null }
            Net_Rx_KBps      = if ($netIf) { [math]::Round((($netIf | Measure-Object BytesReceivedPerSec -Sum).Sum) / 1KB, 1) } else { $null }
            Net_Tx_KBps      = if ($netIf) { [math]::Round((($netIf | Measure-Object BytesSentPerSec    -Sum).Sum) / 1KB, 1) } else { $null }
            Sessions         = $sessions
        }
        Add-CsvRows -Path (Get-DailyFile 'system') -Rows @($sysRow)
    } catch {
        Write-MonitorError "System: $($_.Exception.Message)"
    }

    # ============= Top-Prozesse (CPU%-Delta + RAM) ============================
    try {
        $now      = Get-Date
        $deltaSec = ($now - $prevSnap).TotalSeconds
        $procs    = Get-Process -ErrorAction SilentlyContinue

        $rows = New-Object System.Collections.Generic.List[object]
        $curr = @{}
        foreach ($p in $procs) {
            if ($null -eq $p.CPU) { continue }    # einige System-PIDs liefern kein CPU
            $curr[$p.Id] = $p.CPU
            $cpuPct = $null
            if ($prevProc.ContainsKey($p.Id) -and $deltaSec -gt 0) {
                $diff = $p.CPU - $prevProc[$p.Id]
                if ($diff -lt 0) { $diff = 0 }
                $cpuPct = [math]::Round(($diff / $deltaSec) * 100 / $coreCount, 1)
            }
            $rows.Add([pscustomobject]@{
                Zeitpunkt    = $ts
                ProzessName  = $p.ProcessName
                ProzessId    = $p.Id
                CPU_Prozent  = $cpuPct
                RAM_MB       = [math]::Round($p.WorkingSet64 / 1MB, 1)
                Threads      = $p.Threads.Count
                Handles      = $p.HandleCount
                Kategorie    = $null   # wird unten gesetzt
            })
        }
        $prevProc = $curr
        $prevSnap = $now

        # Top-N nach CPU% (erst ab dem zweiten Sample sinnvoll) UND nach RAM
        $topCpu = $rows | Where-Object { $null -ne $_.CPU_Prozent } |
                  Sort-Object CPU_Prozent -Descending | Select-Object -First $TopProcessCount
        $topRam = $rows | Sort-Object RAM_MB -Descending | Select-Object -First $TopProcessCount

        $tagged = @{}
        foreach ($r in $topCpu) { $r.Kategorie = 'CPU'; $tagged[$r.ProzessId] = $r }
        foreach ($r in $topRam) {
            if ($tagged.ContainsKey($r.ProzessId)) { $tagged[$r.ProzessId].Kategorie = 'CPU+RAM' }
            else { $r.Kategorie = 'RAM'; $tagged[$r.ProzessId] = $r }
        }
        Add-CsvRows -Path (Get-DailyFile 'topprocesses') -Rows ($tagged.Values)
    } catch {
        Write-MonitorError "Prozesse: $($_.Exception.Message)"
    }

    # ============= Optional: SQL-Live-Abfragen + Blocking =====================
    if ($SqlInstance) {
        try {
            if (Get-Command sqlcmd -ErrorAction SilentlyContinue) {
                $query = @"
SET NOCOUNT ON;
SELECT
  CONVERT(VARCHAR(19), GETDATE(), 120) AS Zeitpunkt,
  r.session_id AS Sitzung,
  r.status AS Status,
  ISNULL(r.blocking_session_id, 0) AS BlockiertVon,
  ISNULL(r.wait_type, '') AS WaitTyp,
  r.wait_time AS Wartezeit_ms,
  r.cpu_time AS CPU_ms,
  r.total_elapsed_time AS Laufzeit_ms,
  ISNULL(DB_NAME(r.database_id), '') AS Datenbank,
  REPLACE(REPLACE(LEFT(ISNULL(t.text,''), 300), CHAR(13),' '), CHAR(10),' ') AS Statement
FROM sys.dm_exec_requests r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id > 50 AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;
"@
                # sqlcmd in Hintergrund-Job mit hartem Timeout (auf inlet sonst Hang-Gefahr)
                $job = Start-Job -ScriptBlock {
                    param($inst, $q)
                    sqlcmd -S $inst -E -l 5 -t 15 -h -1 -W -s ';' -Q $q 2>&1
                } -ArgumentList $SqlInstance, $query

                if (Wait-Job $job -Timeout 20) {
                    $out = Receive-Job $job
                    $clean = $out | Where-Object {
                        $_ -is [string] -and $_ -ne '' -and $_ -notmatch '^[\s\-]+$'
                    }
                    if ($clean) {
                        $sqlFile = Get-DailyFile 'sql'
                        if (-not (Test-Path $sqlFile)) {
                            # Einmaliger Header zu Beginn der Tagesdatei
                            'Zeitpunkt;Sitzung;Status;BlockiertVon;WaitTyp;Wartezeit_ms;CPU_ms;Laufzeit_ms;Datenbank;Statement' |
                                Out-File -FilePath $sqlFile -Encoding UTF8
                        }
                        $clean | Out-File -FilePath $sqlFile -Append -Encoding UTF8
                    }
                } else {
                    Stop-Job $job -ErrorAction SilentlyContinue
                    Write-MonitorError "SQL: Timeout nach 20s (Instance $SqlInstance)"
                }
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            } else {
                Write-MonitorError "SQL: sqlcmd nicht gefunden - SQL-Teil uebersprungen."
            }
        } catch {
            Write-MonitorError "SQL: $($_.Exception.Message)"
        }
    }

    # ============= Aufraeumen (nur halbstuendlich) ============================
    if ($iterStart.Minute -in @(0, 30) -and $iterStart.Second -lt $IntervalSeconds) {
        try { Invoke-Cleanup -Days $RetentionDays } catch {}
    }

    # ============= Schlafen, abzueglich Iterationsdauer =======================
    $elapsedMs = [int]((Get-Date) - $iterStart).TotalMilliseconds
    $sleepMs   = [math]::Max(500, ($IntervalSeconds * 1000) - $elapsedMs)
    Start-Sleep -Milliseconds $sleepMs
}
