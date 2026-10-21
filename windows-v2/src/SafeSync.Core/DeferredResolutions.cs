namespace SafeSync.Core;

// Session-only, explicit user choices. These retain the inspected file versions;
// finishing the current run never grants authority over different later bytes.
internal sealed class DeferredResolutions(BackupJob job)
{
    private readonly string binding=Binding(job);
    public ComparedResolutions Choices {get;}=new();
    public bool Matches(BackupJob current)=>binding==Binding(current);
    private static string Binding(BackupJob job)=>System.Text.Json.JsonSerializer.Serialize(new
    {job.Id,job.Source,job.Destination,job.DestinationType,job.CloudAccountId,job.CloudFolderId,job.CloudFolderIdentity,job.SyncMode,job.MirrorDeletes,job.CloudBindingReviewRequired});

    public void Merge(BackupJob current,ComparedResolutions choices)
    {
        if(!Matches(current))throw new InvalidOperationException("예약 후 작업 위치 또는 연결이 변경되었습니다. 다시 확인하세요.");
        // Validate every entry before changing the queue. Never accept an
        // unchecked dictionary as delayed force-overwrite permission.
        foreach(var (path,action) in choices)
        {
            if(PathPolicy.Internal(PathPolicy.Relative(path)))throw new InvalidDataException("내부 파일은 처리 예약할 수 없습니다.");
            if(action==ConflictAction.Ignore)continue;
            if(!choices.Comparisons.TryGetValue(path,out var c) || c.JobId!=current.Id || c.SourceRoot!=current.Source || c.BackupRoot!=current.Destination || c.Provider!=current.DestinationType || c.Account!=current.CloudAccountId || c.FolderId!=current.CloudFolderId || !c.Readable || c.Relative!=path)
                throw new InvalidDataException("예약할 파일의 현재 정보와 작업 연결을 먼저 확인하세요.");
            if(!(action switch
            {
                ConflictAction.Overwrite=>c.CanForward,
                ConflictAction.UseBackup=>c.CanReverse,
                ConflictAction.KeepBoth=>c.CanForward && c.Backup is {Exists:true,Folder:false},
                ConflictAction.NormalizeDuplicates=>c.Duplicates is {Groups.Length:>0},
                _=>false
            }))throw new InvalidDataException("선택한 파일에 적용할 수 없는 처리입니다.");
        }
        foreach(var (path,action) in choices)
        {
            Choices[path]=action;
            if(choices.Comparisons.TryGetValue(path,out var comparison))
                Choices.Comparisons[path]=comparison with{Duplicates=comparison.Duplicates is {} plan ? plan with{Groups=plan.Groups.Select(g=>g with{Items=g.Items.ToArray()}).ToArray()} : null};
            else Choices.Comparisons.Remove(path);
        }
    }
}
