create procedure dbo.RestoreLinkedServerBackup @ServerName varchar(max)
    ,@DbName varchar(max)
    ,@Stats varchar(5) = 5
as

-- declare @ServerName as varchar(max) = ''
-- declare @DbName as varchar(max) = ''
-- declare @Stats varchar(5) = 5
declare @difflsn as numeric(25, 0)
declare @sql as nvarchar(max);

if OBJECT_ID('tempDB..#backups', 'U') is not null
    drop table #backups

if OBJECT_ID('tempDB..#restoreFile', 'U') is not null
    drop table #restoreFile

create table #backups (
    rw bigint
    ,physical_device_name nvarchar(max)
    ,checkpoint_lsn numeric(25, 0)
    ,differential_base_lsn numeric(25, 0)
    ,backup_finish_date datetime
    ,BackupType varchar(64)
    )

set @sql = 
    'insert into #backups
select row_number() over (order by backup_finish_date desc) rw
    ,m.physical_device_name
    ,s.checkpoint_lsn
    ,s.differential_base_lsn
    ,s.backup_finish_date
    ,case s.[type]
        when ''D''
            then ''Full''
        when ''I''
            then ''Differential''
        when ''L''
            then ''Transaction Log''
        end as BackupType
from ' 
    + @ServerName + '.msdb.dbo.backupset s
inner join ' + @ServerName + '.msdb.dbo.backupmediafamily m
    on s.media_set_id = m.media_set_id
where s.database_name = ''' + @DbName + 
    '''
    and s.[type] in (''D'',''I'')
order by backup_finish_date desc'

-- print @sql
exec sp_executesql @sql

set @difflsn = (
        select differential_base_lsn
        from #backups b
        where rw = 1
        )

select *
into #restoreFile
from #backups b
where rw = 1
    or checkpoint_lsn = @difflsn

if (
        select count(*)
        from #restoreFile
        ) = 2
begin
    set @sql = 'restore database [' + @DbName + ']
from disk = N''' + (
            select physical_device_name
            from #restoreFile
            where BackupType = 'Full'
            ) + '''
with file = 1
    ,NOUNLOAD
    ,REPLACE
    ,NORECOVERY
    ,STATS = ' + @Stats + '

restore database [' + @DbName + ']
from disk = N''' + (
            select physical_device_name
            from #restoreFile
            where BackupType = 'Differential'
            ) + '''
with file = 1
    ,NOUNLOAD
    ,RECOVERY
    ,STATS = ' + @Stats
end
else
begin
    set @sql = 'restore database [' + @DbName + ']
from disk = N''' + (
            select physical_device_name
            from #restoreFile
            ) + '''
with file = 1
    ,NOUNLOAD
    ,REPLACE
    ,RECOVERY
    ,STATS = ' + @Stats
end

print @sql

exec sp_executesql @sql

drop table #backups

drop table #restoreFile

set @sql = 'alter database [' + @DbName + '] set compatibility_level = ' + (
        select convert(nvarchar(8), compatibility_level)
        from sys.databases
        where name = 'master'
        )

print @sql

execute sp_executesql @sql
