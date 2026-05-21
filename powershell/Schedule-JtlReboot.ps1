<#
.SYNOPSIS
    Registriert einen geplanten, gewarnten Neustart des Servers (Task Scheduler).
.DESCRIPTION
    Legt eine Windows-Aufgabe an, die den Server zu fester Zeit neu startet und
    angemeldete RDP-Benutzer vorher warnt. Empfehlung:
      - Reiner RDP-Sitzungsserver:   woechentlich (Memory-Leaks der Sessions)
      - Sonst:                       monatlich nach dem Patchday
    Die Aufgabe nutzt 'shutdown /r' mit Vorlaufzeit + Warnmeldung.
.PARAMETER Schedule
    'Weekly' oder 'Monthly'. Standard 'Monthly'.
.PARAMETER DayOfWeek
    Bei Weekly: Wochentag (Standard Sunday).
.PARAMETER DayOfMonth
    Bei Monthly: Tag im Monat (Standard 7 - typ. nach Patchday).
.PARAMETER At
    Uhrzeit, z. B. '03:00'. Standard '03:00'.
.PARAMETER WarnMinutes
    Vorwarnzeit in Minuten, in der angemeldete Nutzer eine Meldung sehen. Standard 10.
.EXAMPLE
    .\Schedule-JtlReboot.ps1 -Schedule Weekly -DayOfWeek Sunday -At 03:00
    .\Schedule-JtlReboot.ps1 -Schedule Monthly -DayOfMonth 7 -At 03:00 -WarnMinutes 15
.NOTES
    Als Administrator ausfuehren. Entfernen: Unregister-ScheduledTask -TaskName JTL_GeplanterNeustart
#>
[CmdletBinding()]
param(
    [ValidateSet('Weekly','Monthly')] [string]$Schedule = 'Monthly',
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
        [string]$DayOfWeek = 'Sunday',
    [ValidateRange(1,28)] [int]$DayOfMonth = 7,
    [string]$At = '03:00',
    [int]$WarnMinutes = 10
)

$ErrorActionPreference = 'Stop'
$taskName = 'JTL_GeplanterNeustart'
$warnSeconds = $WarnMinutes * 60
$comment = "Geplante Serverwartung. Bitte alle Programme schliessen. Neustart in $WarnMinutes Minuten."
# shutdown: /r Neustart, /t Vorlaufzeit, /c Kommentar, /d Grund (Planung)
$cmd = "shutdown.exe /r /t $warnSeconds /c `"$comment`" /d p:0:0"

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c $cmd"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun

if ($Schedule -eq 'Weekly') {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $At
    $info = "woechentlich ($DayOfWeek $At)"
} else {
    # Monatlicher Trigger ueber CIM, da New-ScheduledTaskTrigger kein -Monthly bietet
    $cls = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskMonthlyTrigger
    $trigger = New-CimInstance -CimClass $cls -ClientOnly
    $trigger.DaysOfMonth = [int][math]::Pow(2, ($DayOfMonth - 1)) # Bitmaske: Tag X
    $trigger.MonthsOfYear = 4095   # alle 12 Monate
    $trigger.StartBoundary = ([datetime]::Today.ToString('yyyy-MM-dd') + 'T' + $At + ':00')
    $trigger.Enabled = $true
    $info = "monatlich (Tag $DayOfMonth, $At)"
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Geplanter Neustart mit $WarnMinutes min Vorwarnung." -Force | Out-Null

Write-Host "Aufgabe '$taskName' registriert: $info, Vorwarnung $WarnMinutes min." -ForegroundColor Green
Write-Host "Testen (startet WIRKLICH neu nach Vorlauf): Start-ScheduledTask -TaskName $taskName"
Write-Host "Abbrechen eines laufenden Neustarts:        shutdown /a"
Write-Host "Entfernen:                                  Unregister-ScheduledTask -TaskName $taskName"
