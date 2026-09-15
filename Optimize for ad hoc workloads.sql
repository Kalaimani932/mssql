------To find the number of single-use cached plans, enter the following query:

SELECT objtype,
 cacheobjtype, 
SUM(refcounts),
  AVG(usecounts), 
  SUM(CAST(size_in_bytes AS bigint))/1024/1024 AS Size_MB
FROM sys.dm_exec_cached_plans
WHERE usecounts = 1 AND objtype = 'Adhoc'
GROUP BY cacheobjtype, objtype
