namespace SafeSync.Core;

public sealed class BackupEngine(ConfigStore store)
{
    public Func<BackupJob,Cloud.IRemoteStore>? CloudFactory {get;set;}
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SemaphoreSlim> locks = new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string,byte> observedTwoWayJobs=new();
    public async Task<BackupResult> RunAsync(BackupJob job, bool forceFull, IEnumerable<string>? changed,
        PauseGate pause, IProgress<BackupProgress>? progress, CancellationToken token,
        IReadOnlyDictionary<string, ConflictAction>? resolutions = null, bool reconcileOffline = false,
        int retentionDays = 100)
    {
        using var trace=OperationLog.Begin(job,forceFull,reconcileOffline);
        try
        {
            var result=await RunCoreAsync(job,forceFull,changed,pause,new DiagnosticProgress(trace,progress),token,resolutions,reconcileOffline,retentionDays);
            trace?.Complete(result);return result;
        }
        catch(Exception ex){trace?.Fail(ex);throw;}
    }
    private sealed class DiagnosticProgress(OperationLog.Run? trace,IProgress<BackupProgress>? next) : IProgress<BackupProgress>
    {public void Report(BackupProgress value){trace?.Progress(value);next?.Report(value);}}
    private async Task<BackupResult> RunCoreAsync(BackupJob job,bool forceFull,IEnumerable<string>? changed,
        PauseGate pause,IProgress<BackupProgress>? progress,CancellationToken token,
        IReadOnlyDictionary<string,ConflictAction>? resolutions,bool reconcileOffline,int retentionDays)
    {
        ConfigStore.ValidateJob(job);
        if (job.DestinationType != "Local" && CloudFactory==null) throw new NotSupportedException("클라우드 공급자가 연결되지 않았습니다.");
        var gate = locks.GetOrAdd(job.Id, _ => new(1,1));
        try{using var timing=OperationLog.Measure("prepare.job_gate");await pause.WaitForBoundaryAsync(gate,token);}catch(JobStoppedException){return new(){Canceled=true};}
        try
        {
            pause.ThrowIfStopRequested();
            if(job.SyncMode=="TwoWay")
            {
                var twoWayResult=await new TwoWayEngine(store,job.DestinationType=="Local" ? null : CloudFactory!(job)).RunAsync(job,forceFull,changed,pause,progress,token,resolutions,reconcileOffline || !observedTwoWayJobs.ContainsKey(job.Id),retentionDays);
                if(!twoWayResult.Canceled)observedTwoWayJobs.TryAdd(job.Id,0);return twoWayResult;
            }
            if(job.DestinationType!="Local")return await new Cloud.CloudBackupEngine(store,CloudFactory!(job)).RunAsync(job,forceFull,changed,pause,progress,token,resolutions,reconcileOffline,retentionDays);
            // Never create an absent network root: a disconnected drive must fail,
            // not turn into a successful empty scan/deletion run.
            if (!Directory.Exists(job.Source) || !Directory.Exists(job.Destination))
                throw new DirectoryNotFoundException("원본 또는 백업 위치에 접근할 수 없습니다.");
            PathPolicy.RejectLinks(job.Source,job.Source);
            PathPolicy.RejectLinks(job.Destination,job.Destination);
            var state = store.LoadState(job);
            var roots = new OneWayRoots(job,state);
            store.SaveState(state);
            var publisher = new VerifiedFiles();
            progress?.Report(new(job.Id,job.Name,"중단된 파일 교체 확인", "",0,0));
            await publisher.RecoverAsync(job.Source,token);
            await publisher.RecoverAsync(job.Destination,token);
            var offline=OfflineJournal.Read(job.Source,state.SourceJournal,token,OfflineJournal.TrackedIds(state.Files));
            var targetOffline=OfflineJournal.Read(job.Destination,state.DestinationJournal,token,OfflineJournal.TrackedIds(state.Files,true));
            bool journalInvalid=(state.SourceJournal!=null && offline.RequiresScan)||(state.DestinationJournal!=null && targetOffline.RequiresScan);
            state.SourceJournal=offline.Checkpoint;state.DestinationJournal=targetOffline.Checkpoint;
            changed=(changed ?? []).Concat(offline.Paths).Concat(targetOffline.Paths);
            var entries = state.Files.ToDictionary(f => PathPolicy.Relative(f.RelativePath),StringComparer.OrdinalIgnoreCase);
            var pending = new HashSet<string>(state.PendingPaths.Select(PathPolicy.Relative),StringComparer.OrdinalIgnoreCase);
            foreach (var entry in entries.Values.Where(e => e.Status != "BackedUp")) pending.Add(entry.RelativePath);
            bool full = forceFull || journalInvalid || (reconcileOffline && (offline.RequiresScan || targetOffline.RequiresScan)) || state.FullScanRequired ||
                !DateTime.TryParse(state.LastFullScanUtc,out _);
            OperationLog.Event("prepare.plan","local",completed:pending.Count,total:entries.Count,detail:$"full={full};manual={forceFull};journalInvalid={journalInvalid};reconcile={reconcileOffline};sourceScan={offline.RequiresScan};destinationScan={targetOffline.RequiresScan};required={state.FullScanRequired}");
            if (full)
            {
                // Enumerate completely before mutating the backup. Any access
                // error aborts the scan instead of treating unseen files as deleted.
                foreach (var file in FileTree.Scan(job.Source,token, folder => progress?.Report(new(job.Id,job.Name,"원본 폴더 비교",folder,0,0))))
                {
                    await pause.WaitAsync(token);
                    pause.ThrowIfStopRequested();
                    pending.Add(PathPolicy.Relative(Path.GetRelativePath(job.Source,file.FullName)));
                }
                foreach (var relative in entries.Keys) pending.Add(relative);
            }
            ChangePlanner.Add(job.Source,changed ?? [],entries,pending,token,pause.ThrowIfStopRequested);
            if (resolutions != null) foreach (var key in resolutions.Keys) pending.Add(PathPolicy.Relative(key));
            if(full){state.FullScanRequired=false;state.LastFullScanUtc=DateTime.UtcNow.ToString("O");}
            state.CheckpointActive = true;
            Save();
            var result = new BackupResult();
            var work = pending.Order(StringComparer.OrdinalIgnoreCase).ToArray();
            int completed = 0;var checkpointPaths=new List<string>(5);bool rootFailed=false;
            try
            {
                foreach (var relative in work)
                {
                    await pause.WaitAsync(token);
                    pause.ThrowIfStopRequested();
                    token.ThrowIfCancellationRequested();
                    if (PathPolicy.Internal(relative)) { pending.Remove(relative); continue; }
                    progress?.Report(new(job.Id,job.Name,"파일 비교 및 백업",relative,completed,work.Length));
                    var source = PathPolicy.Combine(job.Source,relative);
                    var destination = PathPolicy.Combine(job.Destination,relative);
                    var info = new FileInfo(source);
                    using var fileTiming=OperationLog.Measure("file.local",relative);
                    bool handled = false;
                    try
                    {
                        roots.Check();
                        var action = resolutions != null && resolutions.TryGetValue(relative,out var choice) ? choice : (ConflictAction?)null;
                        if(Directory.Exists(source))
                        {
                            // Watchers/USN report directories as well as files.
                            // FileInfo.Exists is false for an existing directory;
                            // it must never enter missing-file/deletion handling.
                            // Clear only this obsolete file row, preserving child
                            // baselines and every physical backup item.
                            if(action==ConflictAction.Ignore){handled=true;result.Skipped++;continue;}
                            await FileComparisons.VerifyAsync(job,relative,null,resolutions,token);
                            var targetKind=FileComparisons.ReadLocal(job.Destination,relative);
                            if(targetKind is {Folder:false})throw new Cloud.CloudConflictException(relative,"원본 폴더와 백업 파일의 경로가 충돌합니다. 기존 백업을 보존했습니다.");
                            if(action is ConflictAction.Overwrite or ConflictAction.KeepBoth or ConflictAction.UseBackup)
                                throw new Cloud.CloudConflictException(relative,"폴더 항목은 파일 덮어쓰기나 복원으로 처리할 수 없습니다. 현재 항목을 다시 확인하세요.");
                            entries.Remove(relative);handled=true;continue;
                        }
                        if(action==ConflictAction.Ignore){entries[relative]=FileEntry.From(info,relative,"Conflict","이번 동기화에서 제외");handled=true;result.Skipped++;continue;}
                        await FileComparisons.VerifyAsync(job,relative,null,resolutions,token);
                        if(action==ConflictAction.UseBackup)
                        {
                            progress?.Report(new(job.Id,job.Name,"백업 → 원본 검증 복원",relative,completed,work.Length));
                            await FileComparisons.RestoreAsync(store,job,relative,null,null,token,resolutions);info.Refresh();
                            entries[relative]=FileEntry.From(info,relative);entries[relative].BackupFileId=OfflineJournal.FileIdentity(destination);
                            result.Copied++;handled=true;continue;
                        }
                        if(action is ConflictAction.Overwrite or ConflictAction.KeepBoth && !info.Exists)throw new Cloud.CloudConflictException(relative,"복사할 원본 파일이 없습니다. 덮어쓰기로 삭제를 강제하지 않습니다.");
                        if (!info.Exists)
                        {
                            roots.RequireDeletion(relative,entries.GetValueOrDefault(relative));
                            // Only tracked backup files are eligible for mirrored deletion.
                            if (entries.ContainsKey(relative) && job.MirrorDeletes && File.Exists(destination))
                            { TrashService.Move(job.Destination,relative,"deleted"); result.Trashed++; }
                            entries.Remove(relative); handled = true; continue;
                        }
                        using var sourceGuard = new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
                        info.Refresh();
                        var target = new FileInfo(destination);
                        bool sameModified = target.Exists && Math.Abs((info.LastWriteTimeUtc - target.LastWriteTimeUtc).TotalSeconds) <= 2;
                        bool sameSize = target.Exists && info.Length == target.Length;
                        // Creation time is not a portable content identifier:
                        // NAS/Samba and copied files may report a different birth time.
                        bool sameContent=false;
                        if(action is null && target.Exists && sameSize)
                        {
                            progress?.Report(new(job.Id,job.Name,"파일 내용 동일 여부 검증",relative,completed,work.Length));
                            PathPolicy.RejectLinks(job.Destination,destination);
                            using var targetGuard=new FileStream(destination,FileMode.Open,FileAccess.Read,FileShare.Read);
                            target.Refresh();
                            sameContent=info.Length==target.Length && await VerifiedFiles.HashAsync(source,token)==await VerifiedFiles.HashAsync(destination,token);
                        }
                        if (action is null && target.Exists && sameSize && sameContent)
                        { entries[relative] = FileEntry.From(info,relative);entries[relative].BackupFileId=OfflineJournal.FileIdentity(destination); result.Skipped++; handled=true; continue; }
                        if (action is null && target.Exists && info.LastWriteTimeUtc <= target.LastWriteTimeUtc.AddSeconds(2))
                        {
                            var reason = sameModified && !sameSize ? "수정 시간은 같지만 크기가 다릅니다." : "백업이 더 최신이거나 파일 정보가 서로 다릅니다.";
                            result.Conflicts.Add(Issue(relative,reason,info,target));
                            entries[relative] = FileEntry.From(info,relative,"Conflict",reason); continue;
                        }
                        string? sibling = null;
                        string? expectedTarget=action!=null ? target.Exists ? await VerifiedFiles.HashAsync(destination,token) : "" : null;
                        await FileComparisons.VerifyAsync(job,relative,null,resolutions,token);
                        try
                        {
                            if (action == ConflictAction.KeepBoth && target.Exists)
                            {
                                using var mutation=await FileMutationGate.EnterAsync(token);
                                using var targetGuard=new FileStream(destination,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
                                if(await VerifiedFiles.HashAsync(destination,token)!=expectedTarget)throw new Cloud.CloudConflictException(relative,"비교 후 백업이 변경되어 이름을 바꾸지 않았습니다.");
                                await FileComparisons.VerifyAsync(job,relative,null,resolutions,token);
                                sibling = destination + ".SafeSync-conflict-" + DateTime.Now.ToString("yyyyMMdd-HHmmssfff") + "-" + Guid.NewGuid().ToString("N")[..8];
                                File.Move(destination,sibling);
                            }
                            if (!target.Exists && entries.ContainsKey(relative))
                            {
                                var trash = TrashService.NewPath(job.Destination,relative,"backup-deleted");
                                await publisher.CopyAsync(source,job.Destination,Path.GetRelativePath(job.Destination,trash),token);
                                result.Trashed++;
                            }
                            await publisher.CopyAsync(source,job.Destination,relative,token,expectedDestinationHash:sibling!=null ? "" : expectedTarget);
                        }
                        catch
                        {
                            if (sibling != null && File.Exists(sibling) && !File.Exists(destination)) File.Move(sibling,destination);
                            throw;
                        }
                        entries[relative] = FileEntry.From(info,relative);
                        entries[relative].BackupFileId=OfflineJournal.FileIdentity(destination);
                        result.Copied++; handled = true;
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        OperationLog.Event("file.error","local",relative,error:ex,detail:NetworkFailures.IsTransient(ex) ? "network_retry" : "review_or_retry");
                        var locked = ex is IOException && ((ex.HResult & 0xFFFF) is 32 or 33);
                        var issue = Issue(relative,locked ? "다른 프로그램에서 사용 중입니다." : ex.Message,info,new FileInfo(destination)) with{AutomaticNetworkRetry=NetworkFailures.IsTransient(ex)};
                        var oldEntry=entries.GetValueOrDefault(relative);
                        if((!info.Exists || ex is BackupRootUnavailableException) && oldEntry!=null)
                        {oldEntry.Status=ex is Cloud.CloudConflictException ? "Conflict" : "Failed";oldEntry.LastError=issue.Reason;entries[relative]=oldEntry;}
                        else entries[relative] = FileEntry.From(info,relative,locked ? "Locked" : ex is Cloud.CloudConflictException ? "Conflict" : "Failed",issue.Reason);
                        if(locked)issue=LockTracking.Update(entries[relative],oldEntry,issue);
                        if(locked)result.Locked.Add(issue);else if(ex is Cloud.CloudConflictException)result.Conflicts.Add(issue);else result.Errors.Add(issue);
                        if(ex is BackupRootUnavailableException)rootFailed=true;
                    }
                    finally
                    {
                        if (handled){pending.Remove(relative);if(!entries.TryGetValue(relative,out var resolved) || resolved.Status=="BackedUp")result.ResolvedPaths.Add(relative);}
                        completed++;
                        checkpointPaths.Add(relative);
                        if (checkpointPaths.Count>=5 || completed==work.Length){store.SaveCheckpoint(state,entries,pending,checkpointPaths);checkpointPaths.Clear();}
                        progress?.Report(new(job.Id,job.Name,"파일 비교 및 백업",relative,completed,work.Length));
                    }
                    if(rootFailed)break;
                }
                if(completed==work.Length)
                {
                    if (full) state.LastFullScanUtc = DateTime.UtcNow.ToString("O");
                    state.LastRunUtc = DateTime.UtcNow.ToString("O");
                    state.FullScanRequired = false;
                }
                pause.ThrowIfStopRequested();
                progress?.Report(new(job.Id,job.Name,"휴지통 보관 기간 확인", "",completed,work.Length));
                try {roots.Check();result.Trashed += await Task.Run(() => new TrashService().RemoveExpired(job.Destination,retentionDays,token,pause.ThrowIfStopRequested)+new TrashService().RemoveExpired(job.Source,retentionDays,token,pause.ThrowIfStopRequested),token);}
                catch(Exception ex) when(ex is IOException or UnauthorizedAccessException)
                {
                    result.Errors.Add(new(job.Id,job.Name,"[휴지통 정리]",ex.Message,0,0,"","",AutomaticNetworkRetry:NetworkFailures.IsTransient(ex)));
                }
            }
            catch (OperationCanceledException) { result.Canceled = true; }
            finally { state.CheckpointActive = pending.Count > 0; Save(); }
            return result;

            void Save()
            {
                state.PendingPaths = pending.Order(StringComparer.OrdinalIgnoreCase).ToList();
                state.Files = entries.Values.OrderBy(f => f.RelativePath,StringComparer.OrdinalIgnoreCase).ToList();
                store.SaveState(state);
            }
            FileIssue Issue(string path,string reason,FileInfo src,FileInfo dst) => new(job.Id,job.Name,path,reason,
                src.Exists ? src.Length : 0,dst.Exists ? dst.Length : 0,
                src.Exists ? src.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") : "없음",
                dst.Exists ? dst.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") : "없음",
                SourceCreated:src.Exists ? src.CreationTimeUtc.ToString("O") : "",BackupCreated:dst.Exists ? dst.CreationTimeUtc.ToString("O") : "",SourceExists:src.Exists,BackupExists:dst.Exists);
        }
        catch(JobStoppedException){return new(){Canceled=true};}
        finally { gate.Release(); }
    }
}
