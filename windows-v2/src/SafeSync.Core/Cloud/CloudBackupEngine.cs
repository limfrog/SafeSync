namespace SafeSync.Core.Cloud;

public sealed class CloudBackupEngine(ConfigStore store,IRemoteStore remote)
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string,SemaphoreSlim> Gates=new();
    // Account-wide serialization also covers nested/aliased roots.
    public static SemaphoreSlim ScopeGate(IRemoteStore remote)=>Gates.GetOrAdd(remote.Provider+"|"+remote.AccountId,_=>new(1,1));
    public async Task<BackupResult> RunAsync(BackupJob job,bool forceFull,IEnumerable<string>? changes,PauseGate pause,IProgress<BackupProgress>? progress,CancellationToken token,
        IReadOnlyDictionary<string,ConflictAction>? resolutions,bool reconcileOffline,int retentionDays)
    {
        if(!Directory.Exists(job.Source))throw new DirectoryNotFoundException("원본 폴더에 접근할 수 없습니다.");
        if(job.CloudAccountId.Length==0 || job.CloudAccountId!=remote.AccountId)throw new InvalidOperationException("클라우드 계정을 확인하고 작업의 백업 폴더를 다시 선택하세요.");
        Report("클라우드 계정 및 백업 폴더 확인","",0,0);await remote.InitializeAsync(token);
        var gate=ScopeGate(remote);await gate.WaitAsync(token);
        try
        {
            var state=store.LoadState(job);var result=new BackupResult();
            var offline=OfflineJournal.Read(job.Source,state.SourceJournal,token,OfflineJournal.TrackedIds(state.Files));bool journalInvalid=state.SourceJournal!=null && offline.RequiresScan;state.SourceJournal=offline.Checkpoint;
            changes=(changes ?? []).Concat(offline.Paths);
            var entries=new System.Collections.Concurrent.ConcurrentDictionary<string,FileEntry>(state.Files.ToDictionary(f=>PathPolicy.Relative(f.RelativePath),StringComparer.OrdinalIgnoreCase),StringComparer.OrdinalIgnoreCase);
            var pending=new HashSet<string>(state.PendingPaths,StringComparer.OrdinalIgnoreCase);
            foreach(var entry in entries.Values.Where(e=>e.Status!="BackedUp"))pending.Add(entry.RelativePath);
            var publisher=new CloudPublisher(store,job,remote);
            Report("중단된 클라우드 전송 및 교체 확인","",0,0);
            var recovery=await publisher.RecoverAsync(resolutions,pause,token);
            var blocked=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var failure in recovery)
            {
                pending.Add(failure.Relative);blocked.Add(failure.Relative);
                var issue=Issue(failure.Relative,failure.Error.Message,null,null);
                if(failure.Error is CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);
            }
            bool full=forceFull || journalInvalid || (reconcileOffline && offline.RequiresScan) || state.FullScanRequired || !DateTime.TryParse(state.LastFullScanUtc,out _);
            Dictionary<string,RemoteItem>? tree=null;
            var catalog=new RemoteCatalog(store,remote);
            if(full)
            {
                foreach(var file in FileTree.Scan(job.Source,token,folder=>Report("원본 폴더 비교",folder,0,0)))
                {await pause.WaitAsync(token);pending.Add(PathPolicy.Relative(Path.GetRelativePath(job.Source,file.FullName)));}
                foreach(var relative in entries.Keys)pending.Add(relative);
                
            }
            Report("클라우드 변경 기록 확인","",0,0);
            // A source watcher/USN gap requires rescanning the source, not a
            // valid remote catalog. RemoteCatalog independently rebuilds for a
            // missing/expired cursor or changed identity. Manual full compare
            // still explicitly refreshes both endpoints.
            await catalog.RefreshAsync(forceFull,pause,token);tree=new(catalog.State.Items,StringComparer.OrdinalIgnoreCase);
            foreach(var path in catalog.State.Pending)if(!PathPolicy.Internal(path))pending.Add(path);
            ChangePlanner.Add(job.Source,changes ?? [],entries,pending,token);
            if(resolutions!=null)foreach(var relative in resolutions.Keys)pending.Add(PathPolicy.Relative(relative));
            if(full){state.FullScanRequired=false;state.LastFullScanUtc=DateTime.UtcNow.ToString("O");}
            state.CheckpointActive=true;Save();catalog.Acknowledge();var work=pending.Order(StringComparer.OrdinalIgnoreCase).ToArray();int completed=0;
            IReadOnlyDictionary<string,RemoteItem?>? metadata=remote is IRemoteBatch batchStore ? await batchStore.StatManyAsync(tree,work,token) : null;
            try
            {
                var checkpointLock=new object();bool stopWork=false;
                async Task ProcessAsync(string relative)
                {
                    await pause.WaitAsync(token);token.ThrowIfCancellationRequested();if(blocked.Contains(relative)){Interlocked.Increment(ref completed);return;}
                    var path=PathPolicy.Combine(job.Source,relative);var info=new FileInfo(path);bool handled=false;RemoteItem? target=null;
                    try
                    {
                        Report("변경 파일의 클라우드 정보 확인",relative,completed,work.Length);
                        target=metadata!=null ? metadata.GetValueOrDefault(relative) : tree!=null ? tree.GetValueOrDefault(relative) : await remote.StatAsync(relative,token);
                        var action=resolutions!=null && resolutions.TryGetValue(relative,out var selected) ? selected : (ConflictAction?)null;
                        if(action==ConflictAction.Ignore){handled=true;return;}
                        if(!info.Exists)
                        {
                            if(job.MirrorDeletes && entries.ContainsKey(relative) && target!=null)
                            {
                                if(target.Folder || !target.Binary)throw new CloudConflictException(relative,"일반 파일이 아닌 클라우드 항목은 자동으로 삭제하지 않습니다.");
                                await publisher.TrashAsync(relative,target,token);lock(checkpointLock)result.Trashed++;
                            }
                            if(target==null || (job.MirrorDeletes && entries.ContainsKey(relative)))lock(checkpointLock)catalog.Update(relative,null);
                            entries.TryRemove(relative,out _);handled=true;return;
                        }
                        UploadSnapshot snapshot;long sourceFileId;
                        using(var guard=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
                        {
                            info.Refresh();
                            sourceFileId=OfflineJournal.FileIdentity(path);
                            if(target!=null && (target.Folder || !target.Binary))throw new CloudConflictException(relative,"클라우드 폴더·문서·바로가기는 일반 파일로 덮어쓰지 않습니다.");
                            bool sameTime=target!=null && Math.Abs((info.LastWriteTimeUtc-target.ModifiedUtc).TotalSeconds)<=2;
                            if(action==null && sameTime && target!.Length==info.Length)
                            {
                                entries[relative]=FileEntry.From(info,relative);entries[relative].RemoteId=target.Id;
                                lock(checkpointLock)result.Skipped++;handled=true;return;
                            }
                            if(action==null && target!=null && info.LastWriteTimeUtc<=target.ModifiedUtc.AddSeconds(2))
                                throw new CloudConflictException(relative,sameTime ? "수정 시간은 같지만 파일 크기가 다릅니다." : "클라우드 백업이 더 최신이거나 파일 정보가 다릅니다.");
                            Report("전송용 안정 사본 및 체크섬 준비",relative,completed,work.Length);
                            snapshot=await publisher.StageAsync(path,token);
                        }
                        Report("검증 전용 임시 위치로 분할 전송",relative,completed,work.Length);
                        var final=await publisher.PublishAsync(relative,snapshot,target,action==ConflictAction.KeepBoth,pause,token);
                        entries[relative]=new(){RelativePath=relative,Length=snapshot.Length,SourceFileId=sourceFileId,CreationTimeUtc=snapshot.CreatedUtc.ToString("O"),LastWriteTimeUtc=snapshot.ModifiedUtc.ToString("O"),Status="BackedUp",RemoteId=final.Id,LastAttemptUtc=DateTime.UtcNow.ToString("O")};
                        lock(checkpointLock){catalog.Update(relative,final);result.Copied++;}handled=true;
                    }
                    catch(OperationCanceledException){throw;}
                    catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException)
                    {
                        bool locked=ex is IOException && (ex.HResult&0xFFFF) is 32 or 33;
                        var issue=Issue(relative,locked ? "다른 프로그램에서 사용 중입니다." : ex.Message,info,target);
                        string status=locked ? "Locked" : ex is CloudConflictException ? "Conflict" : "Failed";
                        var oldEntry=entries.GetValueOrDefault(relative);
                        entries[relative]=FileEntry.From(info,relative,status,issue.Reason);
                        if(locked)issue=LockTracking.Update(entries[relative],oldEntry,issue);
                        lock(checkpointLock){if(locked)result.Locked.Add(issue);else if(ex is CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);}
                        if(ex is HttpRequestException || ex is CloudApiException)stopWork=true;
                    }
                    finally
                    {
                        lock(checkpointLock){if(handled){pending.Remove(relative);if(!entries.TryGetValue(relative,out var resolved) || resolved.Status=="BackedUp")result.ResolvedPaths.Add(relative);}completed++;store.SaveCheckpoint(state,entries,pending,new[]{relative});Report("파일 비교 및 클라우드 백업",relative,completed,work.Length);}
                    }
                }
                bool Small(string relative){try{return new FileInfo(PathPolicy.Combine(job.Source,relative)) is {Exists:true,Length:<=5*1024*1024};}catch(IOException){return false;}}
                for(int index=0;index<work.Length && !stopWork;)
                {
                    var first=work[index++];
                    if(remote is IRemoteParallel && index<work.Length && Small(first) && Small(work[index]))await Task.WhenAll(ProcessAsync(first),ProcessAsync(work[index++]));
                    else await ProcessAsync(first);
                }
                if(completed==work.Length)
                {
                    if(full)state.LastFullScanUtc=DateTime.UtcNow.ToString("O");state.FullScanRequired=false;state.LastRunUtc=DateTime.UtcNow.ToString("O");
                }
                // Retention cleanup is scoped strictly to the application trash.
                Report("클라우드 휴지통 보관 기간 확인","",completed,work.Length);
                try
                {
                    var trash=await remote.StatAsync(".safesync-trash",token);
                    var protectedBatches=publisher.ProtectedTrashBatches();
                    if(trash?.Folder==true)
                        foreach(var batch in await remote.ListAsync(".safesync-trash",token))
                        {
                            await pause.WaitAsync(token);token.ThrowIfCancellationRequested();
                            if(protectedBatches.Contains(batch.Name) || !batch.Folder || !TrashDates.TryParse(batch.Name,out var deleted) || deleted>=DateTime.Now.AddDays(-retentionDays))continue;
                            await remote.DeleteAsync(".safesync-trash/"+PathPolicy.Relative(batch.Name),token);
                        }
                }
                catch(Exception ex) when(ex is IOException or HttpRequestException){result.Errors.Add(Issue("[휴지통 정리]",ex.Message,null,null));}
            }
            catch(OperationCanceledException){result.Canceled=true;}
            finally{state.CheckpointActive=pending.Count>0;Save();catalog.Save();}
            return result;
            void Save(){state.PendingPaths=pending.Order(StringComparer.OrdinalIgnoreCase).ToList();state.Files=entries.Values.OrderBy(f=>f.RelativePath,StringComparer.OrdinalIgnoreCase).ToList();store.SaveState(state);}
        }
        finally{gate.Release();}
        void Report(string stage,string file,int done,int total)=>progress?.Report(new(job.Id,job.Name,stage,file,done,total));
        FileIssue Issue(string relative,string reason,FileInfo? source,RemoteItem? backup)=>new(job.Id,job.Name,relative,reason,source?.Exists==true ? source.Length : 0,backup?.Length ?? 0,source?.Exists==true ? source.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") : "",backup?.ModifiedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "");
    }
    public static async Task<Dictionary<string,RemoteItem>> TreeAsync(IRemoteStore remote,PauseGate pause,CancellationToken token,Action<string>? progress=null,bool includeInternal=false)
    {
        var files=new Dictionary<string,RemoteItem>(StringComparer.OrdinalIgnoreCase);var folders=new Stack<string>();folders.Push("");
        while(folders.Count>0)
        {
            await pause.WaitAsync(token);token.ThrowIfCancellationRequested();var folder=folders.Pop();progress?.Invoke(folder);
            var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var item in await remote.ListAsync(folder,token))
            {
                var relative=folder.Length==0 ? PathPolicy.Relative(item.Name) : folder+"/"+PathPolicy.Relative(item.Name);
                if(!includeInternal && PathPolicy.Internal(relative))continue;
                if(!seen.Add(item.Name))throw new IOException("클라우드에 중복 이름이 있습니다: "+relative);
                files.Add(relative,item);if(item.Folder)folders.Push(relative);
            }
        }
        return files;
    }
}
