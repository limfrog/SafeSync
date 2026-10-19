using System.Security.Cryptography;
using System.Text.Json;
using SafeSync.Core.Cloud;

namespace SafeSync.Core;

public sealed class LegacyMigration(ConfigStore destination,ISecretVault vault)
{
    public AppConfig Import(string configPath,bool includeSnapshots=true)
    {
        configPath=Path.GetFullPath(configPath);
        if(string.Equals(configPath,destination.ConfigPath,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("같은 설정 파일은 가져올 수 없습니다.");
        if(new FileInfo(configPath).Length>10*1024*1024)throw new InvalidDataException("설정 파일은 10 MB 이하여야 합니다.");
        var sourceRoot=Path.GetDirectoryName(configPath)!;
        var before=SHA256.HashData(File.ReadAllBytes(configPath));
        var config=JsonFile.Read<AppConfig>(configPath);ConfigStore.Validate(config);
        foreach(var folder in new[]{"transactions","cloud-transactions-v2"})
            if(Directory.Exists(Path.Combine(sourceRoot,folder)) && Directory.EnumerateFiles(Path.Combine(sourceRoot,folder),"*.json").Any())
                throw new InvalidOperationException("원본 앱에 미완료 전송/교체 기록이 있습니다. 원본 앱에서 복구를 끝낸 뒤 가져오세요.");
        var accounts=CloudAccounts.Read(config);
        byte[]? key=null;
        try
        {
            if(new[]{accounts.Dropbox,accounts.GoogleDrive}.Any(a=>a.RefreshTokenProtected.StartsWith("aes:",StringComparison.Ordinal)||a.ClientSecretProtected.StartsWith("aes:",StringComparison.Ordinal)))
            {
                var keyPath=Path.Combine(sourceRoot,"secrets.key");
                PathPolicy.RejectLinks(sourceRoot,keyPath);key=File.ReadAllBytes(keyPath);
                if(key.Length!=64)throw new CryptographicException("기존 인증 정보 키의 길이가 잘못되었습니다.");
            }
            foreach(var account in new[]{accounts.Dropbox,accounts.GoogleDrive})
            {
                account.RefreshTokenProtected=vault.Protect(vault.Unprotect(account.RefreshTokenProtected,key));
                account.ClientSecretProtected=vault.Protect(vault.Unprotect(account.ClientSecretProtected,key));
            }
        }
        finally{if(key!=null)CryptographicOperations.ZeroMemory(key);}
        accounts.Write(config);config.AutoStart=false;
        string sourceManifests=Path.Combine(sourceRoot,"manifests");
        if(config.Extra!=null && config.Extra.TryGetValue("NativeStateGeneration",out var priorGeneration))
        {
            var generation=priorGeneration.GetString() ?? "";
            if(!Guid.TryParseExact(generation,"N",out _))throw new InvalidDataException("원본 상태 세대가 잘못되었습니다.");
            sourceManifests=Path.Combine(sourceRoot,"state-generations",generation,"manifests");
        }
        var nextGeneration=Guid.NewGuid().ToString("N");
        var target=Path.Combine(destination.Root,"state-generations",nextGeneration,"manifests");
        foreach(var job in config.Jobs)
        {
            job.Paused=true;
            if(job.DestinationType!="Local")job.CloudAccountId=accounts.For(job.DestinationType).AccountId;
            if(!includeSnapshots)continue;
            var snapshot=Path.Combine(sourceManifests,job.Id+".sync.json");
            if(!File.Exists(snapshot))continue;
            PathPolicy.RejectLinks(sourceRoot,snapshot);
            var nativeDeltas=snapshot+".native-deltas";
            if(Directory.Exists(nativeDeltas))
            {
                PathPolicy.RejectLinks(sourceRoot,nativeDeltas);
                foreach(var delta in Directory.EnumerateFiles(nativeDeltas,"*.json"))PathPolicy.RejectLinks(sourceRoot,delta);
            }
            var state=StateDeltas.Load(snapshot);
            if(state.JobId!=job.Id || (state.Source.Length>0 && !state.Source.Equals(job.Source,StringComparison.OrdinalIgnoreCase)) || (state.Destination.Length>0 && !state.Destination.Equals(job.Destination,StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("기존 스냅샷이 작업의 원본/백업 위치와 다릅니다.");
            var entries=state.Files.ToDictionary(e=>PathPolicy.Relative(e.RelativePath),StringComparer.OrdinalIgnoreCase);
            var pending=new HashSet<string>(state.PendingPaths.Select(PathPolicy.Relative),StringComparer.OrdinalIgnoreCase);
            var parts=snapshot+".checkpoints";
            var originalGeneration=state.Generation.Length>0 ? state.Generation : state.Extra!=null && state.Extra.TryGetValue("Generation",out var stateGeneration) ? stateGeneration.GetString() ?? "" : "";
            if(Directory.Exists(parts))
                foreach(var segment in Directory.EnumerateFiles(parts,"*.json").Order(StringComparer.Ordinal))
                {
                    PathPolicy.RejectLinks(sourceRoot,segment);var delta=JsonFile.Read<Delta>(segment);
                    if(delta.Generation!=originalGeneration)continue;
                    foreach(var entry in delta.Entries)entries[PathPolicy.Relative(entry.RelativePath)]=entry;
                    foreach(var removed in delta.RemovedKeys)entries.Remove(PathPolicy.Relative(removed));
                    foreach(var completed in delta.CompletedPaths)pending.Remove(PathPolicy.Relative(completed));
                }
            state.Source=job.Source;state.Destination=job.Destination;state.DestinationType=job.DestinationType;
            state.CloudFolderId=job.CloudFolderId;state.CloudFolderIdentity=job.CloudFolderIdentity;state.CloudAccountId=job.CloudAccountId;
            state.Files=entries.Values.ToList();state.PendingPaths=pending.ToList();
            // Preserve progress, but reconcile metadata once rather than trusting
            // an unverified cross-version journal/cursor as proof of success.
            state.FullScanRequired=true;
            JsonFile.Save(Path.Combine(target,job.Id+".sync.json"),state);
        }
        if(!before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))))throw new IOException("가져오는 동안 원본 설정이 변경되었습니다. 원본 앱을 종료하고 다시 시도하세요.");
        config.Extra??=new();config.Extra["NativeStateGeneration"]=JsonSerializer.SerializeToElement(nextGeneration);
        if(File.Exists(destination.ConfigPath))File.Copy(destination.ConfigPath,destination.ConfigPath+".before-import-"+Guid.NewGuid().ToString("N"));
        // One atomic config replacement activates the complete new generation.
        // Failed imports leave the previous config and its snapshot generation active.
        destination.Save(config);return config;
    }
    private sealed class Delta
    {
        public string Generation {get;set;}="";
        public List<FileEntry> Entries {get;set;}=[];
        public List<string> RemovedKeys {get;set;}=[];
        public List<string> CompletedPaths {get;set;}=[];
    }
}
