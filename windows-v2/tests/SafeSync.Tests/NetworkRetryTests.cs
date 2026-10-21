using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class NetworkRetryTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var win32=new IOException("예기치 않은 네트워크 오류가 발생했습니다.",unchecked((int)0x8007003b));
        foreach(var error in new Exception[]{win32,new HttpRequestException("disconnected"),new SocketException((int)SocketError.ConnectionReset),new TimeoutException(),new TaskCanceledException("timeout",new TimeoutException()),new CloudApiException(HttpStatusCode.RequestTimeout,"test"),new CloudApiException(HttpStatusCode.TooManyRequests,"test"),new CloudApiException(HttpStatusCode.ServiceUnavailable,"test")})
            check(NetworkFailures.IsTransient(error),"Transient network error was not classified: "+error.GetType().Name);
        foreach(var error in new Exception[]{new OperationCanceledException(),new TaskCanceledException(),new UnauthorizedAccessException(),new DirectoryNotFoundException(),new InvalidDataException("checksum"),new AuthenticationException(),new HttpRequestException("TLS",new AuthenticationException()),new IOException("storage",unchecked((int)0x80070070)),new IOException("locked",unchecked((int)0x80070020)),new CloudConflictException("a.txt","conflict"),new CloudApiException(HttpStatusCode.Unauthorized,"test"),new CloudApiException(HttpStatusCode.Forbidden,"test"),new CloudApiException(HttpStatusCode.Conflict,"test")})
            check(!NetworkFailures.IsTransient(error),"Permanent error/cancellation was silently made automatic: "+error.GetType().Name);
        check(JobProblem.From(win32,false).Kind=="Network" && JobProblem.From(new CloudApiException(HttpStatusCode.RequestTimeout,"test"),true).Kind=="Network","Network recovery guidance requires a file decision");
        check(!NetworkFailures.LegacyMessage("사용자가 네트워크 파일의 내용을 확인해야 합니다"),"Arbitrary network text was suppressed");
        var old=JsonSerializer.Deserialize<FileIssue>("{\"JobId\":\"j\",\"JobName\":\"test\",\"File\":\"a.txt\",\"Reason\":\"An unexpected network error occurred.\",\"SourceSize\":0,\"BackupSize\":0,\"SourceModified\":\"\",\"BackupModified\":\"\"}");
        check(old!=null && NetworkFailures.Automatic(old) && old.Handling=="자동 재시도","Legacy network record requires a user choice");
        var ledgerRoot=Path.Combine(root,"network-notices");Directory.CreateDirectory(ledgerRoot);var ledger=new NoticeLedger(ledgerRoot);
        ledger.Add("j",win32.Message);ledger=new NoticeLedger(ledgerRoot);
        check(ledger.Entries.Count==0,"Old network-only popup survived startup");
        var mixed=new BackupResult();mixed.Errors.Add(new("j","test","a.txt","transient",0,0,"","",AutomaticNetworkRetry:true));
        check(ledger.Apply("j",mixed)==0 && ledger.Entries.Count==0,"Network failure raised a decision notice");
        mixed.Conflicts.Add(new("j","test","b.txt","newer backup",0,0,"",""));
        check(ledger.Apply("j",mixed)==1 && ledger.Entries.Single().Kind=="Conflict","Network filtering hid a real conflict");

        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        foreach(var mode in new[]{"OneWay","TwoWay"})
        foreach(var scenario in new[]{"once","persistent","stop","permanent","timeout"})
            await Scenario(provider,mode,scenario);
        await OuterFailure();

        async Task Scenario(string provider,string mode,string scenario)
        {
            string label=provider+"/"+mode+"/"+scenario;
            var home=Path.Combine(root,"network-"+provider+"-"+mode+"-"+scenario);var source=Path.Combine(home,"source");Directory.CreateDirectory(source);
            File.WriteAllText(Path.Combine(source,"a.txt"),"retry this original");File.WriteAllText(Path.Combine(source,"z.txt"),"unrelated file");
            var remote=new MemoryRemote(provider);int attempts=0,started=0;bool ordered=true;
            File.WriteAllText(Path.Combine(source,"c-conflict.txt"),"older source");File.SetLastWriteTimeUtc(Path.Combine(source,"c-conflict.txt"),DateTime.UtcNow.AddDays(-2));
            await remote.SeedAsync("c-conflict.txt","newer backup preserved",DateTime.UtcNow.AddDays(-1));
            remote.BeforeUpload=()=>
            {
                int attempt=Interlocked.Increment(ref attempts);
                if(scenario=="persistent" || attempt==1)
                {
                    if(scenario=="permanent")throw new CloudApiException(HttpStatusCode.Forbidden,"test upload");
                    if(scenario=="timeout")throw new TaskCanceledException("HTTP timeout",new TimeoutException());
                    throw new CloudApiException(HttpStatusCode.ServiceUnavailable,"test upload");
                }
            };
            var job=new BackupJob{Source=source,DestinationType=provider,CloudAccountId=remote.AccountId,CloudFolderId=remote.Root,SyncMode=mode,TriggerType="Scheduled",ScheduleTime="23:59"};
            var data=new ConfigStore(Path.Combine(home,"data"));await using var scheduler=new BackupScheduler(data){CloudFactory=_=>remote};
            var results=new List<BackupResult>();var failures=new List<Exception>();
            scheduler.Started+=_=>{if(++started>1 && scenario!="persistent" && !remote.Files.ContainsKey("z.txt"))ordered=false;};
            scheduler.Completed+=(_,result)=>{results.Add(result);if(scenario=="stop")scheduler.StopJob(job);};
            scheduler.Failed+=(_,error)=>failures.Add(error);
            scheduler.SetJobs([job]);
            await scheduler.RunAsync(job,true).WaitAsync(TimeSpan.FromSeconds(30));
            check(failures.Count==0 && !scheduler.IsRunning(job.Id),label+" leaked a run or failed outside file diagnostics");
            bool automatic=scenario!="permanent";
            check(results.Count>0 && results[0].Errors.Any() && results[0].Errors.All(e=>NetworkFailures.Automatic(e)==automatic) && !results[0].Canceled,label+" misclassified a file error/cancel");
            check(started==(scenario is "stop" or "permanent" ? 1 : 2),label+" did not make exactly one bounded tail retry");
            if(scenario is "once" or "timeout")
            {
                check(ordered && remote.Files.ContainsKey("a.txt") && remote.Files.ContainsKey("z.txt"),label+" retry overtook normal files or did not recover");
                check(results[^1].Errors.Count==0 && data.LoadState(job).Files.Where(e=>e.RelativePath!="c-conflict.txt").All(e=>e.Status=="BackedUp"),label+" successful retry left failed snapshot entries");
                check(System.Text.Encoding.UTF8.GetString(remote.Bytes("a.txt"))=="retry this original",label+" changed file content");
                check(results[^1].Conflicts.Any(i=>i.File=="c-conflict.txt") && System.Text.Encoding.UTF8.GetString(remote.Bytes("c-conflict.txt"))=="newer backup preserved",label+" auto retry overwrote a real conflict");
            }
            if(scenario=="persistent")
            {
                check(results[^1].Errors.Count>0 && data.LoadState(job).Files.Any(e=>e.Status=="Failed"),label+" persistent failure erased retry state");
                scheduler.Start();await Task.Delay(2300);
                check(started==2,label+" immediately loops instead of backing off");
            }
            if(scenario=="stop")check(job.Stopped && started==1,label+" ignored explicit stop");
        }

        async Task OuterFailure()
        {
            var home=Path.Combine(root,"network-outer");var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);File.WriteAllText(Path.Combine(source,"a.txt"),"local");
            var job=new BackupJob{Source=source,Destination=backup};await using var scheduler=new BackupScheduler(new ConfigStore(Path.Combine(home,"data")));
            int starts=0,failures=0;bool once=false;scheduler.Started+=_=>starts++;
            scheduler.Progress+=_=>{if(!once){once=true;throw win32;}};
            scheduler.Failed+=(_,error)=>{if(NetworkFailures.IsTransient(error))failures++;};
            await scheduler.RunAsync(job,true).WaitAsync(TimeSpan.FromSeconds(20));
            check(starts==2 && failures==1 && File.ReadAllText(Path.Combine(backup,"a.txt"))=="local","Outer SMB failure was not retried safely at the end");
        }
    }
}
