using System.Collections.Concurrent;

namespace SafeSync.Core;

public sealed class BackupScheduler(ConfigStore store) : IAsyncDisposable
{
    private sealed class Running
    {
        public PauseGate Pause { get; } = new();
        public Task Task { get; set; } = Task.CompletedTask;
        public DeferredResolutions? Deferred {get;set;}
    }
    private readonly BackupEngine engine = new(store);
    private readonly CancellationTokenSource stop = new();
    private readonly ConcurrentDictionary<string,Running> running = new();
    private readonly ConcurrentDictionary<string,ConcurrentDictionary<string,long>> changed = new();
    private readonly ConcurrentDictionary<string,DateTime> retries = new();
    private readonly ConcurrentDictionary<string,DateTime> remotePoll=new();
    private readonly ConcurrentDictionary<string,bool> reconcile = new();
    private readonly ConcurrentDictionary<string,FileSystemWatcher> watchers = new();
    private readonly ConcurrentDictionary<string,bool> brokenWatchers=new();
    private readonly object watcherLock=new();
    private long queueVersion,savedQueueVersion=-1;
    private BackupJob[] jobs = [];
    private Task? loop;
    private readonly object queueLock = new();
    private readonly object launchLock = new();
    public event Action<BackupJob>? StateChanged;
    public event Action<BackupProgress>? Progress;
    public event Action<BackupJob>? Started;
    public event Action<BackupJob,BackupResult>? Completed;
    public event Action<BackupJob,Exception>? Failed;
    public event Action<BackupJob,string>? ResolutionsCanceled;
    public Func<IDisposable>? AcquireRunLease { get; set; }
    public Func<BackupJob,Cloud.IRemoteStore>? CloudFactory {get=>engine.CloudFactory;set=>engine.CloudFactory=value;}
    public int RetentionDays { get; set; } = 100;
    public TimeSpan LockedRetryDelay {get;set;}=TimeSpan.FromSeconds(20);
    public bool IsRunning(string id) => running.ContainsKey(id);
    public int RunningCount => running.Count;
    public int QueuedResolutionCount(string id){lock(launchLock)return running.TryGetValue(id,out var current) ? current.Deferred?.Choices.Count ?? 0 : 0;}
    public bool TryQueueResolutions(BackupJob job,ComparedResolutions choices)
    {
        lock(launchLock)
        {
            if(choices.Count==0 || stop.IsCancellationRequested || updateHolds>0 || job.Stopped || !running.TryGetValue(job.Id,out var current))return false;
            var pending=current.Deferred ?? new DeferredResolutions(job);
            pending.Merge(job,choices);current.Deferred=pending;
        }
        StateChanged?.Invoke(job);return true;
    }
    public void CancelQueuedResolutions(BackupJob job)
    {
        bool canceled;
        lock(launchLock){canceled=running.TryGetValue(job.Id,out var current) && current.Deferred!=null;if(canceled)current!.Deferred=null;}
        if(canceled)ResolutionsCanceled?.Invoke(job,"사용자가 예약한 파일 처리를 취소했습니다. 파일은 변경하지 않았습니다.");
        StateChanged?.Invoke(job);
    }
    private int updateHolds;
    public async Task<IDisposable> HoldForUpdateAsync(CancellationToken token)
    {
        Task[] active;
        lock(launchLock)
        {
            if(stop.IsCancellationRequested)throw new OperationCanceledException();
            updateHolds++;active=running.Values.Select(r=>r.Task).ToArray();
            foreach(var current in running.Values)current.Pause.RequestStop();
        }
        var lease=new UpdateHold(this);
        try{await Task.WhenAll(active).WaitAsync(token).ConfigureAwait(false);return lease;}
        catch{lease.Dispose();throw;}
    }
    private sealed class UpdateHold(BackupScheduler scheduler):IDisposable
    {
        private BackupScheduler? owner=scheduler;
        public void Dispose(){var value=Interlocked.Exchange(ref owner,null);if(value!=null)lock(value.launchLock)value.updateHolds--;}
    }
    public bool IsStopping => stop.IsCancellationRequested;
    private string QueuePath => Path.Combine(store.Root,"pending-changes-v2.json");

    public void SetJobs(IEnumerable<BackupJob> source)
    {
        lock(watcherLock)
        {
        foreach (var watcher in watchers.Values) watcher.Dispose();
        watchers.Clear();
        jobs = source.ToArray();
        foreach (var job in jobs)
        {
            reconcile.TryAdd(job.Id,true);
            Watch(job,job.Source);
            if(job.DestinationType=="Local")Watch(job,job.Destination);
        }
        }
    }
    public void Start()
    {
        if (loop != null) return;
        if (File.Exists(QueuePath))
            foreach (var pair in JsonFile.Read<Dictionary<string,Dictionary<string,long>>>(QueuePath))
                changed[pair.Key] = new(pair.Value,StringComparer.OrdinalIgnoreCase);
        loop = Task.Run(LoopAsync);
    }
    private void Watch(BackupJob job,string root)
    {
        string watcherKey=job.Id+"|"+PathPolicy.Root(root);
        if(watchers.ContainsKey(watcherKey) || !Directory.Exists(root))return;
        try
        {
            var watcher = new FileSystemWatcher(root)
            {
                IncludeSubdirectories=true, NotifyFilter=NotifyFilters.FileName | NotifyFilters.DirectoryName |
                    NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime, InternalBufferSize=64 * 1024
            };
            void Queue(string path)
            {
                if (stop.IsCancellationRequested) return;
                var relative = Path.GetRelativePath(root,path).Replace('\\','/');
                if (PathPolicy.Internal(relative)) return;
                try { PathPolicy.Relative(relative); }
                catch (InvalidDataException) { reconcile[job.Id]=true; return; }
                changed.GetOrAdd(job.Id,_ => new(StringComparer.OrdinalIgnoreCase))[relative]=DateTime.UtcNow.Ticks;Interlocked.Increment(ref queueVersion);
            }
            watcher.Created += (_,e) => Queue(e.FullPath);
            watcher.Changed += (_,e) => Queue(e.FullPath);
            watcher.Deleted += (_,e) => Queue(e.FullPath);
            watcher.Renamed += (_,e) => { Queue(e.OldFullPath); Queue(e.FullPath); };
            watcher.Error += (_,_) => {reconcile[job.Id]=true;brokenWatchers[watcherKey]=true;};
            watcher.EnableRaisingEvents=true;
            if(!watchers.TryAdd(watcherKey,watcher))watcher.Dispose();
        }
        catch (IOException) { reconcile[job.Id]=true; }
        catch (UnauthorizedAccessException) { reconcile[job.Id]=true; }
    }
    public void SetPaused(BackupJob job,bool paused)
    {
        job.Paused=paused;
        if (running.TryGetValue(job.Id,out var current))
        {
            if (paused) current.Pause.Pause(); else current.Pause.Resume();
        }
    }
    public void StopJob(BackupJob job)
    {
        lock(launchLock)
        {
            // Ending a run is distinct from pausing its transfer gate.
            job.Stopped=true;job.Paused=false;
            if(running.TryGetValue(job.Id,out var current))current.Pause.RequestStop();
        }
        StateChanged?.Invoke(job);
    }
    public bool ResumeJob(BackupJob job)
    {
        lock(launchLock)
        {
            if(IsRunning(job.Id))return false;
            job.Stopped=false;job.Paused=false;return true;
        }
    }
    public Task RunAsync(BackupJob job,bool full=false,IReadOnlyDictionary<string,ConflictAction>? resolutions=null)
    {
        lock(launchLock)
        {
        if (stop.IsCancellationRequested || updateHolds>0 || job.Paused || job.Stopped || (job.DestinationType != "Local" && CloudFactory==null)) return Task.CompletedTask;
        var current = new Running();
        if (!running.TryAdd(job.Id,current)) return running.TryGetValue(job.Id,out var active) ? active.Task : Task.CompletedTask;
        var captured = changed.TryGetValue(job.Id,out var changes) ? changes.ToArray() : [];
        try {PersistQueue();}catch {running.TryRemove(job.Id,out _);throw;}
        current.Task = Task.Run(async () =>
        {
            bool continueRun=true;
            while(continueRun)
            {
            bool completedNormally=false;
            try
            {
                Started?.Invoke(job);
                using var lease=AcquireRunLease?.Invoke();
                var reporter = new DirectProgress(p => Progress?.Invoke(p));
                var result = await engine.RunAsync(job,full,captured.Select(p => p.Key),current.Pause,reporter,stop.Token,
                    resolutions,reconcile.ContainsKey(job.Id),RetentionDays);
                if (!result.Canceled)
                {
                    reconcile.TryRemove(job.Id,out _);
                    if (changes != null)
                        foreach (var item in captured) ((ICollection<KeyValuePair<string,long>>)changes).Remove(item);
                    Interlocked.Increment(ref queueVersion);PersistQueue();
                    if (result.Locked.Count > 0 || result.Errors.Count > 0) retries[job.Id]=DateTime.UtcNow+(result.Errors.Count>0 ? TimeSpan.FromMinutes(1) : LockedRetryDelay);
                    else retries.TryRemove(job.Id,out _);
                }
                remotePoll[job.Id]=DateTime.UtcNow.AddMinutes(1);Completed?.Invoke(job,result);
                completedNormally=!result.Canceled;
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                retries[job.Id]=DateTime.UtcNow.AddMinutes(1);
                Failed?.Invoke(job,ex);
            }
            finally
            {
                string? canceled=null;
                lock(launchLock)
                {
                    var deferred=current.Deferred;current.Deferred=null;
                    continueRun=deferred!=null && completedNormally && !stop.IsCancellationRequested && updateHolds==0 && !job.Stopped && deferred.Matches(job);
                    if(continueRun)
                    {
                        // Keep ownership of the job across both passes: automatic
                        // retries/manual starts cannot overtake an accepted queue.
                        resolutions=deferred!.Choices;full=false;captured=[];changes=null;
                    }
                    else
                    {
                        running.TryRemove(job.Id,out _);
                        if(deferred!=null)canceled="현재 작업이 중단·실패했거나 위치·연결이 변경되어 예약한 파일 처리를 취소했습니다. 현재 파일을 다시 확인하세요.";
                    }
                }
                if(canceled!=null)ResolutionsCanceled?.Invoke(job,canceled);
                StateChanged?.Invoke(job);
            }
            }
        });
        return current.Task;
        }
    }
    private async Task LoopAsync()
    {
        foreach(var job in jobs)
        {
            try
            {
                var state=store.LoadState(job);
                if(state.Files.Any(e=>e.Status is "Locked" or "Failed"))retries.TryAdd(job.Id,DateTime.UtcNow+LockedRetryDelay);
            }
            catch(Exception ex) when(ex is IOException or System.Text.Json.JsonException){retries.TryAdd(job.Id,DateTime.UtcNow.AddMinutes(1));}
        }
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        try
        {
            while (await timer.WaitForNextTickAsync(stop.Token))
            {
                RepairWatchers();PersistQueue();
                foreach (var job in jobs)
                {
                    if (Volatile.Read(ref updateHolds)>0 || job.Paused || job.Stopped || IsRunning(job.Id) || (job.DestinationType != "Local" && CloudFactory==null)) continue;
                    if (retries.TryGetValue(job.Id,out var due) && due > DateTime.UtcNow) continue;
                    bool retry = retries.TryGetValue(job.Id,out due) && due <= DateTime.UtcNow;
                    bool dirty = changed.TryGetValue(job.Id,out var changes) && !changes.IsEmpty &&
                        new DateTime(changes.Values.Max(),DateTimeKind.Utc) < DateTime.UtcNow.AddSeconds(-2);
                    bool cloudDue=job.DestinationType!="Local" && (!remotePoll.TryGetValue(job.Id,out var pollDue) || pollDue<=DateTime.UtcNow);
                    if (retry || (job.TriggerType == "Realtime" && (dirty || cloudDue || reconcile.ContainsKey(job.Id)))) _ = RunAsync(job);
                    else if (job.TriggerType == "Scheduled" && TimeOnly.TryParseExact(job.ScheduleTime,"HH:mm",out var time) &&
                        TimeOnly.FromDateTime(DateTime.Now) >= time && job.LastScheduledRun != DateTime.Now.ToString("yyyy-MM-dd"))
                    {
                        lock(launchLock)
                        {
                            if(updateHolds>0)continue;
                            job.LastScheduledRun=DateTime.Now.ToString("yyyy-MM-dd");
                            _ = RunAsync(job);
                        }
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
    }
    private void RepairWatchers()
    {
        lock(watcherLock)
        {
            if(stop.IsCancellationRequested)return;
            foreach(var key in brokenWatchers.Keys.ToArray())if(brokenWatchers.TryRemove(key,out _)){if(watchers.TryRemove(key,out var watcher))watcher.Dispose();}
            foreach(var job in jobs)
            foreach(var root in job.DestinationType=="Local" ? new[]{job.Source,job.Destination} : new[]{job.Source})
            {
                var key=job.Id+"|"+PathPolicy.Root(root);
                if(!watchers.ContainsKey(key) && Directory.Exists(root)){reconcile[job.Id]=true;retries.TryRemove(job.Id,out _);Watch(job,root);}
            }
        }
    }
    private void PersistQueue()
    {
        lock(queueLock)
        {
            long version=Interlocked.Read(ref queueVersion);if(version==savedQueueVersion)return;
            JsonFile.Save(QueuePath,changed.ToDictionary(p=>p.Key,p=>p.Value.ToDictionary(v=>v.Key,v=>v.Value)));savedQueueVersion=version;
        }
    }
    public async ValueTask DisposeAsync()
    {
        lock(launchLock)stop.Cancel();
        lock(watcherLock){foreach(var watcher in watchers.Values)watcher.Dispose();watchers.Clear();}
        foreach (var task in running.Values) task.Pause.Resume();
        if (loop != null) await loop;
        await Task.WhenAll(running.Values.Select(v => v.Task));
        PersistQueue();
        stop.Dispose();
    }
    private sealed class DirectProgress(Action<BackupProgress> report) : IProgress<BackupProgress>
    {
        public void Report(BackupProgress value) => report(value);
    }
}
