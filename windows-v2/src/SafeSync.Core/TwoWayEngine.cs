using SafeSync.Core.Cloud;

namespace SafeSync.Core;

// Reconciliation uses a COMMON, verified content baseline, never clock ordering.
// No baseline => union, not deletion. A conflict never advances that baseline.
public sealed class TwoWayEngine(ConfigStore store,IRemoteStore? remote)
{
    public async Task<BackupResult> RunAsync(BackupJob job,bool forceFull,IEnumerable<string>? changes,PauseGate pause,
        IProgress<BackupProgress>? progress,CancellationToken token,IReadOnlyDictionary<string,ConflictAction>? resolutions,
        bool reconcileOffline,int retentionDays)
    {
        if(!Directory.Exists(job.Source) || (remote==null && !Directory.Exists(job.Destination)))
            throw new DirectoryNotFoundException("동기화 폴더에 접근할 수 없습니다. 연결 중단을 삭제로 처리하지 않습니다.");
        PathPolicy.RejectLinks(job.Source,job.Source);
        var result=new BackupResult();var state=store.LoadState(job);
        var entries=state.Files.ToDictionary(e=>PathPolicy.Relative(e.RelativePath),StringComparer.OrdinalIgnoreCase);
        var pending=state.PendingPaths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var dirty=(changes ?? []).Select(PathPolicy.Relative).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var gate=remote==null ? null : CloudBackupEngine.ScopeGate(remote);
        if(gate!=null)await gate.WaitAsync(token);
        try
        {
            Report("양방향 동기화 폴더 및 복구 기록 확인","",0,0);
            var files=new VerifiedFiles();await files.RecoverAsync(job.Source,token);
            CloudPublisher? publisher=null;RemoteCatalog? catalog=null;
            if(remote!=null)
            {
                if(job.CloudAccountId!=remote.AccountId)throw new InvalidOperationException("작업의 클라우드 계정이 다릅니다.");
                await remote.InitializeAsync(token);publisher=new(store,job,remote);
            }
            else {PathPolicy.RejectLinks(job.Destination,job.Destination);await files.RecoverAsync(job.Destination,token);}
            string leftIdentity=LocalRootIdentity(job.Source);
            var rootItem=remote==null ? null : await remote.StatAsync("",token);
            string rightIdentity=remote==null ? LocalRootIdentity(job.Destination) : rootItem?.Id ?? throw new DirectoryNotFoundException("클라우드 동기화 폴더가 없습니다.");
            if((state.SyncSourceIdentity.Length>0 && state.SyncSourceIdentity!=leftIdentity) ||
                (state.SyncBackupIdentity.Length>0 && state.SyncBackupIdentity!=rightIdentity))
                throw new IOException("동기화 루트 폴더의 식별 정보가 변경되었습니다. 삭제 전파를 중단합니다. 폴더를 확인한 뒤 새 작업으로 다시 연결하세요.");
            state.SyncSourceIdentity=leftIdentity;state.SyncBackupIdentity=rightIdentity;
            var sourceOffline=OfflineJournal.Read(job.Source,state.SourceJournal,token,OfflineJournal.TrackedIds(state.Files));
            var backupOffline=remote==null ? OfflineJournal.Read(job.Destination,state.DestinationJournal,token,OfflineJournal.TrackedIds(state.Files,true)) : null;
            bool journalGap=state.SourceJournal!=null && sourceOffline.RequiresScan || state.DestinationJournal!=null && backupOffline?.RequiresScan==true;
            state.SourceJournal=sourceOffline.Checkpoint;if(backupOffline!=null)state.DestinationJournal=backupOffline.Checkpoint;
            foreach(var path in sourceOffline.Paths.Concat(backupOffline?.Paths ?? []))dirty.Add(path);
            bool full=forceFull || state.FullScanRequired || journalGap || !DateTime.TryParse(state.LastFullScanUtc,out _) ||
                reconcileOffline && (sourceOffline.RequiresScan || backupOffline?.RequiresScan==true);
            foreach(var entry in entries.Values.Where(e=>e.Status!="BackedUp"))pending.Add(entry.RelativePath);
            if(resolutions!=null)foreach(var path in resolutions.Keys)pending.Add(PathPolicy.Relative(path));
            var blocked=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if(publisher!=null)
                foreach(var failure in await publisher.RecoverAsync(resolutions,pause,token))
                {
                    blocked.Add(failure.Relative);pending.Add(failure.Relative);
                    var issue=Issue(failure.Relative,failure.Error.Message,null,null);
                    if(failure.Error is CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);
                }
            // Enumerations must finish successfully BEFORE ANY deletion. Access
            // errors and unavailable roots cannot be mistaken for an empty tree.
            if(remote!=null)
            {
                catalog=new(store,remote);Report("클라우드 변경 기록 및 폴더 비교","",0,0);
                await catalog.RefreshAsync(forceFull,pause,token);
                foreach(var path in catalog.State.Pending)dirty.Add(path);
            }
            var candidates=dirty.Concat(pending).ToArray();
            var left=full ? await ScanAsync(job.Source,"원본 폴더 비교") : await PlanAsync(job.Source,candidates);
            Dictionary<string,FileSystemInfo>? right=null;
            if(remote==null)right=full ? await ScanAsync(job.Destination,"백업 폴더 비교") : await PlanAsync(job.Destination,candidates);
            var remoteItems=catalog?.State.Items;
            var implicitParents=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var work=left.Keys.Concat(right?.Keys ?? Enumerable.Empty<string>())
                .Concat(full ? remoteItems?.Keys ?? Enumerable.Empty<string>() : [])
                .Concat(full ? entries.Keys : []).Concat(pending).Concat(dirty).Concat(resolutions?.Keys ?? [])
                .Where(p=>!PathPolicy.Internal(p)).Distinct(StringComparer.OrdinalIgnoreCase)
                // Reconcile files first, then deepest directories. A surviving
                // conflicting/untracked child prevents deletion of its parent.
                .OrderBy(p=>left.GetValueOrDefault(p) is DirectoryInfo || right?.GetValueOrDefault(p) is DirectoryInfo || remoteItems?.GetValueOrDefault(p)?.Folder==true || entries.GetValueOrDefault(p)?.Length==-1 ? 1 : 0)
                .ThenByDescending(p=>p.Count(c=>c=='/')).ThenBy(p=>p,StringComparer.OrdinalIgnoreCase).ToArray();
            foreach(var path in work)pending.Add(path);
            state.CheckpointActive=true;Save();catalog?.Acknowledge();
            int completed=0;bool stopRemote=false;
            try
            {
                foreach(var relative in work)
                {
                    await pause.WaitAsync(token);token.ThrowIfCancellationRequested();
                    if(blocked.Contains(relative)){completed++;continue;}
                    SyncSide? a=null,b=null;
                    entries.TryGetValue(relative,out var previous);
                    try
                    {
                        Report("양쪽 파일 변경 비교",relative,completed,work.Length);
                        var sourcePath=PathPolicy.Combine(job.Source,relative);
                        var backupPath=remote==null ? PathPolicy.Combine(job.Destination,relative) : "";
                        bool rehash=full || IsDirty(relative) || previous?.Status!="BackedUp";
                        a=await ReadLocalAsync(sourcePath,previous?.SyncSource,rehash,token);
                        var ri=remoteItems?.GetValueOrDefault(relative);
                        if(remote!=null && ri==null && implicitParents.Contains(relative))
                        {ri=await remote.StatAsync(relative,token);catalog!.Update(relative,ri);}
                        b=remote==null ? await ReadLocalAsync(backupPath,previous?.SyncBackup,rehash,token) : RemoteSide(ri);
                        if(a!=null && b!=null && ((a.Length==-1)!=(b.Length==-1)))throw new CloudConflictException(relative,"파일과 폴더의 경로가 충돌합니다. 자동으로 교체하지 않습니다.");
                        var choice=resolutions!=null && resolutions.TryGetValue(relative,out var action) ? action : (ConflictAction?)null;
                        if(choice==ConflictAction.Ignore)
                        {
                            // Not a baseline: the unresolved difference remains
                            // visible and must not become deletion authority.
                            throw new CloudConflictException(relative,"이번에는 변경하지 않음 — 양쪽 사본을 유지합니다.");
                        }
                        if(SameContent(a,b)){Commit(relative,a,b);result.Skipped++;continue;}
                        bool forward;
                        bool keepBoth=choice==ConflictAction.KeepBoth;
                        if(choice is ConflictAction.Overwrite or ConflictAction.KeepBoth)
                        {
                            if(a==null)throw new CloudConflictException(relative,"원본 파일이 없습니다. 덮어쓰기로 삭제를 강제하지 않습니다.");
                            forward=true;
                        }
                        else if(choice==ConflictAction.UseBackup)
                        {
                            if(b==null)throw new CloudConflictException(relative,"백업 파일이 없습니다. 덮어쓰기로 삭제를 강제하지 않습니다.");
                            forward=false;
                        }
                        else if(previous?.SyncSource==null || previous.SyncBackup==null)
                        {
                            if(a!=null && b!=null)throw new CloudConflictException(relative,"최초 비교에서 양쪽 내용이 다릅니다. 유지할 사본을 선택하세요.");
                            forward=a!=null;
                        }
                        else
                        {
                            if(!SameContent(previous.SyncSource,previous.SyncBackup))throw new CloudConflictException(relative,"양쪽의 성공 비교 기록이 일치하지 않습니다. 자동 삭제·교체를 중단합니다.");
                            bool ac=!SameContent(a,previous.SyncSource),bc=!SameContent(b,previous.SyncBackup);
                            if(ac && bc)throw new CloudConflictException(relative,"양쪽 파일이 모두 변경되었거나 한쪽 삭제와 다른 쪽 수정이 겹쳤습니다.");
                            if(!ac && !bc)throw new CloudConflictException(relative,"저장된 양방향 비교 기록을 확인할 수 없습니다.");
                            forward=ac;
                        }
                        // The roots are checked again immediately before each
                        // mutation, especially deletion after a remote disconnect.
                        CheckLocalRoot(job.Source,leftIdentity);
                        if(remote==null)CheckLocalRoot(job.Destination,rightIdentity);
                        else if((await remote.StatAsync("",token))?.Id!=rightIdentity)throw new IOException("클라우드 루트가 변경되었습니다.");
                        if(a?.Length==-1 || b?.Length==-1)
                        {
                            Report("양쪽 폴더 구조 반영",relative,completed,work.Length);
                            if(forward)
                            {
                                if(a==null)
                                {
                                    RequireMissingLocal(sourcePath);
                                    if(remote==null)await RemoveFolderAsync(job.Destination,relative,b!,token);
                                    else
                                    {
                                        var folder=await CurrentRemoteAsync(relative,b!,token);
                                        if((await remote.ListAsync(relative,token)).Count>0)throw new CloudConflictException(relative,"백업 폴더에 남아 있는 항목이 있어 폴더 삭제를 보류합니다.");
                                        var trash=".safesync-trash/"+DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-two-way-folder-"+Guid.NewGuid().ToString("N")+"/"+relative;
                                        var moved=await remote.MoveAsync(relative,trash,token);
                                        if(moved.Id!=folder.Id)throw new IOException("휴지통 폴더 식별 정보가 다릅니다.");
                                    }
                                    catalog?.Update(relative,null);result.Trashed++;Commit(relative,null,null);
                                }
                                else
                                {
                                    await RequireLocalAsync(sourcePath,a,token);
                                    if(remote==null){RequireMissingLocal(backupPath);Directory.CreateDirectory(backupPath);b=await ReadLocalAsync(backupPath,null,true,token);}
                                    else {await RequireRemoteMissingAsync(relative,token);await remote.EnsureFolderAsync(relative,token);MarkParents(relative);var folder=await remote.StatAsync(relative,token);catalog!.Update(relative,folder);b=RemoteSide(folder);}
                                    if(b?.Length!=-1)throw new IOException("생성한 백업 폴더를 확인할 수 없습니다.");result.Copied++;Commit(relative,a,b);
                                }
                            }
                            else
                            {
                                if(b==null)
                                {
                                    if(remote==null)RequireMissingLocal(backupPath);else await RequireRemoteMissingAsync(relative,token);
                                    await RemoveFolderAsync(job.Source,relative,a!,token);result.Trashed++;Commit(relative,null,null);
                                }
                                else
                                {
                                    if(remote==null)await RequireLocalAsync(backupPath,b,token);else await CurrentRemoteAsync(relative,b,token);
                                    RequireMissingLocal(sourcePath);Directory.CreateDirectory(sourcePath);a=await ReadLocalAsync(sourcePath,null,true,token);
                                    if(a?.Length!=-1)throw new IOException("생성한 원본 폴더를 확인할 수 없습니다.");result.Copied++;Commit(relative,a,b);
                                }
                            }
                            continue;
                        }
                        if(forward)
                        {
                            if(a==null)
                            {
                                RequireMissingLocal(sourcePath);
                                Report("원본 삭제를 백업 휴지통으로 반영",relative,completed,work.Length);
                                if(remote==null)await RemoveLocalAsync(job.Destination,relative,b!,token);
                                else await publisher!.TrashAsync(relative,await CurrentRemoteAsync(relative,b!,token),token);
                                catalog?.Update(relative,null);result.Trashed++;Commit(relative,null,null);
                            }
                            else
                            {
                                Report("원본 → 백업 검증 복사",relative,completed,work.Length);
                                using var guard=new FileStream(sourcePath,FileMode.Open,FileAccess.Read,FileShare.Read);
                                await RequireLocalAsync(sourcePath,a,token);
                                if(remote==null)
                                {
                                    if(keepBoth && b!=null)await PreserveLocalAsync(job.Destination,relative,b,token);
                                    await files.CopyAsync(sourcePath,job.Destination,relative,token,expectedDestinationHash:keepBoth ? "" : await LocalShaAsync(backupPath,b,token));
                                    b=await ReadLocalAsync(backupPath,null,true,token);
                                }
                                else
                                {
                                    var target=b==null ? await RequireRemoteMissingAsync(relative,token) : await CurrentRemoteAsync(relative,b,token);
                                    var staged=await publisher!.StageAsync(sourcePath,token);
                                    var final=await publisher.PublishAsync(relative,staged,target,keepBoth,pause,token);
                                    MarkParents(relative);
                                    catalog!.Update(relative,final);b=RemoteSide(final);
                                }
                                a=await ReadLocalAsync(sourcePath,null,true,token);
                                if(!SameContent(a,b))throw new IOException("양쪽 복사 결과 검증이 일치하지 않습니다.");
                                result.Copied++;Commit(relative,a,b);
                            }
                        }
                        else
                        {
                            if(b==null)
                            {
                                if(remote==null)RequireMissingLocal(backupPath);else await RequireRemoteMissingAsync(relative,token);
                                Report("백업 삭제를 원본 휴지통으로 반영",relative,completed,work.Length);
                                await RemoveLocalAsync(job.Source,relative,a!,token);result.Trashed++;Commit(relative,null,null);
                            }
                            else
                            {
                                Report("백업 → 원본 검증 복사",relative,completed,work.Length);
                                if(remote==null)
                                {
                                    using var guard=new FileStream(backupPath,FileMode.Open,FileAccess.Read,FileShare.Read);
                                    await RequireLocalAsync(backupPath,b,token);
                                    await files.CopyAsync(backupPath,job.Source,relative,token,expectedDestinationHash:await LocalShaAsync(sourcePath,a,token));
                                }
                                else await DownloadAsync(relative,b,a,sourcePath,job.Source,files,pause,token);
                                a=await ReadLocalAsync(sourcePath,null,true,token);
                                if(!SameContent(a,b))throw new IOException("다운로드 후 양쪽 체크섬이 일치하지 않습니다.");
                                result.Copied++;Commit(relative,a,b);
                            }
                        }
                    }
                    catch(OperationCanceledException){throw;}
                    catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException)
                    {
                        bool locked=ex is IOException && (ex.HResult&0xFFFF) is 32 or 33;
                        var issue=Issue(relative,locked ? "다른 프로그램에서 사용 중입니다." : ex.Message,a,b);
                        // Preserve the LAST SUCCESSFUL pair on failure. Replacing
                        // it with today's partial state can propagate wrong deletes.
                        var entry=previous ?? new FileEntry {RelativePath=relative};
                        var prior=previous==null ? null : new FileEntry {LockedSinceUtc=previous.LockedSinceUtc,LockRetryCount=previous.LockRetryCount};
                        entry.Status=locked ? "Locked" : ex is CloudConflictException ? "Conflict" : "Failed";
                        entry.LastError=issue.Reason;entry.LastAttemptUtc=DateTime.UtcNow.ToString("O");
                        if(locked)issue=LockTracking.Update(entry,prior,issue);
                        entries[relative]=entry;
                        if(locked)result.Locked.Add(issue);else if(ex is CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);
                        if(ex is HttpRequestException or CloudApiException)stopRemote=true;
                    }
                    finally
                    {
                        completed++;store.SaveCheckpoint(state,entries,pending,[relative]);catalog?.Save();
                        Report("양방향 동기화",relative,completed,work.Length);
                    }
                    if(stopRemote)break;
                }
                state.FullScanRequired=false;if(full)state.LastFullScanUtc=DateTime.UtcNow.ToString("O");state.LastRunUtc=DateTime.UtcNow.ToString("O");
                Report("양쪽 휴지통 보관 기간 확인","",completed,work.Length);
                try
                {
                    new TrashService().RemoveExpired(job.Source,retentionDays,token);
                    if(remote==null)new TrashService().RemoveExpired(job.Destination,retentionDays,token);
                    else if((await remote.StatAsync(".safesync-trash",token))?.Folder==true)
                    {
                        var protectedBatches=publisher!.ProtectedTrashBatches();
                        foreach(var batch in await remote.ListAsync(".safesync-trash",token))
                        {
                            await pause.WaitAsync(token);
                            if(batch.Folder && !protectedBatches.Contains(batch.Name) && TrashDates.TryParse(batch.Name,out var date) && date<DateTime.Now.AddDays(-retentionDays))
                                await remote.DeleteAsync(".safesync-trash/"+PathPolicy.Relative(batch.Name),token);
                        }
                    }
                }
                catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException){result.Errors.Add(Issue("휴지통",ex.Message,null,null));}
            }
            catch(OperationCanceledException) when(token.IsCancellationRequested){result.Canceled=true;}
            finally{Save();catalog?.Save();}

            void Commit(string relative,SyncSide? a,SyncSide? b)
            {
                if(a==null && b==null)entries.Remove(relative);
                else entries[relative]=new(){RelativePath=relative,Length=a!.Length,LastWriteTimeUtc=a.Modified,CreationTimeUtc=a.Created,
                    SyncSource=a,SyncBackup=b,SourceFileId=long.TryParse(a.Identity,out var id) ? id : 0,
                    BackupFileId=remote==null && long.TryParse(b!.Identity,out var bid) ? bid : 0,RemoteId=remote!=null ? b!.Identity : "",LastAttemptUtc=DateTime.UtcNow.ToString("O")};
                pending.Remove(relative);result.ResolvedPaths.Add(relative);
            }
            bool IsDirty(string relative)=>dirty.Any(p=>p.Equals(relative,StringComparison.OrdinalIgnoreCase) || relative.StartsWith(p+"/",StringComparison.OrdinalIgnoreCase));
            void MarkParents(string relative)
            {
                for(string parent=RemotePath.Parent(relative);parent.Length>0;parent=RemotePath.Parent(parent))implicitParents.Add(parent);
            }
        }
        finally{gate?.Release();}
        return result;

        void Save(){state.Files=entries.Values.ToList();state.PendingPaths=pending.ToList();state.CheckpointActive=pending.Count>0;store.SaveState(state);}
        void Report(string stage,string path,int done,int total)=>progress?.Report(new(job.Id,job.Name,stage,path,done,total));
        FileIssue Issue(string path,string reason,SyncSide? a,SyncSide? b)=>new(job.Id,job.Name,path,reason,Math.Max(0,a?.Length ?? 0),Math.Max(0,b?.Length ?? 0),a?.Modified ?? "",b?.Modified ?? "");
        async Task<Dictionary<string,FileSystemInfo>> ScanAsync(string root,string label)
        {
            var index=new Dictionary<string,FileSystemInfo>(StringComparer.OrdinalIgnoreCase);
            foreach(var file in FileTree.Entries(root,token,folder=>Report(label,folder,0,0)))
            {
                await pause.WaitAsync(token);
                var relative=PathPolicy.Relative(Path.GetRelativePath(root,file.FullName));
                if(!index.TryAdd(relative,file))throw new IOException("대소문자가 충돌하는 파일 경로입니다: "+relative);
            }
            return index;
        }
        async Task<Dictionary<string,FileSystemInfo>> PlanAsync(string root,IEnumerable<string> paths)
        {
            var index=new Dictionary<string,FileSystemInfo>(StringComparer.OrdinalIgnoreCase);
            foreach(var relative in paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                await pause.WaitAsync(token);token.ThrowIfCancellationRequested();
                if(PathPolicy.Internal(relative))continue;
                var path=PathPolicy.Combine(root,relative);
                // A deleted/renamed directory also carries its tracked children.
                foreach(var old in entries.Keys.Where(k=>k.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)))pending.Add(old);
                if(File.Exists(path))index[relative]=new FileInfo(path);
                else if(Directory.Exists(path))
                {
                    index[relative]=new DirectoryInfo(path);
                    foreach(var child in FileTree.Entries(path,token))
                    {await pause.WaitAsync(token);index[PathPolicy.Relative(Path.GetRelativePath(root,child.FullName))]=child;}
                }
                for(string parent=RemotePath.Parent(relative);parent.Length>0;parent=RemotePath.Parent(parent))
                {
                    var parentPath=PathPolicy.Combine(root,parent);
                    if(Directory.Exists(parentPath))index[parent]=new DirectoryInfo(parentPath);
                }
            }
            return index;
        }
    }
    private static string LocalRootIdentity(string root)
    {
        if(!Directory.Exists(root))throw new DirectoryNotFoundException("동기화 루트에 접근할 수 없습니다.");
        PathPolicy.RejectLinks(root,root);
        // Directory creation time is a fallback on network filesystems without
        // file IDs. Never create the root to make an offline path appear online.
        return OfflineJournal.RootIdentity(root);
    }
    private static void CheckLocalRoot(string root,string expected)
    {if(LocalRootIdentity(root)!=expected)throw new IOException("동기화 루트가 교체되거나 연결이 끊겼습니다.");}
    private static bool SameContent(SyncSide? a,SyncSide? b)=>a==null ? b==null : b!=null && a.Length==b.Length && a.Hash==b.Hash;
    private async Task<SyncSide?> ReadLocalAsync(string path,SyncSide? cached,bool force,CancellationToken token)
    {
        try
        {
            var attributes=File.GetAttributes(path);
            if((attributes&FileAttributes.ReparsePoint)!=0)throw new CloudConflictException(Path.GetFileName(path),"연결 지점은 동기화하지 않습니다.");
            if((attributes&FileAttributes.Directory)!=0)return new(-1,Directory.GetLastWriteTimeUtc(path).ToString("O"),Directory.GetCreationTimeUtc(path).ToString("O"),"[folder]",OfflineJournal.FileIdentity(path).ToString());
        }
        catch(FileNotFoundException){return null;}
        catch(DirectoryNotFoundException){return null;}
        var info=new FileInfo(path);
        using var guard=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);info.Refresh();
        string id=OfflineJournal.FileIdentity(path).ToString(),modified=info.LastWriteTimeUtc.ToString("O"),created=info.CreationTimeUtc.ToString("O");
        if(!force && cached!=null && cached.Length==info.Length && cached.Modified==modified && cached.Created==created && cached.Identity==id)return cached;
        string hash=remote==null ? await VerifiedFiles.HashAsync(path,token) : await RemotePath.HashAsync(remote.Provider,path,token);
        return new(info.Length,modified,created,hash,id);
    }
    private static SyncSide? RemoteSide(RemoteItem? item)
    {
        if(item==null)return null;
        if(item.Folder)return new(-1,item.ModifiedUtc.ToString("O"),item.CreatedUtc.ToString("O"),"[folder]",item.Id);
        if(!item.Binary || item.Hash.Length==0)throw new CloudConflictException(item.Name,"일반 파일이 아니거나 서비스 체크섬이 없어 자동 동기화하지 않습니다.");
        return new(item.Length,item.ModifiedUtc.ToString("O"),item.CreatedUtc.ToString("O"),item.Hash,item.Id);
    }
    private async Task RequireLocalAsync(string path,SyncSide expected,CancellationToken token)
    {
        var current=await ReadLocalAsync(path,null,true,token);
        if(!SameContent(current,expected) || current?.Identity!=expected.Identity)throw new CloudConflictException(Path.GetFileName(path),"비교 후 로컬 파일이 변경되었습니다.");
    }
    private async Task<string> LocalShaAsync(string path,SyncSide? expected,CancellationToken token)
    {
        if(expected==null){if(File.Exists(path))throw new CloudConflictException(Path.GetFileName(path),"비교 후 새 대상 파일이 생겼습니다.");return "";}
        await RequireLocalAsync(path,expected,token);return await VerifiedFiles.HashAsync(path,token);
    }
    private async Task<RemoteItem> CurrentRemoteAsync(string path,SyncSide expected,CancellationToken token)
    {
        var current=await remote!.StatAsync(path,token);
        if(!SameContent(RemoteSide(current),expected) || current!.Id!=expected.Identity || (!current.Folder && current.ModifiedUtc.ToString("O")!=expected.Modified))
            throw new CloudConflictException(path,"비교 후 클라우드 파일이 변경되었습니다.");
        return current;
    }
    private async Task<RemoteItem?> RequireRemoteMissingAsync(string path,CancellationToken token)
    {if(await remote!.StatAsync(path,token)!=null)throw new CloudConflictException(path,"비교 후 클라우드 대상 파일이 생겼습니다.");return null;}
    private static void RequireMissingLocal(string path)
    {
        try{File.GetAttributes(path);}
        catch(FileNotFoundException){return;}
        catch(DirectoryNotFoundException){return;}
        throw new CloudConflictException(Path.GetFileName(path),"비교 후 파일 또는 폴더가 다시 생겼습니다. 삭제 전파를 중단합니다.");
    }
    private async Task DownloadAsync(string relative,SyncSide backup,SyncSide? source,string sourcePath,string root,VerifiedFiles files,PauseGate pause,CancellationToken token)
    {
        await CurrentRemoteAsync(relative,backup,token);
        var directory=Path.Combine(store.Root,"cloud-download-v2",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        var temp=Path.Combine(directory,"payload");
        try
        {
            await remote!.DownloadAsync(relative,temp,token);await pause.WaitAsync(token);
            if(!File.Exists(temp) || new FileInfo(temp).Length!=backup.Length || await RemotePath.HashAsync(remote.Provider,temp,token)!=backup.Hash)
                throw new IOException("다운로드한 임시 사본의 서비스 체크섬이 다릅니다. 원본을 유지합니다.");
            await CurrentRemoteAsync(relative,backup,token);
            File.SetLastWriteTimeUtc(temp,DateTime.Parse(backup.Modified).ToUniversalTime());
            if(DateTime.TryParse(backup.Created,out var created) && created.Year>1601)File.SetCreationTimeUtc(temp,created.ToUniversalTime());
            await files.CopyAsync(temp,root,relative,token,expectedDestinationHash:await LocalShaAsync(sourcePath,source,token));
        }
        finally{if(File.Exists(temp))File.Delete(temp);if(Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any())Directory.Delete(directory);}
    }
    private async Task RemoveLocalAsync(string root,string relative,SyncSide expected,CancellationToken token)
    {
        using var mutation=await FileMutationGate.EnterAsync(token);
        var path=PathPolicy.Combine(root,relative);
        using var guard=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
        await RequireLocalAsync(path,expected,token);
        var target=TrashService.NewPath(root,relative,"two-way-deleted");Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Move(path,target);
        if(!SameContent(await ReadLocalAsync(target,null,true,token),expected))throw new IOException("삭제 직전 파일이 변경되었습니다. 휴지통 사본을 보존했습니다.");
    }
    private async Task RemoveFolderAsync(string root,string relative,SyncSide expected,CancellationToken token)
    {
        using var mutation=await FileMutationGate.EnterAsync(token);var path=PathPolicy.Combine(root,relative);
        await RequireLocalAsync(path,expected,token);
        if(Directory.EnumerateFileSystemEntries(path).Any())throw new CloudConflictException(relative,"폴더에 남아 있는 항목이 있어 삭제를 보류합니다.");
        var trash=TrashService.NewPath(root,relative,"two-way-empty-folder");Directory.CreateDirectory(Path.GetDirectoryName(trash)!);Directory.Move(path,trash);
    }
    private async Task PreserveLocalAsync(string root,string relative,SyncSide expected,CancellationToken token)
    {
        using var mutation=await FileMutationGate.EnterAsync(token);
        var path=PathPolicy.Combine(root,relative);using var guard=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
        await RequireLocalAsync(path,expected,token);
        File.Move(path,PathPolicy.Combine(root,relative+".SafeSync-conflict-"+DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-"+Guid.NewGuid().ToString("N")[..8]));
    }
}
