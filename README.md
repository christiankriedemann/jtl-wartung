# JTL-Wartung

Analyse- und Wartungsskripte für **JTL-Wawi** auf Windows-Server (RDP, Hosting z. B. bei e-comdata).
Deckt beide üblichen Konstellationen ab:

- **SQL Server Standard/Web** auf dediziertem DB-Server → Wartung über **SQL Server Agent**
- **SQL Server Express** lokal auf dem Server → Wartung über **Windows-Aufgabenplanung** (kein Agent in Express)

Alle Diagnoseskripte sind **read-only**. Wartungs-/Setup-Skripte sind als solche gekennzeichnet und melden, was sie tun.

---

## Inhalt

```
jtl-wartung/
├─ powershell/
│  ├─ Get-JtlServerHealthReport.ps1        # HTML-Gesundheitsbericht (CPU/RAM/Disk-Latenz/Dienste/Eventlog)
│  ├─ Invoke-JtlCleanup.ps1                # Temp-/Log-Bereinigung (Vorschau, dann -Execute)
│  ├─ Schedule-JtlReboot.ps1               # Geplanter, gewarnter Neustart (wöchentl./monatl.)
│  ├─ Install-MaintenanceSolution-Express.ps1  # Ola Hallengren + Aufgabenplanung (EXPRESS)
│  └─ Register-JtlScheduledTasks.ps1       # Health-Report + Cleanup als geplante Aufgaben
└─ sql/
   ├─ diagnose/                            # read-only Analyse (SSMS oder sqlcmd)
   │  ├─ 01_server_config_check.sql        # max memory, Edition, MAXDOP, tempdb
   │  ├─ 02_wait_stats.sql                 # worauf wartet SQL? (wichtigste Analyse)
   │  ├─ 03_file_io_latency.sql            # Disk-Latenz je DB-Datei
   │  ├─ 04_index_fragmentation.sql        # Fragmentierung (aktuelle DB)
   │  ├─ 05_missing_indexes.sql            # fehlende Indizes + laufende Abfragen/Blocking
   │  └─ 06_db_size_and_growth.sql         # DB-Größen, Autogrowth, Express-10-GB-Check
   └─ setup/
      └─ Setup-SqlAgentJobs-Standard.sql   # Ola Hallengren + SQL-Agent-Zeitpläne (STANDARD)
```

---

## Schnellstart: Wo liegt die Bremse?

1. **SQL-Konfiguration prüfen** — `sql/diagnose/01_server_config_check.sql`
   Häufigster Fund: `max server memory` nicht gesetzt, oder Express am 10-GB-Limit.
2. **Wait Stats** — `02_wait_stats.sql`
   Zeigt die Art des Engpasses (Disk / CPU / Blocking / Netzwerk).
3. **Disk-Latenz** — `03_file_io_latency.sql` (Richtwert < 10 ms; > 20 ms = Storage-Problem).
4. **Windows-Gesamtbild** — `powershell/Get-JtlServerHealthReport.ps1` → HTML-Report.

Ausführen per sqlcmd, z. B.:
```cmd
sqlcmd -S .\SQLEXPRESS -E -i sql\diagnose\02_wait_stats.sql -o wait_stats.txt
```

---

## Wartung einrichten

### Variante A — SQL Server Standard (dedizierter DB-Server)
1. `MaintenanceSolution.sql` von <https://ola.hallengren.com> herunterladen und installieren
   (mit `@CreateJobs = 'Y'`, Backup-Verzeichnis setzen).
2. `sql/setup/Setup-SqlAgentJobs-Standard.sql` ausführen → legt die Zeitpläne an
   (FULL-Backup täglich 02:00, IndexOptimize täglich 03:00, CHECKDB So 04:00).

### Variante B — SQL Server Express (lokal, kein Agent)
```powershell
.\powershell\Install-MaintenanceSolution-Express.ps1 `
    -SqlInstance ".\SQLEXPRESS" `
    -BackupDirectory "D:\SQLBackup" `
    -MaintenanceSolutionPath "C:\temp\MaintenanceSolution.sql"
```
Legt dieselbe Wartung als **Windows-Aufgaben** (`JTL_SQL_*`) an.

### Windows-seitige Aufgaben (beide Varianten)
```powershell
.\powershell\Register-JtlScheduledTasks.ps1 -SqlInstance ".\SQLEXPRESS"   # Health-Report + Cleanup
.\powershell\Schedule-JtlReboot.ps1 -Schedule Monthly -DayOfMonth 7 -At 03:00
```

---

## Empfohlener Rhythmus

| Aufgabe | Häufigkeit | Werkzeug |
|---|---|---|
| FULL-Backup | täglich (nachts) | Ola Hallengren (Agent / Task) |
| Index- & Statistikpflege | täglich (nachts) | Ola Hallengren |
| DBCC CHECKDB (Integrität) | wöchentlich | Ola Hallengren |
| Health-Report (HTML) | wöchentlich | `Get-JtlServerHealthReport.ps1` |
| Temp-/Log-Bereinigung | monatlich | `Invoke-JtlCleanup.ps1` |
| Windows Update + Reboot | monatlich (nach Patchday) | `Schedule-JtlReboot.ps1` |
| Reboot bei reinem RDP-Server | ggf. wöchentlich | `Schedule-JtlReboot.ps1 -Schedule Weekly` |
| JTL-eigene „Datenbankwartung“ | monatlich / bei Bedarf | in JTL-Wawi |

---

## Hinweise

- PowerShell-Skripte als **Administrator** ausführen; bei Bedarf
  `powershell -ExecutionPolicy Bypass -File <Skript>`.
- **Express-Besonderheiten:** kein SQL Agent, max. 10 GB pro DB, ~1,4 GB Buffer Pool,
  max. 4 Kerne / 1 Socket — bei anhaltender Langsamkeit ist der Wechsel auf Standard zu prüfen.
- **Virenscanner:** `.mdf`/`.ldf`/`.ndf` sowie JTL-Verzeichnisse von der Echtzeitprüfung ausnehmen.
- **Energieplan** auf „Höchstleistung“ stellen (`powercfg /setactive SCHEME_MIN`).
- Index-Vorschläge aus `05_missing_indexes.sql` **nicht blind** übernehmen — bei JTL im Zweifel
  mit dem JTL-Support abstimmen.
- Die Backup-/Reboot-Zeiten in den Skripten an euer Wartungsfenster anpassen.
