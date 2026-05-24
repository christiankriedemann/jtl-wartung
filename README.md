# JTL-Wartung

Fertige Skripte, um einen **JTL-Wawi-Server** (Windows, oft per RDP gehostet, z. B. bei e-comdata)
zu **analysieren** und die **Wartung zu automatisieren** – Backups, Indexpflege, Integritätsprüfung,
Aufräumen, geplanter Neustart.

Du brauchst kein Vorwissen über die Skripte. Diese Seite führt dich Schritt für Schritt.

---

> ## ⚠️ Bitte zuerst lesen – Nutzung auf eigene Gefahr
>
> - **Einsatz auf eigenes Risiko.** Diese Skripte werden „wie besehen", **ohne jede Gewähr**
>   bereitgestellt. Es wird keine Haftung für Schäden, Datenverlust oder Ausfälle übernommen,
>   die aus der Nutzung entstehen.
> - **Verstehen vor Ausführen.** Setze nur ein, was du nachvollziehen kannst. Lies, was ein
>   Skript tut, bevor du es startest. Die Tabelle [„Was ist gefahrlos, was verändert etwas?"](#wichtig-was-ist-gefahrlos-was-verändert-etwas)
>   zeigt, welche Skripte nur lesen und welche etwas verändern.
> - **Immer vorher ein Backup.** Vor jeder verändernden Aktion (Wartung einrichten, Aufräumen,
>   Neustart planen) eine **geprüfte, wiederherstellbare Datensicherung** anlegen.
> - **Erst testen, dann produktiv.** Wenn möglich zuerst auf einem Test-/Spiegelsystem ausprobieren,
>   nicht direkt auf dem Live-Server.
> - **Du bist verantwortlich.** Du allein bist für den Betrieb deines Servers, die Einhaltung der
>   Lizenz-/Supportbedingungen von JTL und Microsoft sowie für eventuelle Folgen verantwortlich.

---

## Was bringt mir das?

- **Finde die Bremse:** Warum ist die Wawi langsam? (Speicher, Festplatte, fehlende Indizes …)
- **Sichere die Daten:** Automatische Backups, damit im Ernstfall nichts verloren geht.
- **Halte es schnell:** Nächtliche Index- und Statistikpflege gegen schleichende Verlangsamung.
- **Weniger Handarbeit:** Einmal einrichten, dann läuft die Wartung von allein.

---

## Ich habe das gerade heruntergeladen – was nun?

Geh einfach von oben nach unten. **Schritt 1 ist gefahrlos** und der richtige Start.

### Schritt 1 – Lage prüfen (ändert nichts, immer ungefährlich)
Diese Skripte **lesen nur** und zeigen dir, wie es um den Server steht. Du kannst sie jederzeit
und beliebig oft laufen lassen, ohne etwas kaputt zu machen.

In SSMS öffnen oder per Eingabeaufforderung, z. B.:
```cmd
sqlcmd -S .\SQLEXPRESS -E -i sql\diagnose\02_wait_stats.sql -o wait_stats.txt
```

Reihenfolge bei Langsamkeit:
1. `sql/diagnose/01_server_config_check.sql` – Grundeinstellungen (häufigster Fund: Arbeitsspeicher nicht begrenzt, oder Express am 10-GB-Limit).
2. `sql/diagnose/02_wait_stats.sql` – worauf wartet die Datenbank? (Festplatte / CPU / Blockaden).
3. `sql/diagnose/03_file_io_latency.sql` – Festplatte schnell genug? (gut < 10 ms, ab > 20 ms = Storage-Problem).
4. `powershell/Get-JtlServerHealthReport.ps1` – Gesamtbild als HTML-Report (CPU, RAM, Dienste, Eventlog).

### Schritt 2 – Wartung einrichten (einmalig, richtet Automatik ein)
Hier entscheidet sich, **welche Variante** zu deinem Server passt. Wenn du es nicht weißt:
Schritt 1 (`01_server_config_check.sql`) zeigt dir die **Edition** an.

- **„Express"** in der Edition? → **Variante B** (kein Auftragsplaner in Express, läuft über Windows-Aufgaben).
- **„Standard"/„Web"/„Enterprise"**? → **Variante A** (über den SQL Server Agent).

(Details unten unter „Wartung einrichten".)

### Schritt 3 – Regelmäßig draufschauen
Den Health-Report ab und zu ansehen, Backups stichprobenartig prüfen. Fertig.

---

## Wichtig: Was ist gefahrlos, was verändert etwas?

Es läuft **nichts von allein**. Jede Änderung passiert nur, wenn *du* ein Skript bewusst startest.

| Skript | Was es tut | Verändert es etwas? |
|---|---|---|
| `sql/diagnose/*` | Server analysieren | **Nein** – reine Anzeige, beliebig oft ausführbar |
| `Get-JtlServerHealthReport.ps1` | HTML-Bericht erstellen | **Nein** – liest nur (legt nur den Report-Ordner an) |
| `Invoke-JtlCleanup.ps1` | Temp/Logs aufräumen | **Vorschau** – zeigt erst nur an; löscht **erst mit `-Execute`** |
| `Setup-SqlAgentJobs-Standard.sql` | Backup-/Wartungs-Zeitpläne anlegen | **Ja** – richtet wiederkehrende SQL-Jobs ein |
| `Install-MaintenanceSolution-Express.ps1` | Wartung auf Express einrichten | **Ja** – installiert Prozeduren + Windows-Aufgaben |
| `Register-JtlScheduledTasks.ps1` | Report + Cleanup einplanen | **Ja** – plant u. a. monatliches Aufräumen **scharf** (mit `-Execute`) |
| `Schedule-JtlReboot.ps1` | Geplanten Neustart einrichten | **Ja** – legt wiederkehrenden Server-Neustart an |

Merksatz:
- **Schritt-1-Skripte** kannst du bedenkenlos ausprobieren.
- **Schritt-2-Skripte** richten Automatik ein. Sie fragen *im Skript* nicht noch einmal nach –
  **der Start ist die Zusage.** Einmal in Ruhe lesen, was sie anlegen, dann ausführen.

---

## Wartung einrichten

### Variante A – SQL Server Standard (dedizierter DB-Server, mit SQL Agent)
1. `MaintenanceSolution.sql` von <https://ola.hallengren.com> herunterladen
   (Industriestandard, kostenlos) und in SSMS gegen die `master`-Datenbank ausführen –
   mit `@CreateJobs = 'Y'` und gesetztem Backup-Verzeichnis.
2. `sql/setup/Setup-SqlAgentJobs-Standard.sql` ausführen → legt die Zeitpläne an:
   FULL-Backup täglich 02:00, Indexpflege täglich 03:00, CHECKDB sonntags 04:00.

### Variante B – SQL Server Express (lokal, ohne SQL Agent)
Express hat keinen Auftragsplaner – die Wartung läuft hier über Windows-Aufgaben:
```powershell
.\powershell\Install-MaintenanceSolution-Express.ps1 `
    -SqlInstance ".\SQLEXPRESS" `
    -BackupDirectory "D:\SQLBackup" `
    -MaintenanceSolutionPath "C:\temp\MaintenanceSolution.sql"
```
Legt dieselbe Wartung als Windows-Aufgaben (`JTL_SQL_*`) an.

### Windows-Aufgaben (für beide Varianten sinnvoll)
```powershell
.\powershell\Register-JtlScheduledTasks.ps1 -SqlInstance ".\SQLEXPRESS"   # Health-Report + Cleanup
.\powershell\Schedule-JtlReboot.ps1 -Schedule Monthly -DayOfMonth 7 -At 03:00
```

### Dauer-Monitor (CPU/RAM/Disk/Top-Prozesse, tageweise CSV)
Für Fälle, in denen Probleme „immer mal" auftreten und niemand den Moment live erwischt:
Der Monitor sampelt im Hintergrund (Standard alle 60 s) und schreibt CSV-Dateien je Tag.
Auswertung anschließend in Excel.
```powershell
# einmalig einrichten (als Administrator) - laeuft danach als Aufgabe unter SYSTEM,
# ueberlebt Logoff/Reboot, startet bei Fehler neu:
.\powershell\Register-JtlMonitorTask.ps1                          # ohne SQL (z. B. direct)
.\powershell\Register-JtlMonitorTask.ps1 -SqlInstance ".\JTLWAWI" # mit SQL-Live-Daten (z. B. inlet)
```
CSV-Dateien liegen unter `C:\JTL-Wartung\monitor\` und werden nach 14 Tagen automatisch
aufgeräumt.

> PowerShell **als Administrator** starten. Falls die Ausführung blockiert wird:
> `powershell -ExecutionPolicy Bypass -File <Skript>`

---

## Empfohlener Rhythmus

| Aufgabe | Wie oft | Womit | Verändert? |
|---|---|---|:--:|
| FULL-Backup | täglich (nachts) | Ola Hallengren (Agent / Aufgabe) | ✅ |
| Index- & Statistikpflege | täglich (nachts) | Ola Hallengren | ✅ |
| Integritätsprüfung (CHECKDB) | wöchentlich | Ola Hallengren | ✅ |
| Health-Report (HTML) | wöchentlich | `Get-JtlServerHealthReport.ps1` | – |
| Temp-/Log-Bereinigung | monatlich | `Invoke-JtlCleanup.ps1` | ✅ (mit `-Execute`) |
| Windows Update + Reboot | monatlich (nach Patchday) | `Schedule-JtlReboot.ps1` | ✅ |
| Reboot bei reinem RDP-Server | ggf. wöchentlich | `Schedule-JtlReboot.ps1 -Schedule Weekly` | ✅ |
| Lage prüfen / Engpass suchen | bei Bedarf | `sql/diagnose/*` | – |
| Last & Verursacher mitschreiben | dauerhaft im Hintergrund | `Register-JtlMonitorTask.ps1` | – (nur Logs) |
| JTL-eigene „Datenbankwartung" | monatlich / bei Bedarf | in JTL-Wawi | ✅ |

„✅" = richtet etwas ein bzw. ändert etwas · „–" = reine Analyse, ungefährlich.

---

## Was im Ordner liegt

```
jtl-wartung/
├─ powershell/
│  ├─ Get-JtlServerHealthReport.ps1            # HTML-Gesundheitsbericht (read-only)
│  ├─ Start-JtlMonitor.ps1                     # Dauer-Monitor (CSV je Tag, read-only)
│  ├─ Register-JtlMonitorTask.ps1              # Monitor als Aufgabe unter SYSTEM einrichten
│  ├─ Invoke-JtlCleanup.ps1                    # Temp-/Log-Bereinigung (Vorschau, dann -Execute)
│  ├─ Schedule-JtlReboot.ps1                   # Geplanter, gewarnter Neustart
│  ├─ Install-MaintenanceSolution-Express.ps1  # Ola Hallengren + Aufgabenplanung (EXPRESS)
│  └─ Register-JtlScheduledTasks.ps1           # Health-Report + Cleanup einplanen
└─ sql/
   ├─ diagnose/                                # read-only Analyse (SSMS oder sqlcmd)
   │  ├─ 01_server_config_check.sql            # Speicher, Edition, MAXDOP, tempdb
   │  ├─ 02_wait_stats.sql                     # worauf wartet SQL? (wichtigste Analyse)
   │  ├─ 03_file_io_latency.sql                # Festplatten-Latenz je DB-Datei
   │  ├─ 04_index_fragmentation.sql            # Fragmentierung (aktuelle DB)
   │  ├─ 05_missing_indexes.sql                # fehlende Indizes + Blocking
   │  └─ 06_db_size_and_growth.sql             # DB-Größen, Autogrowth, Express-10-GB-Check
   └─ setup/
      └─ Setup-SqlAgentJobs-Standard.sql       # SQL-Agent-Zeitpläne (STANDARD)
```

---

## Gute zu wissen

- **Express-Grenzen:** kein SQL Agent, max. 10 GB pro Datenbank, ~1,4 GB Arbeitsspeicher,
  max. 4 Kerne. Bei dauerhafter Langsamkeit lohnt der Wechsel auf Standard.
- **Virenscanner:** `.mdf`/`.ldf`/`.ndf` und JTL-Verzeichnisse von der Echtzeitprüfung ausnehmen.
- **Energieplan** auf „Höchstleistung" stellen (`powercfg /setactive SCHEME_MIN`).
- **Index-Vorschläge** aus `05_missing_indexes.sql` **nicht blind** übernehmen – bei JTL im Zweifel
  mit dem JTL-Support abstimmen.
- **Zeiten anpassen:** Backup- und Reboot-Zeiten in den Skripten an euer Wartungsfenster legen.
- **Wieder entfernen:** Geplante Aufgaben lassen sich rückstandslos löschen, z. B.
  `Unregister-ScheduledTask -TaskName JTL_GeplanterNeustart`.

---

## Rechtliches

Bereitstellung **ohne Gewähr und ohne Haftung** (siehe Hinweis oben). Nutzung auf eigene Gefahr.
Die Wartungslösung **MaintenanceSolution.sql** stammt von [Ola Hallengren](https://ola.hallengren.com)
und unterliegt deren eigener Lizenz; sie ist hier **nicht** enthalten und muss separat geladen werden.
„JTL-Wawi" ist ein Produkt der JTL-Software GmbH, „SQL Server" ein Produkt von Microsoft –
beide stehen in keiner Verbindung zu diesem Repository.
