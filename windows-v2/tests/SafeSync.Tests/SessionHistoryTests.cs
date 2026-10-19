using SafeSync.Core;

internal static class SessionHistoryTests
{
    public static void Run(Action<bool,string> check)
    {
        var session=new SyncSessionHistory();var job=new BackupJob {Name="처음 이름",Source="source",Destination="backup",DestinationType="GoogleDrive"};
        var start=new DateTimeOffset(2026,10,19,0,0,0,TimeSpan.Zero);
        var first=session.Begin(job,start);check(first.IsActive && session.Runs.Count==1,"Session start missing");
        check(ReferenceEquals(first,session.Begin(job,start.AddSeconds(1))),"Duplicate start created duplicate history");
        session.Progress(job,new(job.Id,job.Name,"전송","file",6,12),start.AddSeconds(5));
        check(first.Percent==50 && first.DurationText=="00:00:05","Progress or duration not updated");
        session.SetPaused(job.Id,true);check(first.Outcome==SyncRunOutcome.Paused,"Pause status not retained");
        session.Tick(start.AddSeconds(7));check(first.DurationText=="00:00:07","Active elapsed time freezes without file events");
        session.SetPaused(job.Id,false);check(first.Outcome==SyncRunOutcome.Running,"Resume status not retained");
        var issue=new FileIssue(job.Id,job.Name,"file","conflict",10,11,"source-time","backup-time");
        var result=new BackupResult {Copied=3,Skipped=8,Trashed=2};result.Conflicts.Add(issue);result.Locked.Add(issue);result.Errors.Add(issue);
        session.Complete(job,result,start.AddSeconds(12));
        check(first.EndedUtc==start.AddSeconds(12) && first.DurationText=="00:00:12" && !first.IsActive,"Finished run stayed active");
        check(first.Copied==3 && first.Skipped==8 && first.Trashed==2 && first.ErrorsText=="1","Result counts lost");
        check(first.Outcome==SyncRunOutcome.Attention && first.StatusText=="오류 확인","Partial failure displayed as success");
        result.Errors.Clear();result.Copied=999;check(first.Errors.Count==1 && first.Copied==3,"History changes when result object is modified");
        job.Name="새 이름";job.Source="new-source";job.Destination="new-backup";
        var second=session.Begin(job,start.AddMinutes(1));
        check(second.RunId!=first.RunId && session.Runs.Count==2 && session.Runs[0]==second,"Repeated job overwrote previous run");
        check(first.JobName=="처음 이름" && first.Source=="source" && first.Destination=="backup","History endpoints changed with job settings");
        check(!session.IsLatest(first) && session.IsLatest(second),"Old result treated as latest");
        session.Complete(job,new BackupResult {Skipped=12},start.AddMinutes(1).AddSeconds(1));
        check(second.StatusText=="변경 없음" && first.DurationText=="00:00:12","No-change or finished time incorrect");
        session.Fail(job,new IOException("account failure"),start.AddMinutes(2));var failed=session.Runs[0];
        check(failed.Outcome==SyncRunOutcome.Failed && failed.FailureReason=="account failure" && failed.ErrorsText=="1","Failure before progress lost");
        check(failed.CopiedText=="—" && !failed.IsActive && failed.EndedUtc!=null,"Unknown partial counts shown as zero success");
        session.Complete(job,new BackupResult {Canceled=true,Copied=1},start.AddMinutes(3));
        check(session.Runs[0].Outcome==SyncRunOutcome.Canceled && session.Runs[0].Copied==1,"Canceled result lost");
        check(session.Runs.Count==4,"Session history discarded completed runs");
        check(new SyncSessionHistory().Runs.Count==0,"New session inherited old runs");
    }
}
