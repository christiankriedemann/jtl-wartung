/*
============================================================================
 SETUP (Standard/Web-Edition mit SQL Agent) - Ola Hallengren Maintenance
============================================================================
 Gilt fuer den dedizierten DB-Server (e-comdata) mit voller SQL-Server-Edition.
 NICHT fuer Express (dort kein SQL Agent -> siehe
 powershell/Install-MaintenanceSolution-Express.ps1).

 ----------------------------------------------------------------------------
 SCHRITT 1: Wartungsloesung installieren
 ----------------------------------------------------------------------------
 Lade MaintenanceSolution.sql von https://ola.hallengren.com herunter.
 (Industriestandard, kostenlos, von Microsoft-MVPs gepflegt.)

 Oeffne die Datei in SSMS und passe oben die Backup-Variable an:
     SET @CreateJobs        = 'Y';   -- legt SQL-Agent-Jobs automatisch an
     SET @BackupDirectory   = N'D:\SQLBackup';   -- existierendes Verzeichnis!
     SET @CleanupTime       = 168;   -- Backups aelter als 168 h (7 Tage) loeschen
 Dann gegen die master-Datenbank ausfuehren. Es entstehen u. a. die Jobs:
     - DatabaseBackup - USER_DATABASES - FULL
     - DatabaseBackup - USER_DATABASES - LOG
     - DatabaseIntegrityCheck - USER_DATABASES        (DBCC CHECKDB)
     - IndexOptimize - USER_DATABASES                 (Index + Statistik)
     - CommandLog Cleanup / Output File Cleanup

 ----------------------------------------------------------------------------
 SCHRITT 2: Zeitplaene anlegen (unten ausfuehren, NACH Schritt 1)
 ----------------------------------------------------------------------------
 Empfohlener Rhythmus fuer JTL-Wawi (nachts, ausserhalb der Arbeitszeit):
   - FULL-Backup            taeglich   02:00
   - LOG-Backup             stuendlich (nur bei Recovery-Modell FULL; JTL nutzt
                            i. d. R. SIMPLE -> dann LOG-Backup weglassen)
   - IndexOptimize          taeglich   03:00
   - IntegrityCheck (CHECKDB) woechentlich So 04:00
============================================================================
*/
USE msdb;
GO
SET NOCOUNT ON;

/* Zeitplan: taegliches FULL-Backup 02:00 */
IF NOT EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name = N'JTL_Daily_0200')
    EXEC dbo.sp_add_schedule
        @schedule_name = N'JTL_Daily_0200',
        @freq_type = 4,                 -- taeglich
        @freq_interval = 1,
        @active_start_time = 020000;    -- 02:00:00
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - FULL')
    EXEC dbo.sp_attach_schedule
        @job_name = N'DatabaseBackup - USER_DATABASES - FULL',
        @schedule_name = N'JTL_Daily_0200';
GO

/* Zeitplan: taegliche Index-/Statistikpflege 03:00 */
IF NOT EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name = N'JTL_Daily_0300')
    EXEC dbo.sp_add_schedule
        @schedule_name = N'JTL_Daily_0300',
        @freq_type = 4, @freq_interval = 1,
        @active_start_time = 030000;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'IndexOptimize - USER_DATABASES')
    EXEC dbo.sp_attach_schedule
        @job_name = N'IndexOptimize - USER_DATABASES',
        @schedule_name = N'JTL_Daily_0300';
GO

/* Zeitplan: woechentlicher Integritaetscheck So 04:00 */
IF NOT EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name = N'JTL_Weekly_Sun_0400')
    EXEC dbo.sp_add_schedule
        @schedule_name = N'JTL_Weekly_Sun_0400',
        @freq_type = 8,                 -- woechentlich
        @freq_interval = 1,             -- Sonntag (1 = So)
        @freq_recurrence_factor = 1,
        @active_start_time = 040000;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DatabaseIntegrityCheck - USER_DATABASES')
    EXEC dbo.sp_attach_schedule
        @job_name = N'DatabaseIntegrityCheck - USER_DATABASES',
        @schedule_name = N'JTL_Weekly_Sun_0400';
GO

PRINT 'Zeitplaene angelegt. Pruefen unter: SQL Server Agent > Jobs.';
GO
