/*
============================================================================
 04 - Index-Fragmentierung (aktuelle Datenbank)
============================================================================
 Vorher die JTL-Datenbank waehlen, z. B.:   USE eazybusiness;
 Read-only (zeigt nur an). Behebung uebernimmt die Wartungsloesung (Ola Hallengren).
 Faustregel:
   5-30 %  Fragmentierung -> REORGANIZE
   > 30 %                 -> REBUILD
 Kleine Indizes (< 1000 Seiten) werden ignoriert (lohnt nicht).
============================================================================
*/
SET NOCOUNT ON;

SELECT
    DB_NAME()                                           AS Datenbank,
    OBJECT_SCHEMA_NAME(ips.object_id)                   AS [Schema],
    OBJECT_NAME(ips.object_id)                          AS Tabelle,
    i.name                                              AS Indexname,
    ips.index_type_desc                                 AS IndexTyp,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1)) AS Fragmentierung_Prozent,
    ips.page_count                                      AS Seiten,
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent > 5  THEN 'REORGANIZE'
        ELSE 'ok'
    END                                                 AS Empfehlung
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i
  ON ips.object_id = i.object_id
 AND ips.index_id  = i.index_id
WHERE ips.page_count > 1000
  AND ips.avg_fragmentation_in_percent > 5
  AND i.name IS NOT NULL
ORDER BY ips.avg_fragmentation_in_percent DESC;

/* Hinweis: Auf Express ist ONLINE-Rebuild nicht verfuegbar -> Rebuilds nur in
   einem Wartungsfenster (nachts), da Tabellen waehrenddessen gesperrt werden. */
