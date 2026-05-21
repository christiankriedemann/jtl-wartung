/*
============================================================================
 06 - Datenbankgroessen, Dateiwachstum & Express-Limit-Check
============================================================================
 Read-only. Zeigt Groesse je Datenbank/Datei, freien Platz und Autogrowth.
 Besonders relevant fuer die lokale Express-Instanz (10-GB-Limit pro DB!).
============================================================================
*/
SET NOCOUNT ON;

PRINT '=== Groesse je Datenbank ===';
SELECT
    DB_NAME(database_id)                                  AS Datenbank,
    CAST(SUM(CASE WHEN type = 0 THEN size END) * 8 / 1024.0 AS DECIMAL(18,1)) AS Daten_MB,
    CAST(SUM(CASE WHEN type = 1 THEN size END) * 8 / 1024.0 AS DECIMAL(18,1)) AS Log_MB,
    CAST(SUM(size) * 8 / 1024.0 AS DECIMAL(18,1))         AS Gesamt_MB
FROM sys.master_files
GROUP BY database_id
ORDER BY Gesamt_MB DESC;

PRINT '=== Datei-Details: belegt vs. frei + Autogrowth ===';
SELECT
    DB_NAME()                                             AS Datenbank,
    f.name                                                AS LogischerName,
    f.type_desc                                           AS Typ,
    CAST(f.size * 8 / 1024.0 AS DECIMAL(18,1))            AS ReserviertMB,
    CAST(FILEPROPERTY(f.name,'SpaceUsed') * 8 / 1024.0 AS DECIMAL(18,1)) AS BelegtMB,
    CAST((f.size - FILEPROPERTY(f.name,'SpaceUsed')) * 8 / 1024.0 AS DECIMAL(18,1)) AS FreiMB,
    CASE f.is_percent_growth WHEN 1 THEN CAST(f.growth AS VARCHAR)+' %'
         ELSE CAST(f.growth * 8 / 1024 AS VARCHAR)+' MB' END AS Autogrowth,
    CASE f.max_size WHEN -1 THEN 'unbegrenzt'
         WHEN 268435456 THEN 'unbegrenzt'
         ELSE CAST(f.max_size * 8 / 1024 AS VARCHAR)+' MB' END AS MaxGroesse
FROM sys.database_files AS f;

/* Express-Warnung: Wenn Daten_MB der eazybusiness-DB Richtung 10240 MB (10 GB) geht,
   bremst das massiv und Schreibvorgaenge schlagen irgendwann fehl.
   Gegenmassnahmen: JTL-Datenbankwartung ausfuehren, Altdaten/Logs archivieren,
   oder auf SQL Server Standard wechseln.
   Autogrowth in % ist schlecht -> auf feste MB-Schritte umstellen (z. B. 256 MB). */
