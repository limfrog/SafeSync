using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class ReleaseSafetyTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        await RetryAsync(check);
        var source=new ConfigStore(Path.Combine(root,"native-migration-source"));
        var job=new BackupJob {Source=Path.Combine(root,"native-source"),Destination=Path.Combine(root,"native-destination")};
        source.Save(new(){Jobs=[job]});var state=ConfigStore.NewState(job);
        state.Files=[new(){RelativePath="one.txt",Status="Failed"}];state.PendingPaths=["one.txt","two.txt"];
        source.SaveState(state);var entry=new FileEntry{RelativePath="one.txt",Status="BackedUp"};
        source.SaveCheckpoint(state,new Dictionary<string,FileEntry>{{"one.txt",entry}},new HashSet<string>{"two.txt"},["one.txt"]);
        var target=new ConfigStore(Path.Combine(root,"native-migration-target"));
        var imported=new LegacyMigration(target,new WindowsSecretVault()).Import(source.ConfigPath);
        var reloaded=new ConfigStore(target.Root).LoadState(imported.Jobs.Single());
        check(reloaded.Files.Single().Status=="BackedUp" && reloaded.PendingPaths.SequenceEqual(new[]{"two.txt"}),"Native migration lost completed delta checkpoint");
        check(source.LoadState(job).PendingPaths.SequenceEqual(new[]{"two.txt"}),"Migration modified source checkpoint");
        state.Extra=new(){{"Generation",JsonSerializer.SerializeToElement("stale-generation")}};source.SaveState(state);
        check(source.LoadState(job).Generation==state.Generation && !File.ReadAllText(source.StatePath(job.Id)).Contains("stale-generation"),"Extension data overwrote snapshot generation");
    }

    private static async Task RetryAsync(Action<bool,string> check)
    {
        var cooldown=new CloudRetryState();cooldown.Defer(TimeSpan.FromMinutes(3));int sent=0;
        using(var client=new HttpClient(new Handler((_,_)=>{sent++;return Task.FromResult(Json());})))
        {
            foreach(int run in new[]{1,2})
            {
                var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),retryState:cooldown);bool deferred=false;
                try{await http.SendAsync(()=>new(HttpMethod.Get,"https://www.googleapis.com/drive/v3/files"),default);}catch(CloudApiException ex){deferred=ex.Status==HttpStatusCode.TooManyRequests && ex.RetryAfter>TimeSpan.FromMinutes(2);}
                check(deferred && sent==0,"New job bypassed shared Retry-After cooldown "+run);
            }
        }
        foreach(var status in new[]{HttpStatusCode.TooManyRequests,HttpStatusCode.ServiceUnavailable,HttpStatusCode.BadGateway})
        {
            int calls=0;var delays=new List<TimeSpan>();
            using var client=new HttpClient(new Handler((_,_)=>Task.FromResult(++calls<3 ? new HttpResponseMessage(status) : Json())));
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(delay,_)=>{delays.Add(delay);return Task.CompletedTask;});
            using var result=await http.SendAsync(()=>new(HttpMethod.Get,"https://www.googleapis.com/drive/v3/files"),default);
            check(calls==3 && delays.Count==2 && delays[1]>delays[0],"Read retry/backoff failed: "+status);
        }
        foreach(var route in new[]{"/2/files/get_metadata","/2/files/list_folder/continue"})
        {
            int calls=0;using var client=new HttpClient(new Handler((_,_)=>Task.FromResult(++calls==1 ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) : Json())));
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(_,_)=>Task.CompletedTask);
            using var result=await http.SendAsync(()=>new(HttpMethod.Post,"https://api.dropboxapi.com"+route){Content=CloudJson.Body(new{cursor="synthetic"})},default);
            check(calls==2,"Dropbox metadata POST was not safely retried");
        }
        foreach(var method in new[]{HttpMethod.Post,HttpMethod.Patch,HttpMethod.Put,HttpMethod.Delete})
        {
            int calls=0;using var client=new HttpClient(new Handler((_,_)=>{calls++;return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));}));
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(_,_)=>Task.CompletedTask);
            try{await http.SendAsync(()=>new(method,"https://www.googleapis.com/drive/v3/files"),default);}catch(CloudApiException){}
            check(calls==1,"Ambiguous mutation was blindly repeated: "+method);
        }
        foreach(bool limited in new[]{false,true})
        {
            int calls=0;using var client=new HttpClient(new Handler((_,_)=>Task.FromResult(++calls==1
                ? new HttpResponseMessage(HttpStatusCode.Forbidden){Content=CloudJson.Body(new{error=new{errors=new[]{new{reason=limited ? "userRateLimitExceeded" : "insufficientFilePermissions"}}}})} : Json())));
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(_,_)=>Task.CompletedTask);
            try{using var response=await http.SendAsync(()=>new(HttpMethod.Get,"https://www.googleapis.com/drive/v3/files"),default);}catch(CloudApiException){}
            check(calls==(limited ? 2 : 1),"403 permission/rate limit distinction failed");
        }
        int attempts=0;using(var client=new HttpClient(new Handler((_,_)=>{attempts++;var response=new HttpResponseMessage(HttpStatusCode.TooManyRequests);response.Headers.RetryAfter=new(TimeSpan.FromSeconds(7));return Task.FromResult(response);})))
        {
            var delays=new List<TimeSpan>();var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(delay,_)=>{delays.Add(delay);return Task.CompletedTask;});
            try{await http.SendAsync(()=>new(HttpMethod.Get,"https://www.googleapis.com/drive/v3/files"),default);}catch(CloudApiException){}
            check(attempts==5 && delays.Count==4 && delays.All(d=>d==TimeSpan.FromSeconds(7)),"Retry-After not honored or retries unbounded");
        }
        using(var cancel=new CancellationTokenSource())
        using(var client=new HttpClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.TooManyRequests)))))
        {
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"),(_,ct)=>{cancel.Cancel();return Task.Delay(10000,ct);});bool canceled=false;
            try{await http.SendAsync(()=>new(HttpMethod.Get,"https://www.googleapis.com/drive/v3/files"),cancel.Token);}catch(OperationCanceledException){canceled=true;}
            check(canceled,"Retry delay prevented shutdown cancellation");
        }
    }
    private static HttpResponseMessage Json()=>new(HttpStatusCode.OK){Content=CloudJson.Body(new{ok=true})};
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> send) : HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)=>send(request,token);}

    public static async Task NasAsync(string root,string nasRoot,Action<bool,string> check)
    {
        nasRoot=Path.GetFullPath(nasRoot);
        if(!nasRoot.StartsWith(@"\\",StringComparison.Ordinal) || !Directory.Exists(nasRoot))throw new IOException("NAS test root unavailable.");
        string run="SafeSync-validation-"+Guid.NewGuid().ToString("N"),home=Path.Combine(nasRoot,run);
        Directory.CreateDirectory(home);JsonFile.Save(Path.Combine(home,"TEST-ONLY.json"),new{Product="SafeSync",CreatedUtc=DateTime.UtcNow,LocalReportRoot=root});
        var measurements=new List<object>();
        foreach(bool sourceOnNas in new[]{false,true})
        {
            string local=Path.Combine(root,sourceOnNas ? "from-nas" : "to-nas"),network=Path.Combine(home,sourceOnNas ? "source" : "backup");
            Directory.CreateDirectory(local);Directory.CreateDirectory(network);
            string source=sourceOnNas ? network : local,backup=sourceOnNas ? local : network;
            var job=new BackupJob{Name="NAS validation",Source=source,Destination=backup,MirrorDeletes=true};
            var store=new ConfigStore(Path.Combine(root,"nas-state-"+sourceOnNas));var engine=new BackupEngine(store);
            for(int i=0;i<120;i++)File.WriteAllText(Path.Combine(source,$"한글-{i:D4}.txt"),"원본 "+i);
            var nested=Path.Combine(source,"긴 폴더 이름 테스트",new string('a',80));Directory.CreateDirectory(nested);File.WriteAllText(Path.Combine(nested,"이름😀.txt"),"unicode");
            File.WriteAllBytes(Path.Combine(source,"empty.bin"),[]);
            var bytes=RandomNumberGenerator.GetBytes(32*1024*1024+17);File.WriteAllBytes(Path.Combine(source,"large.bin"),bytes);
            var watch=Stopwatch.StartNew();var first=await engine.RunAsync(job,true,null,new(),null,default);
            measurements.Add(new{Direction=sourceOnNas ? "NAS-to-local" : "local-to-NAS",Stage="first",Milliseconds=watch.ElapsedMilliseconds,Copied=first.Copied});
            check(first.Errors.Count==0 && first.Copied==123,"NAS initial backup failed: "+string.Join(';',first.Errors.Select(e=>e.Reason)));
            check(SHA256.HashData(File.ReadAllBytes(Path.Combine(backup,"large.bin"))).SequenceEqual(SHA256.HashData(bytes)),"NAS large-file hash mismatch");
            watch.Restart();var unchanged=await engine.RunAsync(job,true,null,new(),null,default);
            measurements.Add(new{Direction=sourceOnNas ? "NAS-to-local" : "local-to-NAS",Stage="unchanged",Milliseconds=watch.ElapsedMilliseconds,Skipped=unchanged.Skipped});
            check(unchanged.Skipped==123 && unchanged.Copied==0,"NAS unchanged files recopied");
            string changed=Path.Combine(source,"한글-0000.txt");File.WriteAllText(changed,"새 내용");File.SetLastWriteTimeUtc(changed,DateTime.UtcNow.AddMinutes(1));
            watch.Restart();var update=await engine.RunAsync(job,false,["한글-0000.txt"],new(),null,default);
            measurements.Add(new{Direction=sourceOnNas ? "NAS-to-local" : "local-to-NAS",Stage="incremental",Milliseconds=watch.ElapsedMilliseconds,Copied=update.Copied});
            check(update.Copied==1 && update.Errors.Count==0,"NAS atomic replacement unsupported or failed");
            var trash=new TrashService();check(trash.List(backup,default).Any(t=>t.RelativePath=="한글-0000.txt"),"NAS replacement lost previous version");
            using(var locked=new FileStream(Path.Combine(source,"한글-0001.txt"),FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            {
                var waiting=await engine.RunAsync(job,false,["한글-0001.txt"],new(),null,default);
                check(waiting.Locked.Count==1 && waiting.Errors.Count==0,"NAS locked file raised ordinary error");
            }
            var retried=await engine.RunAsync(job,false,null,new(),null,default);check(retried.Locked.Count==0 && store.LoadState(job).PendingPaths.Count==0,"NAS unlocked file did not leave queue");
            File.Delete(Path.Combine(source,"한글-0002.txt"));var deleted=await engine.RunAsync(job,false,["한글-0002.txt"],new(),null,default);
            check(deleted.Trashed==1,"NAS deletion did not use trash");
            var item=trash.List(backup,default).Single(t=>t.RelativePath=="한글-0002.txt");await trash.RestoreAsync(backup,item,default);
            check(File.ReadAllText(Path.Combine(backup,"한글-0002.txt"))=="원본 2","NAS trash restore mismatch");
            // Only rename our freshly created endpoint, never disconnect the
            // user's NAS or network adapter. Real physical outages remain open.
            string offline=network+"-temporarily-unavailable";
            if(!Path.GetFullPath(offline).StartsWith(home+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("Unsafe NAS fixture move.");
            Directory.Move(network,offline);
            try
            {
                bool rejected=false;try{await engine.RunAsync(job,true,null,new(),null,default);}catch(DirectoryNotFoundException){rejected=true;}
                check(rejected,"Missing NAS endpoint was treated as empty successful backup");
            }
            finally{Directory.Move(offline,network);}
            check(File.Exists(Path.Combine(backup,"large.bin")),"Unavailable endpoint damaged backup");
        }
        JsonFile.Save(Path.Combine(root,"nas-result.json"),new{Status="OK",NasFixture=home,Measurements=measurements,PhysicalDisconnectTested=false});
        Console.WriteLine("NAS fixtures preserved: "+home);
    }
}
