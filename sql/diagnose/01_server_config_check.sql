/*
============================================================================
 01 - Server-Konfiguration pruefen
============================================================================
 Findet die haeufigsten Fehlkonfigurationen, die JTL-Wawi ausbremsen:
 - max server memory nicht gesetzt (SQL frisst allen RAM)
 - Edition / Express-Limits
 - MAXDOP / Cost Threshold for Parallelism
 - tempdb-Konfiguration (Anzahl Dateien)
 Read-only. Ausfuehren in der jeweiligen SQL-Instanz.
============================================================================
*/
SET NOCOUNT ON;

PRINT '=== Version & Edition ===';
SELECT
    SERVERPROPERTY('ProductVersion')      AS ProductVersion,
    SERVERPROPERTY('ProductLevel')        AS ProductLevel,
    SERVERPROPERTY('Edition')             AS Edition,
    SERVERPROPERTY('IsHadrEnabled')       AS IsHadrEnabled,
    SERVERPROPERTY('MachineName')         AS MachineName,
    SERVERPROPERTY('InstanceName')        AS InstanceName;

/* Express: max ~1,4 GB Buffer Pool, 10 GB pro DB, max 4 Kerne / 1 Socket, KEIN SQL Agent.
   Wenn hier "Express" steht, sind das die wahrscheinlichen Engpaesse. */

PRINT '=== Speicher: physisch vs. fuer SQL konfiguriert ===';
SELECT
    total_physical_memory_kb / 1024            AS PhysRAM_MB,
    available_physical_memory_kb / 1024        AS PhysRAM_frei_MB,
    system_memory_state_desc                   AS SpeicherStatus
FROM sys.dm_os_sys_memory;

SELECT
    [name]                                     AS Einstellung,
    CAST(value      AS BIGINT)                 AS Konfiguriert,
    CAST(value_in_use AS BIGINT)               AS InVerwendung
FROM sys.configurations
WHERE name IN (
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads'
)
ORDER BY name;

/* Empfehlung:
   - 'max server memory (MB)' MUSS gesetzt sein. Standard 2147483647 = unbegrenzt = Problem.
     Faustregel auf kombiniertem Server (RDP + SQL): Gesamt-RAM minus Reserve fuer
     Windows + RDP-Sessions + JTL-Wawi. Z. B. 32 GB RAM, dann SQL ~16-20 GB.
   - 'cost threshold for parallelism' Standard 5 ist zu niedrig -> 50 setzen.
   - 'optimize for ad hoc workloads' auf 1 setzen (entlastet Plan-Cache). */

PRINT '=== tempdb-Dateien (Anzahl sollte bei Mehrkern-CPU > 1 sein) ===';
SELECT
    f.name          AS LogischerName,
    f.physical_name AS Pfad,
    f.size * 8 / 1024 AS Groesse_MB,
    CASE f.is_percent_growth WHEN 1 THEN CAST(f.growth AS VARCHAR) + ' %'
         ELSE CAST(f.growth * 8 / 1024 AS VARCHAR) + ' MB' END AS Autogrowth
FROM sys.master_files f
WHERE f.database_id = DB_ID('tempdb');

/* Empfehlung: 4-8 gleich grosse Datendateien fuer tempdb (max = Anzahl Kerne, Deckel 8).
   Autogrowth NICHT in Prozent, sondern feste MB-Schritte. */
