/*
============================================================================
 03 - Datei-I/O-Latenz pro Datenbankdatei
============================================================================
 Zeigt, wie schnell/langsam die Platten je mdf/ldf-Datei antworten.
 Read-only. Kumuliert seit SQL-Neustart.
 Richtwerte Lese-/Schreiblatenz:
   < 10 ms  = gut
   10-20 ms = grenzwertig
   > 20 ms  = Problem (Storage zu langsam / ueberlastet)
============================================================================
*/
SET NOCOUNT ON;

SELECT
    DB_NAME(vfs.database_id)                                          AS Datenbank,
    mf.name                                                          AS LogischerName,
    mf.type_desc                                                     AS Typ,
    mf.physical_name                                                 AS Pfad,
    vfs.num_of_reads                                                 AS Lesevorgaenge,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads,0)  AS DECIMAL(10,1)) AS Avg_Leselatenz_ms,
    vfs.num_of_writes                                               AS Schreibvorgaenge,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes,0) AS DECIMAL(10,1)) AS Avg_Schreiblatenz_ms,
    CAST((vfs.num_of_bytes_read + vfs.num_of_bytes_written) / 1024.0 / 1024 AS DECIMAL(18,1)) AS IO_gesamt_MB
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON vfs.database_id = mf.database_id
 AND vfs.file_id     = mf.file_id
ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;

/* Bei getrenntem DB-Server (e-comdata Datenbank-Server): hohe Latenz hier deutet auf
   Storage-/SAN-Engpass hin. Bei lokaler Express auf dem RDP-Server: oft konkurriert
   die DB-Platte mit Windows + Benutzersitzungen -> ggf. DB auf eigene SSD legen. */
