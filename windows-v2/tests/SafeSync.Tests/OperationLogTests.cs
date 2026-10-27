using System.Text.Json;
using SafeSync.Core;

internal static class OperationLogTests
{
    public static async Task RunAsync(string testRoot,Action<bool,string> check)
    {
        var root=Path.Combine(testRoot,"operation-log");Directory.CreateDirectory(root);
        var source=Path.Combine(root,"private-source");var target=Path.Combine(root,"target");Directory.CreateDirectory(source);Directory.CreateDirectory(target);
        var file=Path.Combine(source,"private-customer-name.txt");File.WriteAllText(file,"secret-content-not-for-logs");
        var job=new BackupJob{Name="private-job",Source=source,Destination=target};
        var store=new ConfigStore(Path.Combine(root,"data"));var engine=new BackupEngine(store);
        using(var log=OperationLog.Start(store.Root,"test-version"))
        {
            var first=await engine.RunAsync(job,true,[],new(),null,default);
            check(first.Copied==1 && first.Errors.Count==0,"Diagnostics changed the first backup.");
            var next=await engine.RunAsync(job,false,[],new(),null,default);
            check(next.Copied==0 && next.Errors.Count==0,"Diagnostics recopied an unchanged file.");
            using(var run=OperationLog.Begin(job,false,false))
            {
                OperationLog.Event("file.error","test",file,error:new IOException("Bearer do-not-log-token https://secret/session",new TimeoutException("do-not-log-inner")));
                OperationLog.Http(OperationLog.Endpoint(new Uri("https://www.googleapis.com/upload/drive/v3/files/secret-session?upload_id=secret")),System.Diagnostics.Stopwatch.GetTimestamp(),8388608,308,1);
                await Task.WhenAll(Enumerable.Range(0,20).Select(i=>Task.Run(()=>OperationLog.Event("parallel","test",file))));
                OperationLog.Event("same.relative","test","private-customer-name.txt");
            }
            await log.FlushAsync();
        }
        var logFolder=Path.Combine(store.Root,"logs","operations");
        var text=string.Join('\n',Directory.GetFiles(logFolder,"Diagnostic-*.jsonl").Select(File.ReadAllText));
        var summary=string.Join('\n',Directory.GetFiles(logFolder,"Summary-*.jsonl").Select(File.ReadAllText));
        check(summary.Contains("prepare.ready") && summary.Contains("prepare.phase"),"Initial preparation summary was not preserved.");
        foreach(var secret in new[]{source,"private-customer-name","private-job","secret-content","do-not-log","https://","upload_id","secret-session"})check(!text.Contains(secret),"Private data in diagnostic log.");
        var rows=text.Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(line=>JsonDocument.Parse(line)).ToArray();
        check(rows.Any(r=>r.RootElement.GetProperty("Event").GetString()=="run.start"),"Missing run start.");
        check(rows.Count(r=>r.RootElement.GetProperty("Event").GetString()=="run.end")==3,"Missing run end or context leak.");
        foreach(var operation in new[]{"prepare.source_scan","prepare.offline_journal","prepare.state_load"})check(rows.Any(r=>r.RootElement.GetProperty("Operation").GetString()==operation),"Missing preparation timing: "+operation);
        var parallel=rows.Where(r=>r.RootElement.GetProperty("Event").GetString()=="parallel").Select(r=>r.RootElement).ToArray();
        check(parallel.Length==20 && parallel.Select(r=>r.GetProperty("Run").GetString()).Distinct().Count()==1,"Lost parallel run context.");
        check(parallel.Select(r=>r.GetProperty("File").GetString()).Distinct().Count()==1,"Unstable file references.");
        check(rows.Single(r=>r.RootElement.GetProperty("Event").GetString()=="same.relative").RootElement.GetProperty("File").GetString()==parallel[0].GetProperty("File").GetString(),"Absolute and relative file phases lost correlation.");
        check(rows.Where(r=>r.RootElement.TryGetProperty("Ms",out var ms) && ms.ValueKind==JsonValueKind.Number).All(r=>r.RootElement.GetProperty("Ms").GetDouble()>=0),"Negative timing.");
        foreach(var row in rows)row.Dispose();
        var rotation=Path.Combine(root,"rotation");var folder=Path.Combine(rotation,"logs","operations");Directory.CreateDirectory(folder);
        for(int i=0;i<12;i++){var p=Path.Combine(folder,$"Diagnostic-old-{i}.jsonl");File.WriteAllText(p,"old");File.SetLastWriteTimeUtc(p,DateTime.UtcNow.AddDays(-20));}
        using(var log=OperationLog.Start(rotation,"rotation-test"))
        {
            for(int i=0;i<6000;i++){OperationLog.Event("volume","test",detail:new string('x',2000));if(i%200==0)await log.FlushAsync();}
            await log.FlushAsync();
        }
        var rotated=Directory.GetFiles(folder,"*.jsonl");
        check(rotated.Length is >=2 and <=OperationLog.FileCount,"Diagnostic rotation failed.");
        check(rotated.All(p=>new FileInfo(p).Length<=OperationLog.FileLimit),"Log exceeded file cap.");
        check(!Directory.GetFiles(folder,"Diagnostic-old-*").Any(),"Expired logs retained.");
        var broken=Path.Combine(root,"broken");Directory.CreateDirectory(broken);File.WriteAllText(Path.Combine(broken,"logs"),"not a directory");
        using(var log=OperationLog.Start(broken,"broken-test"))
        {
            var result=await engine.RunAsync(job,false,[],new(),null,default);await log.FlushAsync();
            check(result.Errors.Count==0,"Log write error escaped into backup.");
        }
    }
}
