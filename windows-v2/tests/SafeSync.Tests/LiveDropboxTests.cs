using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class LiveDropboxTests
{
    public static async Task BrandingAsync(string root,string configPath,string assetRoot)
    {
        var account=CloudAccounts.Read(JsonFile.Read<AppConfig>(configPath)).Dropbox;var config=new AppConfig();new CloudAccounts{Dropbox=account}.Write(config);
        using var services=new CloudServices(()=>config);using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(3));var ct=timeout.Token;
        var full=services.ForAccountRoot("Dropbox");await full.InitializeAsync(ct);
        var name="SafeSync-app-branding-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8];
        if(await full.StatAsync(name,ct)!=null)throw new IOException("Branding folder already exists.");await full.EnsureFolderAsync(name,ct);
        var folder=(await full.StatAsync(name,ct))!;
        var job=new BackupJob{Source=Path.GetFullPath(assetRoot),Destination="Dropbox / "+name,DestinationType="Dropbox",CloudFolderId="/"+name,CloudFolderIdentity=folder.Id,CloudAccountId=account.AccountId};
        var remote=services.ForJob(job);await remote.InitializeAsync(ct);var store=new ConfigStore(Path.Combine(root,"branding-state"));var publisher=new CloudPublisher(store,job,remote);
        foreach(int size in new[]{64,256})
        {
            string file="SafeSync-"+size+".png",path=Path.Combine(assetRoot,file);
            var snapshot=await publisher.StageAsync(path,ct);var item=await publisher.PublishAsync(file,snapshot,null,false,new(),ct);
            if(!RemotePath.Content(item,snapshot))throw new IOException("Branding icon verification failed.");
        }
        JsonFile.Save(Path.Combine(root,"dropbox-branding-result.json"),new{Status="OK",Folder=name,Files=new[]{"SafeSync-64.png","SafeSync-256.png"},ExistingFilesTouched=false});
        Console.WriteLine("PASS: registration icons uploaded and verified in new folder: "+name);
    }
    public static async Task ConnectAsync(string destination)
    {
        var store=new ConfigStore(destination);
        if(File.Exists(store.ConfigPath))throw new InvalidOperationException("An account fixture already exists. Reuse it instead of overwriting credentials.");
        var config=new AppConfig();var accounts=CloudAccounts.Read(config);
        using var services=new CloudServices(()=>config);
        Console.WriteLine("Waiting for user approval in the Dropbox browser page. No password or app secret is stored.");
        await services.Authentication.ConnectAsync("Dropbox",accounts.Dropbox,default);
        accounts.Write(config);store.Save(config);
        Console.WriteLine("PASS: Dropbox OAuth PKCE completed; test-only refresh token protected with Windows DPAPI.");
    }
    public static async Task RunAsync(string root,string configPath)
    {
        var before=SHA256.HashData(File.ReadAllBytes(configPath));var account=CloudAccounts.Read(JsonFile.Read<AppConfig>(configPath)).Dropbox;
        var config=new AppConfig();new CloudAccounts{Dropbox=account}.Write(config);
        var source=Path.Combine(root,"dropbox-source");Directory.CreateDirectory(source);var store=new ConfigStore(Path.Combine(root,"dropbox-state"));
        var checks=new List<string>();var stages=new List<object>();string selectedPath="",phase="authenticate";
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(15));var ct=timeout.Token;
        using var services=new CloudServices(()=>config);
        void Check(bool value,string label){if(!value)throw new InvalidOperationException(label);checks.Add(label);}
        void Save(string status,string? failure=null)=>JsonFile.Save(Path.Combine(root,"dropbox-live-result.json"),new{Status=status,Phase=phase,Checks=checks,Stages=stages,TestFolder=selectedPath,Failure=failure,ExistingBackupsTouched=false,TestFilesPreserved=true,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath)))});
        try
        {
            var full=services.ForAccountRoot("Dropbox");await full.InitializeAsync(ct);
            var label="SafeSync-validation-twoway-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8];
            Check(await full.StatAsync(label,ct)==null,"Unique test folder did not exist");await full.EnsureFolderAsync(label,ct);var folder=await full.StatAsync(label,ct);
            selectedPath="/"+label;
            var job=new BackupJob {Name="Isolated Dropbox two-way test",Source=source,Destination="Dropbox / "+label,DestinationType="Dropbox",CloudFolderId=selectedPath,CloudFolderIdentity=folder!.Id,CloudAccountId=account.AccountId,SyncMode="TwoWay"};
            var remote=services.ForJob(job);await remote.InitializeAsync(ct);
            Check((await remote.StatAsync("",ct))?.Id==folder.Id,"Job bound to selected folder ID");
            var publisher=new CloudPublisher(store,job,remote);var engine=new BackupEngine(store){CloudFactory=_=>remote};
            string Write(string name,string value){var path=PathPolicy.Combine(source,name);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,value,Encoding.UTF8);return path;}
            async Task Put(string name,string value)
            {
                var path=Path.Combine(root,"external-"+Guid.NewGuid().ToString("N"));File.WriteAllText(path,value,Encoding.UTF8);
                var snapshot=await publisher.StageAsync(path,ct);await publisher.PublishAsync(name,snapshot,await remote.StatAsync(name,ct),false,new(),ct);
            }
            async Task<BackupResult> Run(string stage,bool fullScan=false,string[]? paths=null,Dictionary<string,ConflictAction>? choices=null)
            {
                phase=stage;Console.WriteLine("Dropbox live: "+stage);Save("RUNNING");var watch=Stopwatch.StartNew();
                var result=await engine.RunAsync(job,fullScan,paths,new(),null,ct,choices);
                stages.Add(new{Stage=stage,Milliseconds=watch.ElapsedMilliseconds,result.Copied,result.Trashed,Conflicts=result.Conflicts.Count,Errors=result.Errors.Select(x=>x.Reason).ToArray()});
                Check(!result.Canceled && result.Errors.Count==0,stage+": clean execution");return result;
            }
            Write("원본.txt","local");await Put("remote.txt","cloud");
            Check((await Run("initial-union",true)).Copied==2,"Initial union copies both directions");
            Check(File.ReadAllText(Path.Combine(source,"remote.txt"))=="cloud","Downloaded bytes match");
            Check((await Run("unchanged")).Copied==0,"Unchanged files not recopied");
            Write("원본.txt","local edit");Check((await Run("source-edit",paths:["원본.txt"])).Copied==1,"Source change uploaded");
            await Put("remote.txt","cloud edit");Check((await Run("remote-edit",true)).Copied==1,"Remote change downloaded");
            Check(File.ReadAllText(Path.Combine(source,"remote.txt"))=="cloud edit","Remote edit verified");
            await publisher.TrashAsync("원본.txt",(await remote.StatAsync("원본.txt",ct))!,ct);
            Check((await Run("remote-delete",true)).Trashed==1,"Remote delete propagates");
            Check(new TrashService().List(source,ct).Any(x=>x.RelativePath=="원본.txt"),"Source copy retained in trash");
            File.Delete(Path.Combine(source,"remote.txt"));Check((await Run("source-delete",paths:["remote.txt"])).Trashed==1,"Source delete propagates");
            Check(await remote.StatAsync("remote.txt",ct)==null,"Active backup removed");
            Write("conflict.txt","baseline");await Run("baseline",paths:["conflict.txt"]);
            Write("conflict.txt","local change");await Put("conflict.txt","cloud change");Write("unrelated.txt","continues");
            var conflict=await Run("simultaneous-edits",true);Check(conflict.Conflicts.Count==1 && conflict.Copied==1,"Conflict does not stop unrelated file");
            Check((await Run("use-backup",choices:new(){{"conflict.txt",ConflictAction.UseBackup}})).Conflicts.Count==0,"Reverse conflict resolution works");
            Check(File.ReadAllText(Path.Combine(source,"conflict.txt"))=="cloud change","Chosen backup content restored");
            Directory.CreateDirectory(Path.Combine(source,"empty","nested"));await Run("empty-folders",true);
            Check((await remote.StatAsync("empty/nested",ct))?.Folder==true,"Nested empty folders synchronized");
            // Non-empty parent must not be deleted until its files are handled.
            Write("tree/sub/file.txt","tree");await Run("nested-file",true);
            Check((await remote.StatAsync("tree/sub/file.txt",ct))?.Length==new FileInfo(Path.Combine(source,"tree","sub","file.txt")).Length,"Nested file copied");
            engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>remote};
            Check((await Run("restart")).Copied==0,"Restart retained baseline");
            Check(store.LoadState(job).PendingPaths.Count==0,"Pending checkpoints cleared");
            Check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),"Account fixture unchanged");
            Save("OK");Console.WriteLine($"PASS: {checks.Count} real Dropbox assertions. {root}");
        }
        catch(Exception ex){Save("FAILED",ex.GetType().Name+": "+ex.Message);throw;}
    }
}
