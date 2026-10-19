using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class CloudTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var ct=CancellationToken.None;
        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"cloud-"+provider);Directory.CreateDirectory(home);
            var source=Path.Combine(home,"source");Directory.CreateDirectory(source);
            var store=new ConfigStore(Path.Combine(home,"data"));var remote=new MemoryRemote(provider);
            var created=await CloudFolders.CreateAsync(remote,"","새 폴더",ct);
            check(created=="새 폴더" && (await remote.StatAsync(created,ct))?.Folder==true,provider+" create folder failed");
            check(await CloudFolders.CreateAsync(remote,created,"하위 폴더",ct)=="새 폴더/하위 폴더",provider+" nested folder created outside current location");
            bool duplicate=false;try{await CloudFolders.CreateAsync(remote,"","새 폴더",ct);}catch(IOException){duplicate=true;}
            check(duplicate,provider+" existing folder silently reused");
            foreach(var name in new[]{"","../escape","a/b","a\\b",".safesync-trash",".safesync-staging","name.","bad:name"})
            {
                bool invalid=false;try{CloudFolders.ChildPath("새 폴더",name);}catch(InvalidDataException){invalid=true;}
                check(invalid,provider+" unsafe folder name accepted: "+name);
            }
            var job=new BackupJob {Source=source,Destination=provider+" / Backup",DestinationType=provider,CloudFolderId=remote.Root,CloudAccountId=remote.AccountId,MirrorDeletes=true};
            var engine=new BackupEngine(store){CloudFactory=_=>remote};
            Task<BackupResult> Run(bool full=false,string[]? changes=null,Dictionary<string,ConflictAction>? resolutions=null)=>engine.RunAsync(job,full,changes,new(),null,ct,resolutions);
            var a=Path.Combine(source,"한글.txt");File.WriteAllText(a,"first");File.SetLastWriteTimeUtc(a,DateTime.UtcNow.AddMinutes(-5));
            var first=await Run(true);check(first.Copied==1 && first.Errors.Count==0,provider+" initial upload failed");
            check(Encoding.UTF8.GetString(remote.Bytes("한글.txt"))=="first",provider+" copied bytes differ");
            check(store.LoadState(job).Files.Single().RemoteId==remote.Files["한글.txt"].Id,provider+" remote ID not stored");
            var unchanged=await Run(true);check(unchanged.Copied==0 && unchanged.Skipped==1,provider+" unchanged upload repeated");
            File.WriteAllText(a,"new version");File.SetLastWriteTimeUtc(a,DateTime.UtcNow);
            var changed=await Run(false,["한글.txt"]);check(changed.Copied==1,provider+" incremental upload failed");
            check(remote.Files.Keys.Any(k=>k.StartsWith(".safesync-trash/") && !remote.Files[k].Folder),provider+" overwrite discarded previous file");
            await remote.SeedAsync("한글.txt","different size and content",File.GetLastWriteTimeUtc(a));
            File.WriteAllText(Path.Combine(source,"second.txt"),"continue despite conflict");
            var conflict=await Run(false,["한글.txt","second.txt"]);
            check(conflict.Conflicts.Count==1 && conflict.Copied==1,provider+" conflict stopped unrelated backup");
            check(conflict.Conflicts[0].BackupSize==remote.Files["한글.txt"].Length,provider+" conflict omitted destination metadata");
            var keep=await Run(resolutions:new(){{"한글.txt",ConflictAction.KeepBoth}});
            check(keep.Copied==1 && remote.Files.Keys.Any(k=>k.StartsWith("한글.txt.SafeSync-conflict-")),provider+" keep both failed");
            File.Delete(a);var deleted=await Run(false,["한글.txt"]);check(deleted.Trashed==1 && !remote.Files.ContainsKey("한글.txt"),provider+" mirror delete bypassed trash");
            var publisher=new CloudPublisher(store,job,remote);var trash=new CloudTrash(remote,publisher);var listed=new List<CloudTrashItem>();
            await foreach(var item in trash.ListAsync(ct))listed.Add(item);
            var restore=listed.Last(i=>i.RelativePath=="한글.txt");await trash.OperateAsync(restore,true,ct);
            check(remote.Files.ContainsKey("한글.txt") && !remote.Files.ContainsKey(restore.StoragePath),provider+" cloud restore failed");
            check(listed.All(i=>i.DeletedAt.Year==DateTime.Now.Year && i.OriginalPath.Contains(provider)),provider+" flat trash metadata failed");
            var another=listed.First(i=>i.StoragePath!=restore.StoragePath);await trash.OperateAsync(another,false,ct);
            check(!remote.Files.ContainsKey(another.StoragePath),provider+" selected trash deletion failed");
            bool forged=false;try{await trash.OperateAsync(another with{StoragePath="outside.txt"},false,ct);}catch(InvalidDataException){forged=true;}
            check(forged,provider+" forged trash path accepted");
            var locked=Path.Combine(source,"locked.txt");File.WriteAllText(locked,"locked");
            using(var writer=new FileStream(locked,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            {var result=await Run(false,["locked.txt"]);check(result.Locked.Count==1 && result.Errors.Count==0,provider+" locked file emitted error");}
            check((await Run()).Copied==1,provider+" locked retry failed");
            var payload=Path.Combine(source,"transaction.txt");File.WriteAllText(payload,"replacement");
            await remote.SeedAsync("transaction.txt","previous",DateTime.UtcNow.AddHours(-1));var old=remote.Files["transaction.txt"];
            var snapshot=await publisher.StageAsync(payload,ct);remote.CorruptUpload=true;bool rejected=false;
            try{await publisher.PublishAsync("transaction.txt",snapshot,old,false,new(),ct);}catch(IOException){rejected=true;}
            check(rejected && remote.Files["transaction.txt"]==old,provider+" checksum mismatch overwrote existing backup");
            check((await publisher.RecoverAsync(null,new(),ct)).Count==0 && Encoding.UTF8.GetString(remote.Bytes("transaction.txt"))=="replacement",provider+" rejected upload did not retry safely");
            File.WriteAllText(payload,"after interruption");snapshot=await publisher.StageAsync(payload,ct);old=remote.Files["transaction.txt"];remote.FailBeforePublish=true;
            try{await publisher.PublishAsync("transaction.txt",snapshot,old,false,new(),ct);}catch(IOException){}
            check(!remote.Files.ContainsKey("transaction.txt") && publisher.ProtectedTrashBatches().Count>0,provider+" interrupted old copy not protected");
            check((await publisher.RecoverAsync(null,new(),ct)).Count==0 && Encoding.UTF8.GetString(remote.Bytes("transaction.txt"))=="after interruption",provider+" interrupted replacement recovery failed");
            File.WriteAllText(payload,"lost response");snapshot=await publisher.StageAsync(payload,ct);old=remote.Files["transaction.txt"];remote.LosePublishResponse=true;
            try{await publisher.PublishAsync("transaction.txt",snapshot,old,false,new(),ct);}catch(IOException){}
            check((await publisher.RecoverAsync(null,new(),ct)).Count==0 && Encoding.UTF8.GetString(remote.Bytes("transaction.txt"))=="lost response",provider+" lost response not reconciled");
            File.WriteAllText(payload,"corrupt final");snapshot=await publisher.StageAsync(payload,ct);old=remote.Files["transaction.txt"];remote.CorruptPublish=true;
            try{await publisher.PublishAsync("transaction.txt",snapshot,old,false,new(),ct);}catch(IOException){}
            check(remote.Files["transaction.txt"]==old,provider+" final verification did not roll back");
            check((await publisher.RecoverAsync(null,new(),ct)).Count==0 && Encoding.UTF8.GetString(remote.Bytes("transaction.txt"))=="corrupt final",provider+" rollback retry failed");
            File.WriteAllText(payload,"new intent");snapshot=await publisher.StageAsync(payload,ct);old=remote.Files["transaction.txt"];remote.FailBeforePublish=true;
            try{await publisher.PublishAsync("transaction.txt",snapshot,old,false,new(),ct);}catch(IOException){}
            await remote.SeedAsync("transaction.txt","external edit",DateTime.UtcNow);
            check((await publisher.RecoverAsync(null,new(),ct)).Single().Error is CloudConflictException && Encoding.UTF8.GetString(remote.Bytes("transaction.txt"))=="external edit",provider+" external changes overwritten during recovery");
            await publisher.RecoverAsync(new Dictionary<string,ConflictAction>{{"transaction.txt",ConflictAction.Ignore}},new(),ct);
            check((await publisher.RecoverAsync(null,new(),ct)).Count==0,provider+" abandoned intent replayed");
            var wrong=new BackupJob {Source=source,DestinationType=provider,CloudFolderId=remote.Root,CloudAccountId="different"};bool mismatch=false;
            try{await engine.RunAsync(wrong,true,null,new(),null,ct);}catch(InvalidOperationException){mismatch=true;}
            check(mismatch,provider+" accepted mismatched account");
        }
        await MigrationAsync(root,check);
        await CloudProtocolTests.RunAsync(root,check);
    }
    private static async Task MigrationAsync(string root,Action<bool,string> check)
    {
        var vault=new WindowsSecretVault();string plain="합성-test-token-not-real";var encrypted=vault.Protect(plain);
        check(encrypted.StartsWith("dpapi:") && vault.Unprotect(encrypted)==plain,"DPAPI roundtrip failed");
        check(vault.Unprotect(encrypted[6..])==plain,"Legacy unprefixed DPAPI failed");
        var key=RandomNumberGenerator.GetBytes(64);using var aes=Aes.Create();aes.Key=key[..32];aes.GenerateIV();
        var cipher=aes.EncryptCbc(Encoding.UTF8.GetBytes(plain),aes.IV);var payload=aes.IV.Concat(cipher).ToArray();var bytes=payload.Concat(HMACSHA256.HashData(key.AsSpan(32),payload)).ToArray();
        var legacyEncrypted="aes:"+Convert.ToBase64String(bytes);check(vault.Unprotect(legacyEncrypted,key)==plain,"Legacy AES compatibility failed");
        bytes[^1]^=1;bool tampered=false;try{vault.Unprotect("aes:"+Convert.ToBase64String(bytes),key);}catch(CryptographicException){tampered=true;}check(tampered,"Tampered credential accepted");
        var home=Path.Combine(root,"migration");var legacy=new ConfigStore(Path.Combine(home,"old"));var target=new ConfigStore(Path.Combine(home,"new"));
        var job=new BackupJob {Source=Path.Combine(home,"source"),DestinationType="GoogleDrive",Destination="Google Drive / Backup",CloudFolderId="folder",CloudAccountId="account"};
        var config=new AppConfig {Jobs=[job],AutoStart=true};new CloudAccounts {GoogleDrive=new(){ClientId="client",AccountId="account",RefreshTokenProtected=legacyEncrypted}}.Write(config);legacy.Save(config);
        File.WriteAllBytes(Path.Combine(legacy.Root,"secrets.key"),key);
        var state=ConfigStore.NewState(job);state.Source="";state.Destination="";state.Files=[new(){RelativePath="한글.txt",Status="Failed"}];state.PendingPaths=["한글.txt","pending.txt"];
        state.Generation="generation";state.Extra=new(){{"GoogleChangeToken",JsonSerializer.SerializeToElement("cursor")}};JsonFile.Save(legacy.StatePath(job.Id),state);
        JsonFile.Save(legacy.StatePath(job.Id)+".checkpoints/001.json",new{Generation="generation",Entries=new[]{new FileEntry {RelativePath="한글.txt",Status="BackedUp",RemoteId="remote-id"}},RemovedKeys=Array.Empty<string>(),CompletedPaths=new[]{"한글.txt"}});
        JsonFile.Save(legacy.StatePath(job.Id)+".checkpoints/002.json",new{Generation="obsolete",Entries=new[]{new FileEntry{RelativePath="wrong.txt"}},CompletedPaths=Array.Empty<string>(),RemovedKeys=Array.Empty<string>()});
        var sourceHash=SHA256.HashData(File.ReadAllBytes(legacy.ConfigPath));var migrated=new LegacyMigration(target,vault).Import(legacy.ConfigPath);
        check(migrated.Jobs.Single().Paused && !migrated.AutoStart,"Migration activated jobs or autostart");
        var loaded=new ConfigStore(target.Root).LoadState(migrated.Jobs.Single());
        check(loaded.Files.Single().Status=="BackedUp" && loaded.Files.Single().RemoteId=="remote-id","Migration did not merge matching checkpoints");
        check(loaded.PendingPaths.SequenceEqual(new[]{"pending.txt"}) && loaded.FullScanRequired,"Migration pending paths/reconcile lost");
        check(vault.Unprotect(CloudAccounts.Read(migrated).GoogleDrive.RefreshTokenProtected)==plain && !File.Exists(Path.Combine(target.Root,"secrets.key")),"Migration did not re-protect legacy secret");
        check(sourceHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(legacy.ConfigPath))),"Migration modified original config");
        var activeBefore=SHA256.HashData(File.ReadAllBytes(target.ConfigPath));state.Files.Add(new(){RelativePath="../outside"});legacy.SaveState(state);bool unsafeState=false;
        try{new LegacyMigration(target,vault).Import(legacy.ConfigPath);}catch(InvalidDataException){unsafeState=true;}
        check(unsafeState && activeBefore.SequenceEqual(SHA256.HashData(File.ReadAllBytes(target.ConfigPath))),"Failed migration changed active config");
        check(new ConfigStore(target.Root).LoadState(migrated.Jobs.Single()).Files.Count==1,"Failed migration changed active snapshots");
        JsonFile.Save(Path.Combine(legacy.Root,"cloud-transactions-v2/pending.json"),new{Pending=true});bool unfinished=false;
        try{new LegacyMigration(target,vault).Import(legacy.ConfigPath);}catch(InvalidOperationException){unfinished=true;}check(unfinished,"Migration ignored active transactions");
        var empty=Path.Combine(root,"empty-hash");File.WriteAllBytes(empty,[]);
        check(await RemotePath.HashAsync("GoogleDrive",empty,default)=="d41d8cd98f00b204e9800998ecf8427e","Google MD5 vector failed");
        check(await RemotePath.HashAsync("Dropbox",empty,default)=="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","Dropbox empty vector failed");
        var large=new byte[4*1024*1024+17];for(int i=0;i<large.Length;i++)large[i]=(byte)(i%251);File.WriteAllBytes(empty,large);
        var expected=Convert.ToHexStringLower(SHA256.HashData(SHA256.HashData(large.AsSpan(0,4*1024*1024)).Concat(SHA256.HashData(large.AsSpan(4*1024*1024))).ToArray()));
        check(await RemotePath.HashAsync("Dropbox",empty,default)==expected,"Dropbox 4 MiB boundary vector failed");
    }
}

internal sealed class MemoryRemote(string provider) : IRemoteStore
{
    public string Provider=>provider;public string Root=>"fake-root";public string AccountId=>"fake-account";
    public Dictionary<string,RemoteItem> Files {get;}=new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string,byte[]> content=new(StringComparer.OrdinalIgnoreCase);
    public bool CorruptUpload,FailBeforePublish,LosePublishResponse,CorruptPublish,CorruptDownload;
    public Task InitializeAsync(CancellationToken token){token.ThrowIfCancellationRequested();return Task.CompletedTask;}
    public Task<RemoteItem?> StatAsync(string path,CancellationToken token){token.ThrowIfCancellationRequested();return Task.FromResult(path.Length==0 ? new RemoteItem(Root,"Test root",true,0,DateTime.MinValue,DateTime.MinValue,"","") : Files.GetValueOrDefault(path));}
    public Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token){token.ThrowIfCancellationRequested();return Task.FromResult<IReadOnlyList<RemoteItem>>(Files.Where(k=>RemotePath.Parent(k.Key)==directory).Select(k=>k.Value).ToArray());}
    public Task EnsureFolderAsync(string path,CancellationToken token)
    {
        string current="";foreach(var part in path.Split('/',StringSplitOptions.RemoveEmptyEntries)){current=current.Length==0 ? part : current+"/"+part;if(!Files.ContainsKey(current))Files[current]=new(Guid.NewGuid().ToString(),part,true,0,DateTime.MinValue,DateTime.MinValue,"","");}
        return Task.CompletedTask;
    }
    public async Task SeedAsync(string path,string value,DateTime time)
    {
        await EnsureFolderAsync(RemotePath.Parent(path),default);var bytes=Encoding.UTF8.GetBytes(value);content[path]=bytes;
        var hash=provider=="GoogleDrive" ? Convert.ToHexStringLower(MD5.HashData(bytes)) : Convert.ToHexStringLower(SHA256.HashData(SHA256.HashData(bytes)));
        Files[path]=new(Guid.NewGuid().ToString(),RemotePath.Name(path),false,bytes.Length,time,time,hash,"1");
    }
    public byte[] Bytes(string path)=>content[path];
    public async Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string path,UploadSession session,Action save,PauseGate pause,CancellationToken token)
    {
        await pause.WaitAsync(token);await EnsureFolderAsync(RemotePath.Parent(path),token);content[path]=File.ReadAllBytes(snapshot.Path);
        var item=new RemoteItem(Guid.NewGuid().ToString(),RemotePath.Name(path),false,snapshot.Length,snapshot.ModifiedUtc,snapshot.CreatedUtc,CorruptUpload ? "bad" : snapshot.Hash,"1");CorruptUpload=false;Files[path]=item;session.Offset=snapshot.Length;save();return item;
    }
    public async Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token)
    {
        token.ThrowIfCancellationRequested();bool publish=from.StartsWith(".safesync-staging/");if(publish && FailBeforePublish){FailBeforePublish=false;throw new IOException("Simulated interruption");}
        if(Files.ContainsKey(to))throw new IOException("No overwrite allowed");await EnsureFolderAsync(RemotePath.Parent(to),token);
        var item=Files[from] with{Name=RemotePath.Name(to)};if(publish && CorruptPublish){CorruptPublish=false;item=item with{Hash="bad"};}
        Files.Remove(from);Files[to]=item;if(content.Remove(from,out var bytes))content[to]=bytes;
        if(publish && LosePublishResponse){LosePublishResponse=false;throw new IOException("Simulated lost response");}return item;
    }
    public Task DownloadAsync(string relative,string localPath,CancellationToken token)
    {
        var bytes=content[relative].ToArray();
        if(CorruptDownload){CorruptDownload=false;if(bytes.Length>0)bytes[0]^=0xff;else bytes=[1];}
        File.WriteAllBytes(localPath,bytes);return Task.CompletedTask;
    }
    public Task DeleteAsync(string path,CancellationToken token){foreach(var key in Files.Keys.Where(k=>k==path || k.StartsWith(path+"/")).ToArray()){Files.Remove(key);content.Remove(key);}return Task.CompletedTask;}
}
