<#
.SYNOPSIS
    Sammelt einen kompakten Gesundheitsbericht eines Windows-Servers mit JTL-Wawi/SQL.
.DESCRIPTION
    Liest CPU, RAM, Disk-Latenz, freien Plattenplatz, Top-Prozesse, den Status der
    JTL-/SQL-Dienste sowie kritische Ereignisse aus dem Eventlog. Optional werden
    Datenbankgroessen direkt aus dem SQL Server abgefragt.
    Read-only - veraendert nichts am System.
.PARAMETER OutputPath
    Verzeichnis fuer den HTML-Report. Standard: .\reports
.PARAMETER SqlInstance
    Optionale SQL-Instanz fuer DB-Groessenabfrage, z. B. "localhost\JTLWAWI".
    Ohne Angabe wird der SQL-Teil uebersprungen.
.PARAMETER EventHours
    Zeitfenster fuer Eventlog-Auswertung in Stunden. Standard: 24.
.EXAMPLE
    .\Get-JtlServerHealthReport.ps1
.EXAMPLE
    .\Get-JtlServerHealthReport.ps1 -SqlInstance "localhost\JTLWAWI" -EventHours 48
.NOTES
    In einer aufgerufenen PowerShell ggf. Ausfuehrungsrichtlinie erlauben:
        powershell -ExecutionPolicy Bypass -File .\Get-JtlServerHealthReport.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SqlInstance,
    [int]$EventHours = 24
)

$ErrorActionPreference = 'Continue'

# Skriptverzeichnis robust ermitteln ($PSScriptRoot ist je nach PowerShell-Version/Startart leer)
if (-not $OutputPath) {
    $scriptDir = if ($PSScriptRoot)               { $PSScriptRoot }
                 elseif ($PSCommandPath)          { Split-Path -Parent $PSCommandPath }
                 elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
                 else                             { (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'reports'
}

$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$reportFile = Join-Path $OutputPath "JTL-Health_$($env:COMPUTERNAME)_$timestamp.html"
$sections = New-Object System.Collections.Generic.List[string]

function Add-Section { param([string]$Title, [object]$Data)
    $html = $Data | ConvertTo-Html -Fragment -As Table
    $sections.Add("<h2>$Title</h2>$html")
}

# --- System / Uptime ---------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime
Add-Section 'System' ([pscustomobject]@{
    Server         = $env:COMPUTERNAME
    Betriebssystem = $os.Caption
    Laufzeit_Tage  = [math]::Round($uptime.TotalDays, 1)
    LetzterStart   = $os.LastBootUpTime
    Zeitpunkt      = Get-Date
})
if ($uptime.TotalDays -gt 35) {
    $sections.Add("<p class='warn'>Hinweis: Server laeuft seit ueber 35 Tagen ohne Neustart. Geplanten Reboot pruefen.</p>")
}

# --- CPU / RAM ----------------------------------------------------------------
$cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
$freeRamMB  = [math]::Round($os.FreePhysicalMemory / 1024)
Add-Section 'CPU & Arbeitsspeicher' ([pscustomobject]@{
    CPU_Auslastung_Prozent = $cpuLoad
    RAM_gesamt_MB          = $totalRamMB
    RAM_frei_MB            = $freeRamMB
    RAM_belegt_Prozent     = [math]::Round((($totalRamMB - $freeRamMB) / $totalRamMB) * 100, 1)
})

# --- Disk: Platz + Latenz -----------------------------------------------------
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [pscustomobject]@{
        Laufwerk      = $_.DeviceID
        Groesse_GB    = [math]::Round($_.Size / 1GB, 1)
        Frei_GB       = [math]::Round($_.FreeSpace / 1GB, 1)
        Frei_Prozent  = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
    }
}
Add-Section 'Datentraeger - Belegung' $disks
foreach ($d in $disks) {
    if ($d.Frei_Prozent -lt 15) {
        $sections.Add("<p class='warn'>Warnung: Laufwerk $($d.Laufwerk) hat nur noch $($d.Frei_Prozent) % frei.</p>")
    }
}

# Disk-Latenz ueber WMI-Performance-Klasse (sprachunabhaengig - Get-Counter-Namen sind
# auf deutschem Windows lokalisiert und wuerden sonst fehlschlagen).
# Zwei Abrufe ~1s auseinander: der erste "primt" die Zaehler, sonst kaeme 0 zurueck.
try {
    Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop | Out-Null
    Start-Sleep -Milliseconds 1000
    $perf = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($perf) {
        $latency = @(
            [pscustomobject]@{ Messwert = 'Avg. Disk sec/Read';        Wert_ms = [math]::Round($perf.AvgDisksecPerRead  * 1000, 1) }
            [pscustomobject]@{ Messwert = 'Avg. Disk sec/Write';       Wert_ms = [math]::Round($perf.AvgDisksecPerWrite * 1000, 1) }
            [pscustomobject]@{ Messwert = 'Current Disk Queue Length'; Wert_ms = $perf.CurrentDiskQueueLength }
        )
        Add-Section 'Datentraeger - Latenz (Richtwert &lt; 10 ms gut, &gt; 20 ms kritisch)' $latency
    } else {
        $sections.Add("<p class='warn'>Disk-Latenz: keine _Total-Instanz gefunden.</p>")
    }
} catch {
    $sections.Add("<p class='warn'>Disk-Latenz nicht verfuegbar: $($_.Exception.Message)</p>")
}

# --- Top-Prozesse -------------------------------------------------------------
$topCpu = Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 Name,
    @{n='CPU_s';e={[math]::Round($_.CPU,1)}}, @{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB,1)}}, Id
Add-Section 'Top-Prozesse nach CPU' $topCpu
$topRam = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 Name,
    @{n='RAM_MB';e={[math]::Round($_.WorkingSet64/1MB,1)}}, @{n='CPU_s';e={[math]::Round($_.CPU,1)}}, Id
Add-Section 'Top-Prozesse nach RAM' $topRam

# --- Relevante Dienste --------------------------------------------------------
$svcPatterns = 'MSSQL*','SQLAgent*','SQLBrowser','*JTL*','*Worker*','*ameise*'
$services = Get-Service | Where-Object {
    $name = $_.Name; $disp = $_.DisplayName
    $svcPatterns | Where-Object { $name -like $_ -or $disp -like $_ }
} | Select-Object Name, DisplayName, Status, StartType -Unique
if ($services) { Add-Section 'JTL- / SQL-Dienste' $services }

# --- Eventlog: kritische Eintraege (gruppiert nach Haeufigkeit) ----------------
# Statt 30 Rohzeilen: nach Quelle+EventId+Stufe gruppieren und zaehlen, damit
# wiederkehrende Fehler ("erscheint 240x") sofort sichtbar werden.
$since = (Get-Date).AddHours(-$EventHours)
try {
    $raw = Get-WinEvent -FilterHashtable @{ LogName='System','Application'; Level=1,2; StartTime=$since } -ErrorAction Stop
    if ($raw) {
        $grouped = $raw | Group-Object LogName, ProviderName, Id, LevelDisplayName | ForEach-Object {
            $latest = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $msg = if ($latest.Message) { ($latest.Message -split "`r?`n")[0] } else { '(kein Meldungstext)' }
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) }
            [pscustomobject]@{
                Anzahl    = $_.Count
                Protokoll = $latest.LogName
                Quelle    = $latest.ProviderName
                EventId   = $latest.Id
                Stufe     = $latest.LevelDisplayName
                Zuletzt   = $latest.TimeCreated
                Beispiel  = $msg
            }
        } | Sort-Object Anzahl -Descending | Select-Object -First 25
        Add-Section "Eventlog - Fehler/Kritisch gruppiert (letzte $EventHours h)" $grouped
    } else {
        $sections.Add("<p>Keine kritischen Eventlog-Eintraege in den letzten $EventHours h.</p>")
    }
} catch {
    $sections.Add("<p class='warn'>Eventlog-Auswertung fehlgeschlagen: $($_.Exception.Message)</p>")
}

# --- Optional: SQL-Datenbankgroessen ------------------------------------------
if ($SqlInstance) {
    $query = @"
SET NOCOUNT ON;
SELECT DB_NAME(database_id) AS Datenbank,
       CAST(SUM(size) * 8 / 1024.0 AS DECIMAL(18,1)) AS Gesamt_MB
FROM sys.master_files GROUP BY database_id ORDER BY Gesamt_MB DESC;
"@
    try {
        $sqlcmdAvailable = Get-Command sqlcmd -ErrorAction SilentlyContinue
        if ($sqlcmdAvailable) {
            # sqlcmd in einem Hintergrund-Job mit hartem Timeout, damit ein haengender
            # Verbindungsversuch den ganzen Report nicht blockiert.
            $job = Start-Job -ScriptBlock {
                param($inst, $q)
                sqlcmd -S $inst -E -l 10 -t 30 -h -1 -W -s "|" -Q $q 2>&1
            } -ArgumentList $SqlInstance, $query
            if (Wait-Job $job -Timeout 40) {
                $raw = Receive-Job $job
                $sections.Add("<h2>SQL: Datenbankgroessen ($SqlInstance)</h2><pre>$($raw -join "`n")</pre>")
            } else {
                Stop-Job $job
                $sections.Add("<p class='warn'>SQL-Abfrage nach 40s abgebrochen - SqlInstance pruefen oder Parameter weglassen.</p>")
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } else {
            $sections.Add("<p class='warn'>sqlcmd nicht gefunden - SQL-Teil uebersprungen.</p>")
        }
    } catch {
        $sections.Add("<p class='warn'>SQL-Abfrage fehlgeschlagen: $($_.Exception.Message)</p>")
    }
}

# --- HTML zusammenbauen -------------------------------------------------------
$style = @"
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color:#222; }
 h1 { border-bottom: 2px solid #444; }
 h2 { margin-top: 28px; color:#1a5; }
 table { border-collapse: collapse; margin: 8px 0; }
 th,td { border:1px solid #ccc; padding:4px 8px; font-size: 13px; text-align:left; }
 th { background:#f0f0f0; }
 .warn { color:#b00; font-weight:bold; }
 pre { background:#f7f7f7; padding:8px; border:1px solid #ddd; }
</style>
"@
$body = "<h1>JTL Server-Health: $($env:COMPUTERNAME)</h1><p>Erstellt: $(Get-Date)</p>" + ($sections -join "`n")
ConvertTo-Html -Head $style -Body $body | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host "Report erstellt: $reportFile" -ForegroundColor Green
return $reportFile
