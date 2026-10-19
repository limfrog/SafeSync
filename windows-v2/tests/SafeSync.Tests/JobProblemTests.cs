using System.Net;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class JobProblemTests
{
    public static void Run(string root,Action<bool,string> check)
    {
        var cases=new (Exception Error,string Kind)[]
        {
            (new CloudBindingException("계정 확인 필요"),"Binding"),
            (new CloudApiException(HttpStatusCode.Unauthorized,"request"),"Authentication"),
            (new CloudApiException(HttpStatusCode.Forbidden,"request"),"Access"),
            (new CloudApiException(HttpStatusCode.TooManyRequests,"request"),"Network"),
            (new CloudApiException(HttpStatusCode.ServiceUnavailable,"request"),"Network"),
            (new HttpRequestException("offline"),"Network"),
            (new DirectoryNotFoundException("missing"),"Missing"),
            (new UnauthorizedAccessException("denied"),"Access"),
            (new IOException("full",unchecked((int)0x80070070)),"Storage"),
            (new IOException("클라우드에 중복 이름이 있습니다: Music/._Melody.zip"),"Duplicate"),
            (new CloudDuplicateNameException("dup.txt"),"Duplicate"),
            (new IOException("unknown failure"),"Other")
        };
        foreach(var (error,kind) in cases)
        {
            var problem=JobProblem.From(error,true);
            check(problem.Kind==kind && problem.Message==error.Message && problem.Guidance.Length>30 && problem.Title.Length>5,"Failure category did not provide a useful recovery path: "+kind);
        }
        var local=JobProblem.Classify("동기화 루트 폴더의 식별 정보가 변경되었습니다.",false);
        check(local.Guidance.Contains("작업 설정") && !local.Guidance.Contains("클라우드 위치 다시 연결"),"Local failure suggested a cloud-only action.");
        var conflict=JobProblem.Classify("different contents",true,"Conflict","file.txt");
        check(conflict.Kind=="Conflict" && conflict.File=="file.txt" && conflict.Guidance.Contains("충돌 처리 보기"),"Conflict recovery lost its file/action.");
        var home=Path.Combine(root,"problem-diagnostics");var store=new JobProblemStore(home);
        store.Set("job",conflict);var ledger=new NoticeLedger(home);ledger.Add("job","problem");ledger.Dismiss(ledger.Entries.ToArray());
        check(new JobProblemStore(home).Get("job")==conflict && new NoticeLedger(home).Entries.Count==0,"Clearing notices erased recovery diagnostics.");
        store.Set("other",JobProblem.From(new HttpRequestException("offline"),true));store.Set("job",null);
        check(new JobProblemStore(home).Get("job")==null && new JobProblemStore(home).Get("other")!=null,"Successful recovery did not clear only its own diagnostic.");
    }
}
