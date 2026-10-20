namespace SafeSync.Core;

internal sealed class BackupRootUnavailableException(string message,Exception? inner=null):IOException(message,inner);

// A missing file is not evidence of a deletion if its containing storage was
// disconnected/replaced. Bind before recovery and preserve this binding on disk.
internal sealed class OneWayRoots
{
    private readonly string source,sourceIdentity;
    private readonly string? backup,backupIdentity;
    public OneWayRoots(BackupJob job,JobState state)
    {
        source=job.Source;sourceIdentity=Read(source);
        if(job.DestinationType=="Local"){backup=job.Destination;backupIdentity=Read(backup);}
        if((state.OneWaySourceIdentity.Length>0 && state.OneWaySourceIdentity!=sourceIdentity) ||
            (backup!=null && state.OneWayBackupIdentity.Length>0 && state.OneWayBackupIdentity!=backupIdentity))
            throw new BackupRootUnavailableException("원본 또는 백업 폴더가 이전과 다른 폴더입니다. 삭제 반영을 중단했습니다. 기존 위치를 다시 연결하거나 확인 후 새 작업으로 등록하세요.");
        if(state.OneWaySourceIdentity.Length==0 && state.Files.Count>0)state.FullScanRequired=true;
        state.OneWaySourceIdentity=sourceIdentity;state.OneWayBackupIdentity=backupIdentity ?? "";
    }
    private static string Read(string path)
    {
        try{return OfflineJournal.RequiredRootIdentity(path);}
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException)
        {throw new BackupRootUnavailableException("원본 또는 백업 폴더에 접근할 수 없어 백업과 삭제 반영을 중단했습니다. 연결을 복구한 뒤 다시 시도하세요.",ex);}
    }
    public void Check()
    {
        if(Read(source)!=sourceIdentity || (backup!=null && Read(backup)!=backupIdentity))
            throw new BackupRootUnavailableException("작업 도중 원본 또는 백업 폴더가 교체되었습니다. 기존 백업과 재시도 목록을 유지합니다.");
    }
    public void RequireDeletion(string relative,FileEntry? entry)
    {
        Check();
        if(entry!=null && !entry.DeletionSourceVerified)
            throw new Cloud.CloudConflictException(relative,"이전 버전의 원본 확인 정보가 없어 삭제를 반영하지 않았습니다. 원본 위치와 백업 사본을 확인하세요.");
        // GetAttributes surfaces access denied/I/O errors that FileInfo.Exists
        // would turn into false. Check each ancestor, including link boundaries.
        string path=source;var parts=PathPolicy.Relative(relative).Split('/');
        for(int i=0;i<parts.Length;i++)
        {
            path=Path.Combine(path,parts[i]);FileAttributes attributes;
            try{attributes=File.GetAttributes(path);}
            catch(FileNotFoundException){Check();return;}
            catch(DirectoryNotFoundException){Check();return;}
            if((attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("원본 경로에 연결 지점이 있어 삭제를 중단합니다.");
            if(i==parts.Length-1)throw new Cloud.CloudConflictException(relative,"원본 파일 또는 폴더가 다시 나타났습니다. 삭제를 반영하지 않습니다.");
            if((attributes&FileAttributes.Directory)==0)throw new IOException("원본 상위 폴더가 파일로 변경되어 삭제를 중단합니다.");
        }
    }
}
