using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SafeSync.Core;

public static class JsonFile
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true, WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    public static T Read<T>(string path)
    {
        using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
        using var reader = new StreamReader(input, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return JsonSerializer.Deserialize<T>(reader.ReadToEnd(), Options) ?? throw new InvalidDataException("비어 있는 JSON 파일입니다.");
    }
    public static void Save<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, value, Options);
                output.Flush(true);
            }
            for(int attempt=0;;attempt++)
            {
                try
                {
                    if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);
                    break;
                }
                catch(IOException ex) when(attempt<4 && ((ex.HResult&0xFFFF) is 32 or 33 or 1175 or 1176 or 1177))
                {
                    // Readers/AV may briefly deny atomic replacement. Never
                    // delete the destination or fall back to in-place writes.
                    Thread.Sleep(25*(1<<attempt));
                }
            }
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

public sealed class ConfigStore(string dataRoot)
{
    private string stateGeneration="";
    private bool generationLoaded;
    public string Root { get; } = Path.GetFullPath(dataRoot);
    public string ConfigPath => Path.Combine(Root, "config.json");
    public AppConfig Load()
    {
        if (!File.Exists(ConfigPath)) return new();
        var config = JsonFile.Read<AppConfig>(ConfigPath);
        Validate(config);
        // preview.3 stored a compatibility pause flag on ended jobs.
        foreach(var job in config.Jobs.Where(j=>j.Stopped))job.Paused=false;
        SetGeneration(config);
        return config;
    }
    public void Save(AppConfig config) { Validate(config);ValidateGeneration(config);JsonFile.Save(ConfigPath, config);SetGeneration(config); }
    public string StatePath(string id)
    {
        ValidateId(id);
        if(!generationLoaded){SetGeneration(File.Exists(ConfigPath) ? JsonFile.Read<AppConfig>(ConfigPath) : new());}
        return Path.Combine(stateGeneration.Length==0 ? Root : Path.Combine(Root,"state-generations",stateGeneration), "manifests", id + ".sync.json");
    }
    public JobState LoadState(BackupJob job)
    {
        var path = StatePath(job.Id);
        if (!File.Exists(path)) return NewState(job);
        var state = StateDeltas.Load(path);
        if(state.JobId!=job.Id)throw new InvalidDataException("스냅샷의 작업 ID가 다릅니다.");
        // Never reuse a snapshot for different endpoints, even if an imported ID matches.
        if (state.SyncMode!=job.SyncMode || !string.Equals(state.Source, job.Source, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(state.Destination, job.Destination, StringComparison.OrdinalIgnoreCase) || state.DestinationType!=job.DestinationType || state.CloudFolderId!=job.CloudFolderId || state.CloudAccountId!=job.CloudAccountId || state.CloudFolderIdentity!=job.CloudFolderIdentity)
            return NewState(job);
        foreach (var entry in state.Files) PathPolicy.Relative(entry.RelativePath);
        foreach (var pending in state.PendingPaths) PathPolicy.Relative(pending);
        return state;
    }
    public void SaveState(JobState state) => StateDeltas.Save(StatePath(state.JobId), state);
    public void SaveCheckpoint(JobState state,IReadOnlyDictionary<string,FileEntry> entries,ISet<string> pending,IEnumerable<string> paths)=>StateDeltas.Append(StatePath(state.JobId),state,entries,pending,paths);
    public static JobState NewState(BackupJob job)=>new(){JobId=job.Id,SyncMode=job.SyncMode,Source=job.Source,Destination=job.Destination,DestinationType=job.DestinationType,CloudFolderId=job.CloudFolderId,CloudFolderIdentity=job.CloudFolderIdentity,CloudAccountId=job.CloudAccountId};
    public AppConfig ImportLegacy(string configPath)
    {
        return new LegacyMigration(this,new Cloud.WindowsSecretVault()).Import(configPath);
    }
    private static string ValidateGeneration(AppConfig config)
    {
        var generation=config.Extra!=null && config.Extra.TryGetValue("NativeStateGeneration",out var value) ? value.GetString() ?? "" : "";
        if(generation.Length>0 && !Guid.TryParseExact(generation,"N",out _))throw new InvalidDataException("잘못된 상태 세대입니다.");
        return generation;
    }
    private void SetGeneration(AppConfig config){stateGeneration=ValidateGeneration(config);generationLoaded=true;}
    public static void Validate(AppConfig config)
    {
        if (config.Jobs is null || config.Jobs.Count > 1000) throw new InvalidDataException("작업 목록이 잘못되었습니다.");
        if (config.TrashRetentionDays is < 1 or > 3650) throw new InvalidDataException("휴지통 보관 기간은 1~3650일입니다.");
        if (config.ThemeMode is not ("Light" or "Dark")) throw new InvalidDataException("화면 모드가 잘못되었습니다.");
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var job in config.Jobs)
        {
            ValidateJob(job);
            if (!ids.Add(job.Id)) throw new InvalidDataException("작업 ID가 중복되었습니다.");
        }
    }
    public static void ValidateJob(BackupJob job)
    {
        ValidateId(job.Id);
        if(job.SyncMode is not ("OneWay" or "TwoWay"))throw new InvalidDataException("동기화 방향을 확인하세요.");
        if (string.IsNullOrWhiteSpace(job.Name) || job.Name.Length > 200) throw new InvalidDataException("작업 이름을 확인하세요.");
        if (!Path.IsPathFullyQualified(job.Source)) throw new InvalidDataException("원본은 절대 경로여야 합니다.");
        if (job.TriggerType is not ("Realtime" or "Scheduled") || !TimeOnly.TryParseExact(job.ScheduleTime,"HH:mm", out _))
            throw new InvalidDataException("예약 설정을 확인하세요.");
        if (job.DestinationType == "Local") PathPolicy.ValidateRoots(job.Source, job.Destination);
        else if (job.DestinationType is not ("GoogleDrive" or "Dropbox") || string.IsNullOrWhiteSpace(job.CloudFolderId))
            throw new InvalidDataException("백업 위치를 확인하세요.");
    }
    public static void ValidateId(string id)
    {
        if (string.IsNullOrEmpty(id) || !Regex.IsMatch(id, "^[a-zA-Z0-9_.-]{1,128}$") || id is "." or "..")
            throw new InvalidDataException("작업 ID가 잘못되었습니다.");
    }
}

public static class PathPolicy
{
    public static string Root(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    public static string Relative(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || Path.IsPathRooted(path) || path.Contains(':')) throw new InvalidDataException("잘못된 상대 경로입니다.");
        var parts = path.Replace('\\','/').Split('/');
        if (parts.Any(p => p is "" or "." or ".." || p.EndsWith(' ') || p.EndsWith('.') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
            throw new InvalidDataException("안전하지 않은 파일 경로입니다.");
        return string.Join('/', parts);
    }
    public static bool Inside(string root, string path) => Path.GetFullPath(path).StartsWith(Root(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    public static string Combine(string root, string relative)
    {
        var result = Path.GetFullPath(Path.Combine(root, Relative(relative).Replace('/', Path.DirectorySeparatorChar)));
        if (!Inside(root, result)) throw new InvalidDataException("백업 경로를 벗어났습니다.");
        RejectLinks(root, result);
        return result;
    }
    public static void ValidateRoots(string source, string destination)
    {
        if (!Path.IsPathFullyQualified(source) || !Path.IsPathFullyQualified(destination)) throw new InvalidDataException("절대 경로를 지정하세요.");
        if (string.Equals(Root(source), Root(destination), StringComparison.OrdinalIgnoreCase) || Inside(source, destination) || Inside(destination, source))
            throw new InvalidDataException("원본과 백업 위치는 서로 겹칠 수 없습니다.");
    }
    public static void RejectLinks(string root, string path)
    {
        var current = Path.GetFullPath(path);
        var boundary = Root(root);
        while (true)
        {
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("심볼릭 링크/연결 지점은 안전을 위해 처리하지 않습니다: " + current);
            if (string.Equals(Root(current), boundary, StringComparison.OrdinalIgnoreCase)) break;
            var parent = Path.GetDirectoryName(current);
            if (parent is null) break;
            current = parent;
        }
    }
    public static bool Internal(string relative) => relative.Split('/', '\\').Any(p => p.Equals(".safesync-trash",StringComparison.OrdinalIgnoreCase) ||
        p.Equals(".safesync-staging",StringComparison.OrdinalIgnoreCase) || p.Contains(".safesync-part-",StringComparison.OrdinalIgnoreCase) || p.Contains(".safesync-txn-",StringComparison.OrdinalIgnoreCase));
}
