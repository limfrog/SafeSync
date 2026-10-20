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
        var gate=ScopeGate(remote);await pause.WaitForBoundaryAsync(gate,token);
        try
        {
            var state=store.LoadState(job);var result=new BackupResult();
            var roots=new OneWayRoots(job,state);store.SaveState(state);
            if(await FileComparisons.PrepareDuplicatesAsync(job,remote,resolutions,token))forceFull=true;
            await new VerifiedFiles().RecoverAsync(job.Source,token);
            var offline=OfflineJournal.Read(job.Source,state.SourceJournal,token,OfflineJournal.TrackedIds(state.Files));bool journalInvalid=state.SourceJournal!=null && offline.RequiresScan;state.SourceJournal=offline.Checkpoint;
            changes=(changes ?? []).Concat(offline.Paths);
            var entries=new System.Collections.Concurrent.ConcurrentDictionary<string,FileEntry>(state.Files.ToDictionary(f=>PathPolicy.Relative(f.RelativePath),StringComparer.OrdinalIgnoreCase),StringComparer.OrdinalIgnoreCase);
            var pending=new HashSet<string>(state.PendingPaths,StringComparer.OrdinalIgnoreCase);
            foreach(var entry in entries.Values.Where(e=>e.Status!="BackedUp"))pending.Add(entry.RelativePath);
            var publisher=new CloudPublisher(store,job,remote);
            publisher.ValidateDeletion=relative=>roots.RequireDeletion(relative,entries.GetValueOrDefault(relative) ?? throw new CloudConflictException(relative,"삭제 전 원본 확인 기록이 없습니다. 기존 백업을 보존합니다."));
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
                {await pause.WaitAsync(token);pause.ThrowIfStopRequested();pending.Add(PathPolicy.Relative(Path.GetRelativePath(job.Source,file.FullName)));}
                foreach(var relative in entries.Keys)pending.Add(relative);
                
            }
            Report("클라우드 변경 기록 확인","",0,0);
            // A source watcher/USN gap requires rescanning the source, not a
            // valid remote catalog. RemoteCatalog independently rebuilds for a
            // missing/expired cursor or changed identity. Manual full compare
            // still explicitly refreshes both endpoints.
            await catalog.RefreshAsync(forceFull,pause,token);tree=new(catalog.State.Items,StringComparer.OrdinalIgnoreCase);
            foreach(var path in catalog.State.Pending)if(!PathPolicy.Internal(path))pending.Add(path);
            ChangePlanner.Add(job.Source,changes ?? [],entries,pending,token,pause.ThrowIfStopRequested);
            if(resolutions!=null)foreach(var relative in resolutions.Keys)pending.Add(PathPolicy.Relative(relative));
            if(full){state.FullScanRequired=false;state.LastFullScanUtc=DateTime.UtcNow.ToString("O");}
            state.CheckpointActive=true;Save();catalog.Acknowledge();var work=pending.Order(StringComparer.OrdinalIgnoreCase).ToArray();int completed=0;
            IReadOnlyDictionary<string,RemoteItem?>? metadata=null;
            if(remote is IRemoteBatch batchStore)
            {
                try{metadata=await batchStore.StatManyAsync(tree,work.Where(p=>!catalog.IsAmbiguous(p)),token);}
                catch(CloudDuplicateNameException){await catalog.RefreshAsync(true,pause,token);tree=new(catalog.State.Items,StringComparer.OrdinalIgnoreCase);}
            }
            try
            {
                var checkpointLock=new object();bool stopWork=false;
                async Task ProcessAsync(string relative)
                {
                    await pause.WaitAsync(token);pause.ThrowIfStopRequested();token.ThrowIfCancellationRequested();if(blocked.Contains(relative)){Interlocked.Increment(ref completed);return;}
                    var path=PathPolicy.Combine(job.Source,relative);var info=new FileInfo(path);bool handled=false;RemoteItem? target=null;
                    try
                    {
                        Report("변경 파일의 클라우드 정보 확인",relative,completed,work.Length);
                        roots.Check();
                        var action=resolutions!=null && resolutions.TryGetValue(relative,out var selected) ? selected : (ConflictAction?)null;
                        if(action==ConflictAction.Ignore){entries[relative]=FileEntry.From(info,relative,"Conflict","이번 동기화에서 제외");lock(checkpointLock)result.Skipped++;handled=true;return;}
                        if(catalog.IsAmbiguous(relative))
                        {
                            PathPolicy.RejectLinks(job.Source,path);
                            if(action==null && remote is IRemoteDuplicates duplicates)
                            {
                                if(Directory.Exists(path) && (await duplicates.CandidatesAsync(relative,token)) is {Count:>0} folders && folders.All(i=>i.Folder))
                                {entries.TryRemove(relative,out _);lock(checkpointLock)result.Skipped++;handled=true;return;}
                                var identical=await RemoteDuplicates.IdenticalAsync(remote,path,relative,token);
                                if(identical!=null)
                                {
                                    info.Refresh();
                                    entries[relative]=FileEntry.From(info,relative);entries[relative].RemoteId=identical.Id;
                                    lock(checkpointLock)result.Skipped++;handled=true;return;
                                }
                            }
                            throw new CloudDuplicateNameException(relative);
                        }
                        target=metadata!=null ? metadata.GetValueOrDefault(relative) : tree!=null ? tree.GetValueOrDefault(relative) : await remote.StatAsync(relative,token);
                        await FileComparisons.VerifyAsync(job,relative,remote,resolutions,token);
                        if(action==ConflictAction.UseBackup)
                        {
                            Report("클라우드 백업 → 원본 검증 복원",relative,completed,work.Length);
                            target=await remote.StatAsync(relative,token);
                            await FileComparisons.RestoreAsync(store,job,relative,remote,target,token,resolutions);info.Refresh();
                            entries[relative]=FileEntry.From(info,relative);entries[relative].RemoteId=target!.Id;
                            lock(checkpointLock){catalog.Update(relative,target);result.Copied++;}handled=true;return;
                        }
                        if(Directory.Exists(path))
                        {
                            if(target!=null && !target.Folder)throw new CloudConflictException(relative,"원본 폴더와 클라우드 파일의 경로가 충돌합니다.");
                            entries.TryRemove(relative,out _);handled=true;return;
                        }
                        if(!info.Exists)
                        {
                            roots.RequireDeletion(relative,entries.GetValueOrDefault(relative));
                            if(action is ConflictAction.Overwrite or ConflictAction.KeepBoth)throw new CloudConflictException(relative,"복사할 원본 파일이 없습니다. 덮어쓰기로 삭제를 강제하지 않습니다.");
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
                            await FileComparisons.VerifyAsync(job,relative,remote,resolutions,token);
                            sourceFileId=OfflineJournal.FileIdentity(path);
                            if(target!=null && (target.Folder || !target.Binary))throw new CloudConflictException(relative,"클라우드 폴더·문서·바로가기는 일반 파일로 덮어쓰지 않습니다.");
                            bool sameTime=target!=null && Math.Abs((info.LastWriteTimeUtc-target.ModifiedUtc).TotalSeconds)<=2;
                            bool sameContent=false;
                            if(action==null && target!=null && target.Length==info.Length && (target.Hash.Length>0 || target.Sha256.Length>0))
                            {
                                Report("클라우드 파일 내용 동일 여부 검증",relative,completed,work.Length);
                                string hash,sha256="";
                                if(remote.Provider=="GoogleDrive"){var hashes=await RemotePath.GoogleHashesAsync(path,token);hash=hashes.Md5;sha256=hashes.Sha256;}
                                else hash=await RemotePath.HashAsync(remote.Provider,path,token);
                                sameContent=RemotePath.Content(target,new(path,info.Length,info.LastWriteTimeUtc,info.CreationTimeUtc,hash,sha256));
                            }
                            if(action==null && target!=null && target.Length==info.Length && sameContent)
                            {
                                entries[relative]=FileEntry.From(info,relative);entries[relative].RemoteId=target.Id;
                                lock(checkpointLock)result.Skipped++;handled=true;return;
                            }
                            if(action==null && target!=null && info.LastWriteTimeUtc<=target.ModifiedUtc.AddSeconds(2))
                                throw new CloudConflictException(relative,sameTime ? "수정 시간은 비슷하지만 파일 내용이 다르거나 내용 동일 여부를 검증할 수 없습니다." : "클라우드 백업이 더 최신이거나 파일 정보가 다릅니다.");
                            Report("전송용 안정 사본 및 체크섬 준비",relative,completed,work.Length);
                            snapshot=await publisher.StageAsync(path,token);
                        }
                        Report("검증 전용 임시 위치로 분할 전송",relative,completed,work.Length);
                        var final=await publisher.PublishAsync(relative,snapshot,target,action==ConflictAction.KeepBoth,pause,token);
                        entries[relative]=new(){RelativePath=relative,Length=snapshot.Length,SourceFileId=sourceFileId,CreationTimeUtc=snapshot.CreatedUtc.ToString("O"),LastWriteTimeUtc=snapshot.ModifiedUtc.ToString("O"),Status="BackedUp",RemoteId=final.Id,LastAttemptUtc=DateTime.UtcNow.ToString("O"),DeletionSourceVerified=true};
                        lock(checkpointLock){catalog.Update(relative,final);result.Copied++;}handled=true;
                    }
                    catch(OperationCanceledException){throw;}
                    catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException)
                    {
                        bool locked=ex is IOException && (ex.HResult&0xFFFF) is 32 or 33;
                        var issue=Issue(relative,locked ? "다른 프로그램에서 사용 중입니다." : ex.Message,info,target);
                        string status=locked ? "Locked" : ex is CloudConflictException ? "Conflict" : "Failed";
                        var oldEntry=entries.GetValueOrDefault(relative);
                        if((!info.Exists || ex is BackupRootUnavailableException) && oldEntry!=null){oldEntry.Status=status;oldEntry.LastError=issue.Reason;entries[relative]=oldEntry;}
                        else entries[relative]=FileEntry.From(info,relative,status,issue.Reason);
                        if(locked)issue=LockTracking.Update(entries[relative],oldEntry,issue);
                        lock(checkpointLock){if(locked)result.Locked.Add(issue);else if(ex is CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);}
                        if(ex is HttpRequestException or CloudApiException or BackupRootUnavailableException)stopWork=true;
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
                pause.ThrowIfStopRequested();
                Report("클라우드 휴지통 보관 기간 확인","",completed,work.Length);
                try
                {
                    roots.Check();
                    result.Trashed+=new TrashService().RemoveExpired(job.Source,retentionDays,token,pause.ThrowIfStopRequested);
                    var trash=await remote.StatAsync(".safesync-trash",token);
                    var protectedBatches=publisher.ProtectedTrashBatches();
                    if(trash?.Folder==true)
                        foreach(var batch in await remote.ListAsync(".safesync-trash",token))
                        {
                            await pause.WaitAsync(token);pause.ThrowIfStopRequested();token.ThrowIfCancellationRequested();
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
        FileIssue Issue(string relative,string reason,FileInfo? source,RemoteItem? backup)=>new(job.Id,job.Name,relative,reason,source?.Exists==true ? source.Length : 0,backup?.Length ?? 0,source?.Exists==true ? source.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") : "",backup?.ModifiedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "",SourceCreated:source?.Exists==true ? source.CreationTimeUtc.ToString("O") : "",BackupCreated:backup?.CreatedUtc.ToString("O") ?? "",SourceExists:source?.Exists,BackupExists:backup!=null);
    }
    public static async Task<Dictionary<string,RemoteItem>> TreeAsync(IRemoteStore remote,PauseGate pause,CancellationToken token,Action<string>? progress=null,bool includeInternal=false)
    {
        var files=new Dictionary<string,RemoteItem>(StringComparer.OrdinalIgnoreCase);var folders=new Stack<string>();folders.Push("");
        while(folders.Count>0)
        {
            await pause.WaitAsync(token);pause.ThrowIfStopRequested();token.ThrowIfCancellationRequested();var folder=folders.Pop();progress?.Invoke(folder);
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
