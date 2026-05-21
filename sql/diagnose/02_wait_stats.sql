/*
============================================================================
 02 - Wait Stats: Worauf wartet der SQL Server?
============================================================================
 Die wichtigste Einzelanalyse. Zeigt, wo die Engpaesse liegen.
 Read-only. Werte sind kumuliert seit dem letzten SQL-Neustart.
============================================================================
 Deutung der haeufigsten Waits:
   PAGEIOLATCH_*   -> Disk zu langsam / zu wenig RAM (Daten muessen von Platte)
   WRITELOG        -> Transaktionslog-Disk zu langsam
   CXPACKET/CXCONSUMER -> Parallelitaet (MAXDOP / Cost Threshold pruefen)
   LCK_M_*         -> Blocking (sperrende Transaktionen, siehe Skript 05)
   SOS_SCHEDULER_YIELD -> CPU-Druck
   RESOURCE_SEMAPHORE  -> zu wenig Arbeitsspeicher fuer Abfragen
   ASYNC_NETWORK_IO    -> Client/Netzwerk langsam (bei getrenntem DB-Server relevant)
============================================================================
*/
SET NOCOUNT ON;

SELECT TOP 20
    wait_type                                                   AS WaitTyp,
    waiting_tasks_count                                         AS Anzahl,
    CAST(wait_time_ms / 1000.0 AS DECIMAL(18,1))                AS Wartezeit_s,
    CAST(signal_wait_time_ms / 1000.0 AS DECIMAL(18,1))         AS CPU_Wartezeit_s,
    CAST((wait_time_ms - signal_wait_time_ms) / 1000.0 AS DECIMAL(18,1)) AS Ressourcen_Wartezeit_s,
    CAST(100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS DECIMAL(5,2)) AS Anteil_Prozent
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    -- harmlose Hintergrund-Waits ausfiltern
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
    'BROKER_TO_FLUSH','BROKER_TRANSMITTER','CHECKPOINT_QUEUE',
    'CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT','DBMIRROR_EVENTS_QUEUE','DBMIRROR_WORKER_QUEUE',
    'DBMIRRORING_CMD','DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE',
    'EXECSYNC','FSAGENT','FT_IFTS_SCHEDULER_IDLE_WAIT','FT_IFTSHC_MUTEX',
    'HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','HADR_LOGCAPTURE_WAIT',
    'HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK','HADR_WORK_QUEUE',
    'KSOURCE_WAKEUP','LAZYWRITER_SLEEP','LOGMGR_QUEUE','MEMORY_ALLOCATION_EXT',
    'ONDEMAND_TASK_QUEUE','PARALLEL_REDO_DRAIN_WORKER','PARALLEL_REDO_LOG_CACHE',
    'PARALLEL_REDO_TRAN_LIST','PARALLEL_REDO_WORKER_SYNC','PARALLEL_REDO_WORKER_WAIT_WORK',
    'PREEMPTIVE_XE_GETTARGETSTATE','PWAIT_ALL_COMPONENTS_INITIALIZED',
    'PWAIT_DIRECTLOGCONSUMER_GETNEXT','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_SHUTDOWN_QUEUE','REDO_THREAD_PENDING_WORK','REQUEST_FOR_DEADLOCK_SEARCH',
    'RESOURCE_QUEUE','SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP',
    'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK','SLEEP_TASK',
    'SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT','SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','SQLTRACE_WAIT_ENTRIES',
    'WAIT_FOR_RESULTS','WAITFOR','WAITFOR_TASKSHUTDOWN','WAIT_XTP_HOST_WAIT',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_CKPT_CLOSE','XE_DISPATCHER_JOIN',
    'XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
)
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;

/* Tipp: Werte zuruecksetzen, um nur die letzten Stunden zu messen:
   DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);  -- benoetigt erhoehte Rechte */
