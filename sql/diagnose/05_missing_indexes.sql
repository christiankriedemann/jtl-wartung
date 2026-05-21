/*
============================================================================
 05 - Fehlende Indizes & teure laufende Abfragen
============================================================================
 Teil A: vom Optimizer vorgeschlagene fehlende Indizes (nach Wirkung sortiert).
 Teil B: aktuell laufende Abfragen + Blocking (Live-Bild bei Beschwerden "haengt").
 Read-only.
 WICHTIG: Index-Vorschlaege NICHT blind uebernehmen. Bei JTL-Wawi koennen eigene
 Indizes Probleme bei Updates verursachen. Im Zweifel mit JTL-Support abstimmen.
============================================================================
*/
SET NOCOUNT ON;

PRINT '=== Teil A: Vorgeschlagene fehlende Indizes (Top 20 nach Nutzen) ===';
SELECT TOP 20
    DB_NAME(mid.database_id)                              AS Datenbank,
    OBJECT_NAME(mid.object_id, mid.database_id)           AS Tabelle,
    CAST(migs.avg_total_user_cost
         * migs.avg_user_impact
         * (migs.user_seeks + migs.user_scans) AS DECIMAL(18,1)) AS GeschaetzterNutzen,
    migs.user_seeks + migs.user_scans                     AS ZugriffeSeitNeustart,
    CAST(migs.avg_user_impact AS DECIMAL(5,1))            AS Verbesserung_Prozent,
    mid.equality_columns                                  AS Gleichheitsspalten,
    mid.inequality_columns                                AS Ungleichheitsspalten,
    mid.included_columns                                  AS EingeschlosseneSpalten
FROM sys.dm_db_missing_index_groups AS mig
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details     AS mid  ON mig.index_handle  = mid.index_handle
ORDER BY GeschaetzterNutzen DESC;

PRINT '=== Teil B: Aktuell laufende Abfragen ===';
SELECT
    r.session_id                                          AS Sitzung,
    r.status                                              AS Status,
    r.blocking_session_id                                 AS BlockiertVon,
    r.wait_type                                           AS WaitTyp,
    r.wait_time / 1000.0                                  AS Wartezeit_s,
    r.cpu_time                                            AS CPU_ms,
    r.total_elapsed_time / 1000.0                         AS Laufzeit_s,
    DB_NAME(r.database_id)                                AS Datenbank,
    SUBSTRING(t.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS AktuellesStatement
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID
  AND r.session_id > 50
ORDER BY r.total_elapsed_time DESC;
