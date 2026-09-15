----Point 1: TempDB Multi-AZ Sync Status & HADR Behavior

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    d.name AS [Database_Name],
    d.state_desc AS [Database_State],
    d.recovery_model_desc AS [Recovery_Model],
    ISNULL(CAST(hadr.is_local AS VARCHAR(5)), 'N/A') AS [Is_Local],
    ISNULL(CAST(hadr.is_primary_replica AS VARCHAR(5)), 'N/A') AS [Is_Primary_Replica],
    ISNULL(hadr.synchronization_state_desc, 'STANDALONE / NOT IN HADR') AS [Sync_State],
    CASE 
        WHEN d.name = 'tempdb' THEN 'Local Scratch DB (Never Replicated in Multi-AZ)'
        WHEN hadr.synchronization_state_desc IS NOT NULL THEN 'Replicated in Multi-AZ'
        ELSE 'Standalone Database'
    END AS [Multi_AZ_Behavior_Note]
FROM sys.databases d WITH (NOLOCK)
LEFT JOIN sys.dm_hadr_database_replica_states hadr 
    ON d.database_id = hadr.database_id AND hadr.is_local = 1
ORDER BY (CASE WHEN d.name = 'tempdb' THEN 0 ELSE 1 END), d.name;
-----Point 2: TempDB Data Files Sizing & Uniformity (Proportional Fill)


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    df.file_id AS [File_ID],
    df.name AS [Logical_Name],
    df.type_desc AS [File_Type],
    (df.size * 8) / 1024 AS [Size_MB],
    CASE 
        WHEN df.is_percent_growth = 1 THEN CAST(df.growth AS VARCHAR(10)) + '%'
        ELSE CAST((df.growth * 8) / 1024 AS VARCHAR(10)) + ' MB'
    END AS [Autogrowth_Setting],
    CASE 
        WHEN (SELECT COUNT(DISTINCT size) FROM tempdb.sys.database_files WITH (NOLOCK) WHERE type_desc = 'ROWS') = 1 
        THEN 'EQUAL SIZING (Optimal Proportional Fill)'
        ELSE 'MISMATCHED SIZING (Resize all data files to same size)'
    END AS [Sizing_Status]
FROM tempdb.sys.database_files df WITH (NOLOCK)
WHERE df.type_desc = 'ROWS'
ORDER BY df.file_id;
----Point 3: Logical vCPU Count vs. Total TempDB Data Files (Scale to 8)

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    osi.cpu_count AS [Logical_vCPUs],
    (SELECT COUNT(*) FROM tempdb.sys.database_files WITH (NOLOCK) WHERE type_desc = 'ROWS') AS [Current_TempDB_Data_Files],
    8 AS [Target_Recommended_Files],
    CASE 
        WHEN (SELECT COUNT(*) FROM tempdb.sys.database_files WITH (NOLOCK) WHERE type_desc = 'ROWS') = 8 
        THEN 'OPTIMAL (Configured with 8 Data Files)'
        WHEN (SELECT COUNT(*) FROM tempdb.sys.database_files WITH (NOLOCK) WHERE type_desc = 'ROWS') < 8 
        THEN 'ACTION REQUIRED: Add Data Files to reach 8 total files'
        ELSE 'NOTICE: More than 8 Data Files present'
    END AS [File_Count_Recommendation]
FROM sys.dm_os_sys_info osi;
-----Point 4: Additional Storage Volume for Archived Database


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    d.name AS [Database_Name],
    mf.name AS [Logical_File_Name],
    mf.type_desc AS [File_Type],
    LEFT(mf.physical_name, 3) AS [Drive_Volume],
    mf.physical_name AS [Full_Physical_Path],
    (CAST(mf.size AS BIGINT) * 8) / 1024 AS [Size_MB],
    CASE 
        WHEN d.name LIKE '%archive%' OR d.name LIKE '%history%' OR d.name LIKE '%old%' 
        THEN 'PRIMARY ARCHIVE CANDIDATE (Migrate to lower-cost volume)'
        ELSE 'Standard Database'
    END AS [Archive_Volume_Suitability]
FROM sys.master_files mf WITH (NOLOCK)
JOIN sys.databases d WITH (NOLOCK) ON mf.database_id = d.database_id
ORDER BY [Archive_Volume_Suitability] DESC, [Size_MB] DESC;
-----Point 5: Table Compression & Partitioning for Large/Archived Tables


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT TOP 20
    DB_NAME() AS [Database_Name],
    s.name AS [Schema_Name],
    t.name AS [Table_Name],
    p.partition_number AS [Partition_No],
    p.rows AS [Row_Count],
    p.data_compression_desc AS [Current_Compression],
    (SUM(a.total_pages) * 8) / 1024 AS [Total_Space_MB],
    (SUM(a.used_pages) * 8) / 1024 AS [Used_Space_MB],
    CASE 
        WHEN p.data_compression_desc = 'NONE' AND (SUM(a.total_pages) * 8) / 1024 > 1000 
        THEN 'HIGH PRIORITY: Implement PAGE Compression & Partitioning'
        WHEN p.data_compression_desc = 'NONE' AND (SUM(a.total_pages) * 8) / 1024 > 250 
        THEN 'MEDIUM PRIORITY: Evaluate PAGE Compression'
        ELSE 'COMPRESSED / NORMAL'
    END AS [Compression_Advice]
FROM sys.tables t WITH (NOLOCK)
JOIN sys.schemas s WITH (NOLOCK) ON t.schema_id = s.schema_id
JOIN sys.partitions p WITH (NOLOCK) ON t.object_id = p.object_id
JOIN sys.allocation_units a WITH (NOLOCK) ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name, p.partition_number, p.rows, p.data_compression_desc
ORDER BY [Total_Space_MB] DESC;
----Point 6: Filegroups for Data & Index Isolation


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    DB_NAME() AS [Database_Name],
    fg.name AS [Filegroup_Name],
    fg.is_default AS [Is_Default_FG],
    COUNT(DISTINCT t.object_id) AS [Tables_Count],
    COUNT(DISTINCT i.index_id) AS [Indexes_Count],
    CASE 
        WHEN fg.name = 'PRIMARY' AND COUNT(DISTINCT i.index_id) > 10 
        THEN 'RECOMMENDATION: Separate Non-Clustered Indexes to dedicated FG (e.g. FG_INDEX)'
        ELSE 'Filegroup Layout Active'
    END AS [Filegroup_Status]
FROM sys.filegroups fg WITH (NOLOCK)
LEFT JOIN sys.allocation_units a WITH (NOLOCK) ON fg.data_space_id = a.data_space_id
LEFT JOIN sys.partitions p WITH (NOLOCK) ON a.container_id = p.partition_id
LEFT JOIN sys.tables t WITH (NOLOCK) ON p.object_id = t.object_id AND t.is_ms_shipped = 0
LEFT JOIN sys.indexes i WITH (NOLOCK) ON p.object_id = i.object_id AND p.index_id = i.index_id
GROUP BY fg.name, fg.is_default;
----Point 7: Resource Governor Pools & Usage Limits per Application


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    rgc.is_enabled AS [Is_Resource_Governor_Enabled],
    ISNULL(OBJECT_SCHEMA_NAME(rgc.classifier_function_id) + '.' + OBJECT_NAME(rgc.classifier_function_id), 'NONE') AS [Classifier_Function],
    rp.pool_id AS [Pool_ID],
    rp.name AS [Pool_Name],
    rp.min_cpu_percent AS [Min_CPU_Percent],
    rp.max_cpu_percent AS [Max_CPU_Percent],
    rp.cap_cpu_percent AS [Cap_CPU_Percent],
    rp.min_memory_percent AS [Min_Memory_Percent],
    rp.max_memory_percent AS [Max_Memory_Percent],
    CASE 
        WHEN rgc.is_enabled = 0 THEN 'DISABLED: Enable to cap high-load application pools'
        ELSE 'ACTIVE: Review workload pool limits'
    END AS [Action_Status]
FROM sys.resource_governor_configuration rgc
CROSS JOIN sys.resource_governor_resource_pools rp;
----Point 8: Filegroups for Temporary/Staging Tables & Backup Strategy


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    DB_NAME() AS [Database_Name],
    fg.name AS [Filegroup_Name],
    df.name AS [Logical_File_Name],
    df.physical_name AS [File_Path],
    (df.size * 8) / 1024 AS [Size_MB],
    CASE 
        WHEN fg.name LIKE '%stage%' OR fg.name LIKE '%temp%' OR fg.name LIKE '%load%'
        THEN 'DEDICATED STAGING FILEGROUP (Excludable from Piecemeal Backup)'
        ELSE 'STANDARD OLTP FILEGROUP'
    END AS [Filegroup_Role]
FROM sys.filegroups fg WITH (NOLOCK)
JOIN sys.database_files df WITH (NOLOCK) ON fg.data_space_id = df.data_space_id;
-----Point 9: Data Masking (DDM) & Database Encryption (TDE)


SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- 9A: Transparent Data Encryption (TDE) Check
SELECT 
    d.name AS [Database_Name],
    CASE k.encryption_state
        WHEN 0 THEN '0: No Encryption Key'
        WHEN 1 THEN '1: Unencrypted'
        WHEN 2 THEN '2: Encryption In Progress'
        WHEN 3 THEN '3: Fully Encrypted (TDE Active)'
        WHEN 4 THEN '4: Key Change In Progress'
        WHEN 5 THEN '5: Decryption In Progress'
        WHEN 6 THEN '6: Protection Change In Progress'
        ELSE 'NOT CONFIGURED'
    END AS [TDE_Encryption_State],
    ISNULL(k.encryptor_type, 'NONE') AS [Encryptor_Type]
FROM sys.databases d WITH (NOLOCK)
LEFT JOIN sys.dm_database_encryption_keys k 
    ON d.database_id = k.database_id
ORDER BY d.name;

-- 9B: Dynamic Data Masking (DDM) Columns Check in Current DB
SELECT 
    DB_NAME() AS [Database_Name],
    s.name AS [Schema_Name],
    t.name AS [Table_Name],
    c.name AS [Masked_Column_Name],
    mc.masking_function AS [Masking_Function_Applied]
FROM sys.masked_columns mc WITH (NOLOCK)
JOIN sys.tables t WITH (NOLOCK) ON mc.object_id = t.object_id
JOIN sys.schemas s WITH (NOLOCK) ON t.schema_id = s.schema_id
JOIN sys.columns c WITH (NOLOCK) ON mc.object_id = c.object_id AND mc.column_id = c.column_id;
-----Point 10: TempDB Physical Location (Instance Store NVMe vs. EBS)

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    df.file_id AS [File_ID],
    df.name AS [Logical_Name],
    df.physical_name AS [Physical_Path],
    (df.size * 8) / 1024 AS [Size_MB],
    CASE 
        WHEN df.physical_name LIKE 'D:\%' THEN 'LOCAL NVMe SSD (Instance Store - Optimal)'
        ELSE 'STANDARD EBS VOLUME (Consider migrating to db.r6id / db.m6id)'
    END AS [Storage_Tier_Assessment]
FROM tempdb.sys.database_files df WITH (NOLOCK);
-----Point 11: Multi-Volume Storage Separation & I/O Latency Diagnostics

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT 
    DB_NAME(vfs.database_id) AS [Database_Name],
    mf.name AS [Logical_File_Name],
    mf.type_desc AS [File_Type],
    LEFT(mf.physical_name, 3) AS [Drive_Volume],
    vfs.num_of_reads AS [Total_Reads],
    vfs.num_of_writes AS [Total_Writes],
    CASE WHEN vfs.num_of_reads = 0 THEN 0 ELSE (vfs.io_stall_read_ms / vfs.num_of_reads) END AS [Avg_Read_Latency_ms],
    CASE WHEN vfs.num_of_writes = 0 THEN 0 ELSE (vfs.io_stall_write_ms / vfs.num_of_writes) END AS [Avg_Write_Latency_ms],
    CASE 
        WHEN mf.type_desc = 'LOG' AND (CASE WHEN vfs.num_of_writes = 0 THEN 0 ELSE (vfs.io_stall_write_ms / vfs.num_of_writes) END) > 5 
        THEN 'HIGH LOG LATENCY: Candidate for Dedicated High-IOPS Log Volume'
        WHEN DB_NAME(vfs.database_id) LIKE '%archive%' OR DB_NAME(vfs.database_id) LIKE '%history%'
        THEN 'ARCHIVE DB: Candidate for Low-Cost Secondary Volume'
        ELSE 'Normal Layout'
    END AS [Multi_Volume_Recommendation]
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf WITH (NOLOCK)
    ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE vfs.num_of_reads > 0 OR vfs.num_of_writes > 0
ORDER BY [Avg_Write_Latency_ms] DESC;
