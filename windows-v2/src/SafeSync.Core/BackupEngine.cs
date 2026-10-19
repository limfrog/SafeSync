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
        ConfigStore.ValidateJob(job);
        if (job.DestinationType != "Local" && CloudFactory==null) throw new NotSupportedException("클라우드 공급자가 연결되지 않았습니다.");
        var gate = locks.GetOrAdd(job.Id, _ => new(1,1));
        await gate.WaitAsync(token);
        try
        {
            if(job.SyncMode=="TwoWay")
            {
                var twoWayResult=await new TwoWayEngine(store,job.DestinationType=="Local" ? null : CloudFactory!(job)).RunAsync(job,forceFull,changed,pause,progress,token,resolutions,reconcileOffline || !observedTwoWayJobs.ContainsKey(job.Id),retentionDays);
                if(!twoWayResult.Canceled)observedTwoWayJobs.TryAdd(job.Id,0);return twoWayResult;
            }
            if(resolutions?.Values.Contains(ConflictAction.UseBackup)==true)throw new InvalidOperationException("백업을 원본으로 복사하는 처리는 양방향 작업에서만 가능합니다.");
            if(job.DestinationType!="Local")return await new Cloud.CloudBackupEngine(store,CloudFactory!(job)).RunAsync(job,forceFull,changed,pause,progress,token,resolutions,reconcileOffline,retentionDays);
            // Never create an absent network root: a disconnected drive must fail,
            // not turn into a successful empty scan/deletion run.
            if (!Directory.Exists(job.Source) || !Directory.Exists(job.Destination))
                throw new DirectoryNotFoundException("원본 또는 백업 위치에 접근할 수 없습니다.");
            PathPolicy.RejectLinks(job.Source,job.Source);
            PathPolicy.RejectLinks(job.Destination,job.Destination);
            var publisher = new VerifiedFiles();
            progress?.Report(new(job.Id,job.Name,"중단된 파일 교체 확인", "",0,0));
            await publisher.RecoverAsync(job.Destination,token);
            var state = store.LoadState(job);
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
            if (full)
            {
                // Enumerate completely before mutating the backup. Any access
                // error aborts the scan instead of treating unseen files as deleted.
                foreach (var file in FileTree.Scan(job.Source,token, folder => progress?.Report(new(job.Id,job.Name,"원본 폴더 비교",folder,0,0))))
                {
                    await pause.WaitAsync(token);
                    pending.Add(PathPolicy.Relative(Path.GetRelativePath(job.Source,file.FullName)));
                }
                foreach (var relative in entries.Keys) pending.Add(relative);
            }
            ChangePlanner.Add(job.Source,changed ?? [],entries,pending,token);
            if (resolutions != null) foreach (var key in resolutions.Keys) pending.Add(PathPolicy.Relative(key));
            if(full){state.FullScanRequired=false;state.LastFullScanUtc=DateTime.UtcNow.ToString("O");}
            state.CheckpointActive = true;
            Save();
            var result = new BackupResult();
            var work = pending.Order(StringComparer.OrdinalIgnoreCase).ToArray();
            int completed = 0;var checkpointPaths=new List<string>(5);
            try
            {
                foreach (var relative in work)
                {
                    await pause.WaitAsync(token);
                    token.ThrowIfCancellationRequested();
                    if (PathPolicy.Internal(relative)) { pending.Remove(relative); continue; }
                    progress?.Report(new(job.Id,job.Name,"파일 비교 및 백업",relative,completed,work.Length));
                    var source = PathPolicy.Combine(job.Source,relative);
                    var destination = PathPolicy.Combine(job.Destination,relative);
                    var info = new FileInfo(source);
                    bool handled = false;
                    try
                    {
                        if (!info.Exists)
                        {
                            // Only tracked backup files are eligible for mirrored deletion.
                            if (entries.ContainsKey(relative) && job.MirrorDeletes && File.Exists(destination))
                            { TrashService.Move(job.Destination,relative,"deleted"); result.Trashed++; }
                            entries.Remove(relative); handled = true; continue;
                        }
                        using var sourceGuard = new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
                        info.Refresh();
                        var target = new FileInfo(destination);
                        var action = resolutions != null && resolutions.TryGetValue(relative,out var choice) ? choice : (ConflictAction?)null;
                        if (action == ConflictAction.Ignore)
                        {
                            entries[relative] = FileEntry.From(info,relative,"Conflict","이번에는 변경하지 않음");
                            handled = true; continue;
                        }
                        bool sameModified = target.Exists && Math.Abs((info.LastWriteTimeUtc - target.LastWriteTimeUtc).TotalSeconds) <= 2;
                        bool sameCreated = target.Exists && Math.Abs((info.CreationTimeUtc - target.CreationTimeUtc).TotalSeconds) <= 2;
                        bool sameSize = target.Exists && info.Length == target.Length;
                        if (action is null && target.Exists && sameModified && sameCreated && sameSize)
                        { entries[relative] = FileEntry.From(info,relative);entries[relative].BackupFileId=OfflineJournal.FileIdentity(destination); result.Skipped++; handled=true; continue; }
                        if (action is null && target.Exists && info.LastWriteTimeUtc <= target.LastWriteTimeUtc.AddSeconds(2))
                        {
                            var reason = sameModified && !sameSize ? "수정 시간은 같지만 크기가 다릅니다." : "백업이 더 최신이거나 파일 정보가 서로 다릅니다.";
                            result.Conflicts.Add(Issue(relative,reason,info,target));
                            entries[relative] = FileEntry.From(info,relative,"Conflict",reason); continue;
                        }
                        string? sibling = null;
                        try
                        {
                            if (action == ConflictAction.KeepBoth && target.Exists)
                            {
                                sibling = destination + ".SafeSync-conflict-" + DateTime.Now.ToString("yyyyMMdd-HHmmssfff") + "-" + Guid.NewGuid().ToString("N")[..8];
                                File.Move(destination,sibling);
                            }
                            if (!target.Exists && entries.ContainsKey(relative))
                            {
                                var trash = TrashService.NewPath(job.Destination,relative,"backup-deleted");
                                await publisher.CopyAsync(source,job.Destination,Path.GetRelativePath(job.Destination,trash),token);
                                result.Trashed++;
                            }
                            await publisher.CopyAsync(source,job.Destination,relative,token);
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
                        var locked = ex is IOException && ((ex.HResult & 0xFFFF) is 32 or 33);
                        var issue = Issue(relative,locked ? "다른 프로그램에서 사용 중입니다." : ex.Message,info,new FileInfo(destination));
                        var oldEntry=entries.GetValueOrDefault(relative);
                        entries[relative] = FileEntry.From(info,relative,locked ? "Locked" : "Failed",issue.Reason);
                        if(locked)issue=LockTracking.Update(entries[relative],oldEntry,issue);
                        if(locked)result.Locked.Add(issue);else result.Errors.Add(issue);
                    }
                    finally
                    {
                        if (handled){pending.Remove(relative);if(!entries.TryGetValue(relative,out var resolved) || resolved.Status=="BackedUp")result.ResolvedPaths.Add(relative);}
                        completed++;
                        checkpointPaths.Add(relative);
                        if (checkpointPaths.Count>=5 || completed==work.Length){store.SaveCheckpoint(state,entries,pending,checkpointPaths);checkpointPaths.Clear();}
                        progress?.Report(new(job.Id,job.Name,"파일 비교 및 백업",relative,completed,work.Length));
                    }
                }
                if (full) state.LastFullScanUtc = DateTime.UtcNow.ToString("O");
                state.LastRunUtc = DateTime.UtcNow.ToString("O");
                state.FullScanRequired = false;
                progress?.Report(new(job.Id,job.Name,"휴지통 보관 기간 확인", "",completed,work.Length));
                try {result.Trashed += await Task.Run(() => new TrashService().RemoveExpired(job.Destination,retentionDays,token),token);}
                catch(Exception ex) when(ex is IOException or UnauthorizedAccessException)
                {
                    result.Errors.Add(new(job.Id,job.Name,"[휴지통 정리]",ex.Message,0,0,"",""));
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
                dst.Exists ? dst.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") : "없음");
        }
        finally { gate.Release(); }
    }
}
