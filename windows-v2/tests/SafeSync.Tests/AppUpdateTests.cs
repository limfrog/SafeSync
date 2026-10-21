using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core;

internal static class AppUpdateTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var pair in new[]{("1.0.0-preview.10","1.0.0-preview.9"),("1.0.0","1.0.0-preview.100"),("1.2.0","1.1.99"),("2.0.0","1.99.99"),("0.3.10","0.3.9")})
            check(new AppUpdateVersion(pair.Item1).IsNewerThan(pair.Item2),"Semantic update order is incorrect.");
        check(!new AppUpdateVersion("1.1.0-preview.1").IsNewerThan("1.0.0"),"Stable users offered an unsolicited preview.");
        check(new AppUpdateVersion("v1.0.0+build.2").CompareTo(new("1.0.0+build.9"))==0,"Build metadata changes release precedence.");
        foreach(var bad in new[]{"../1.0.0","1.0","1.00.0","1.0.0-preview.01","1.0.0/evil","1.0.0\n","99999999999.0.0"})
        {
            bool rejected=false;try{_ = new AppUpdateVersion(bad);}catch(InvalidDataException){rejected=true;}
            check(rejected,"Invalid update version accepted: "+bad);
        }
        byte[] payload=Encoding.UTF8.GetBytes("synthetic update installer");
        var release=new AppUpdateRelease("1.0.0-preview.99","https://raw.githubusercontent.com/limfrog/SafeSync/main/dist/SafeSync-Setup-1.0.0-preview.99.exe",Convert.ToHexStringLower(SHA256.HashData(payload)),payload.Length,"합성 업데이트 검사");
        foreach(var bad in new[]{release with{Url="https://evil.test/installer.exe"},release with{Url=release.Url+"?other=1"},release with{Url=release.Url.Replace("https:","http:")},release with{Url=release.Url.Replace("limfrog/","other/")},release with{Sha256="invalid"},release with{Size=0},release with{Version="../bad"}})
        {
            bool rejected=false;try{AppUpdateClient.Validate(bad,"windows-x64");}catch(InvalidDataException){rejected=true;}
            check(rejected,"Unsafe release metadata accepted.");
        }
        var home=Path.Combine(root,"app-update-tests");Directory.CreateDirectory(home);
        var requests=new List<string>();
        using var client=new AppUpdateClient(new Handler((request,_)=>
        {
            requests.Add(request.RequestUri!.AbsoluteUri);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=request.RequestUri==AppUpdateClient.FeedUri
                ? new StringContent(JsonSerializer.Serialize(new AppUpdateFeed{SchemaVersion=1,Windows=release},JsonFile.Options))
                : new ByteArrayContent(payload)});
        }));
        check((await client.CheckAsync("1.0.0-preview.12","windows-x64",default))?.Version==release.Version,"New update was not detected.");
        check(await client.CheckAsync(release.Version,"windows-x64",default)==null,"Same version caused repeated update.");
        var file=await client.DownloadAsync(release,"windows-x64",home,null,default);
        check(File.ReadAllBytes(file).SequenceEqual(payload),"Downloaded update differs from expected payload.");
        int before=requests.Count;await client.DownloadAsync(release,"windows-x64",home,null,default);
        check(requests.Count==before,"Verified cached download repeated.");
        File.WriteAllText(file,"tampered");
        await client.DownloadAsync(release,"windows-x64",home,null,default);
        check(requests.Count==before+1 && await AppUpdateClient.VerifyAsync(file,release,default),"Tampered cache was trusted.");
        using var corrupt=new AppUpdateClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(new byte[payload.Length])})));
        var rejectedHome=Path.Combine(home,"rejected");bool checksum=false;
        try{await corrupt.DownloadAsync(release,"windows-x64",rejectedHome,null,default);}catch(InvalidDataException){checksum=true;}
        check(checksum && !Directory.EnumerateFiles(rejectedHome).Any(),"Corrupt update became an installable file or left a partial.");
        using var interrupted=new AppUpdateClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StreamContent(new BrokenReadStream())})));
        bool interruptedSafely=false;
        try{await interrupted.DownloadAsync(release,"windows-x64",rejectedHome,null,default);}catch(IOException){interruptedSafely=true;}
        check(interruptedSafely && !Directory.EnumerateFiles(rejectedHome).Any(),"Interrupted transfer left an installable update.");
        using var redirected=new AppUpdateClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect){Headers={Location=new("https://evil.test/installer.exe")}})));
        bool redirect=false;try{await redirected.CheckAsync("1.0.0-preview.1","windows-x64",default);}catch(HttpRequestException){redirect=true;}
        check(redirect,"Unexpected redirect was accepted.");
        using var large=new AppUpdateClient(new Handler((_,_)=>Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(new string('x',65537))})));
        bool oversized=false;try{await large.CheckAsync("1.0.0-preview.1","windows-x64",default);}catch(InvalidDataException){oversized=true;}
        check(oversized,"Oversized update feed was accepted.");
        using var cancel=new CancellationTokenSource();cancel.Cancel();bool canceled=false;
        try{await client.DownloadAsync(release,"windows-x64",Path.Combine(home,"canceled"),null,cancel.Token);}catch(OperationCanceledException){canceled=true;}
        check(canceled && !Directory.EnumerateFiles(Path.Combine(home,"canceled")).Any(),"Canceled update left partial data.");
        var defaults=JsonSerializer.Deserialize<AppConfig>("{}",JsonFile.Options)!;
        check(defaults.AutomaticallyCheckUpdates && defaults.AutomaticallyDownloadUpdates,"Existing users did not receive update defaults.");
        defaults.AutomaticallyCheckUpdates=false;defaults.AutomaticallyDownloadUpdates=false;
        var roundtrip=JsonSerializer.Deserialize<AppConfig>(JsonSerializer.Serialize(defaults,JsonFile.Options),JsonFile.Options)!;
        check(!roundtrip.AutomaticallyCheckUpdates && !roundtrip.AutomaticallyDownloadUpdates,"Disabled update preferences were not preserved.");
        await HoldAsync(home,check);
    }
    private static async Task HoldAsync(string root,Action<bool,string> check)
    {
        var source=Path.Combine(root,"hold-source");var backup=Path.Combine(root,"hold-backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
        File.WriteAllText(Path.Combine(source,"a.txt"),"finish current file");File.WriteAllText(Path.Combine(source,"b.txt"),"pending file");
        var job=new BackupJob{Source=source,Destination=backup};var store=new ConfigStore(Path.Combine(root,"hold-state"));
        await using var scheduler=new BackupScheduler(store);scheduler.SetJobs([job]);
        using var release=new ManualResetEventSlim();var reached=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        scheduler.Progress+=p=>{if(p.CurrentFile=="a.txt" && p.Stage=="파일 비교 및 백업" && !reached.Task.IsCompleted){reached.SetResult();release.Wait(TimeSpan.FromSeconds(15));}};
        var running=scheduler.RunAsync(job,true);
        try
        {
            await reached.Task.WaitAsync(TimeSpan.FromSeconds(10));
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var holding=scheduler.HoldForUpdateAsync(timeout.Token);
            check(!holding.IsCompleted,"Update hold did not wait for active file.");release.Set();
            using(await holding)
            {
                await running;
                check(File.Exists(Path.Combine(backup,"a.txt")) && !File.Exists(Path.Combine(backup,"b.txt")),"Update hold cut a file short or copied the next file.");
                check(!job.Stopped && !job.Paused,"Update altered persistent job flags.");
                check(store.LoadState(job).PendingPaths.Contains("b.txt"),"Update hold lost pending backup work.");
                await scheduler.RunAsync(job);
                check(!File.Exists(Path.Combine(backup,"b.txt")),"Update hold allowed a new backup to launch.");
            }
            await scheduler.RunAsync(job);
            check(File.Exists(Path.Combine(backup,"b.txt")),"Canceled/finished update hold did not restore backup execution.");
        }
        finally{release.Set();}
    }
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> reply):HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){token.ThrowIfCancellationRequested();return reply(request,token);}
    }
    private sealed class BrokenReadStream:Stream
    {
        private bool read;
        public override bool CanRead=>true;public override bool CanSeek=>false;public override bool CanWrite=>false;
        public override long Length=>throw new NotSupportedException();public override long Position{get=>0;set=>throw new NotSupportedException();}
        public override int Read(byte[] buffer,int offset,int count){if(read)throw new IOException("Simulated network interruption");read=true;buffer[offset]=1;return 1;}
        public override ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken token=default){byte[] bytes=new byte[1];int count=Read(bytes,0,1);bytes.AsMemory(0,count).CopyTo(buffer);return ValueTask.FromResult(count);}
        public override void Flush()=>throw new NotSupportedException();public override long Seek(long offset,SeekOrigin origin)=>throw new NotSupportedException();
        public override void SetLength(long value)=>throw new NotSupportedException();public override void Write(byte[] buffer,int offset,int count)=>throw new NotSupportedException();
    }
}
