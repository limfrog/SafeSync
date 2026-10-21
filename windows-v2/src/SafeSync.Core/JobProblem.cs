using System.Text.Json;
using SafeSync.Core.Cloud;

namespace SafeSync.Core;

public sealed record JobProblem(string Kind,string Title,string Message,string Guidance,string File="")
{
    public static JobProblem From(Exception error,bool cloud)=>Classify(error.Message,cloud,error is CloudBindingException ? "Binding" : error is CloudApiException api ? ((int)api.Status).ToString() : NetworkFailures.IsTransient(error) ? "Network" : error is DirectoryNotFoundException ? "Missing" : error is UnauthorizedAccessException ? "Access" : error is IOException io && (io.HResult&0xffff) is 39 or 112 ? "Storage" : "");
    public static JobProblem Classify(string message,bool cloud,string code="",string file="")
    {
        string kind,title,guide;
        if(code.Length==0 && NetworkFailures.LegacyMessage(message))code="Network";
        if((message.Contains("중복") && message.Contains("이름")) || message.Contains("같은 이름의 항목"))
        {kind="Duplicate";title="클라우드에 이름이 같은 항목이 있습니다";guide="동기화 상태 → 문제 해결에서 파일을 선택하세요. 내용까지 같은 사본들은 자동으로 통과합니다. 다른 사본은 ID·크기·날짜를 확인한 뒤 덮어쓰기 방향 또는 ‘중복 이름만 정리’를 선택할 수 있습니다. 추가 사본은 .SafeSync-conflict- 이름으로 보존하며, 폴더는 내부 파일 전체가 해당 이름 아래 남습니다. 다른 파일의 백업은 계속됩니다.";}
        else if(code=="Binding" || message.Contains("계정과 현재") || message.Contains("계정이 다릅니다") || message.Contains("식별 정보가 변경"))
        {kind="Binding";title="계정 또는 백업 위치 확인이 필요합니다";guide="‘클라우드 위치 다시 연결’에서 현재 계정과 사용할 폴더를 확인하세요. 새 위치에는 이전 삭제 판단이나 충돌 처리 결정을 재사용하지 않습니다. 연결 후 ‘이 작업 다시 시도’를 눌러 진행합니다.";}
        else if(code=="401" || message.Contains("invalid_grant",StringComparison.OrdinalIgnoreCase))
        {kind="Authentication";title="클라우드 로그인 확인이 필요합니다";guide="‘계정 연결’에서 다시 로그인한 뒤 ‘이 작업 다시 시도’를 누르세요. 로그인 계정이 달라졌다면 사용할 백업 폴더도 다시 확인해야 합니다.";}
        else if(code is "403" or "Access")
        {kind="Access";title="파일 또는 폴더 접근이 거부되었습니다";guide="선택한 계정에 폴더 접근 권한이 있는지, 로컬/NAS 폴더가 쓰기 가능한지 확인하세요. 필요하면 계정 연결 또는 작업 설정을 확인한 뒤 다시 시도하세요. 이 화면은 접근 권한을 자동으로 변경하지 않습니다.";}
        else if(code=="429")
        {kind="Network";title="클라우드 요청 제한으로 잠시 기다려야 합니다";guide="서비스의 요청 제한이 해제될 때까지 잠시 기다린 뒤 다시 시도하세요. ‘일단 대기’를 선택하면 반복 실행을 멈추고 나중에 직접 시작할 수 있습니다.";}
        else if(code=="Network" || code is "408" or "500" or "502" or "503" or "504")
        {kind="Network";title="일시적인 네트워크 오류 · 자동 재시도";guide="파일별 덮어쓰기 방법을 선택할 필요가 없습니다. 현재 동기화가 끝난 뒤 한 번 자동 재시도하고, 계속 실패하면 간격을 늘려 재시도합니다. 오류 목록에는 당시 기록을 남깁니다. 네트워크가 오래 끊겼다면 연결 상태를 확인하세요. ‘일단 대기’는 자동 실행을 멈춥니다.";}
        else if(code=="Missing" || message.Contains("폴더에 접근할 수 없") || message.Contains("폴더가 없습니다"))
        {kind="Missing";title="원본 또는 백업 폴더를 찾을 수 없습니다";guide="드라이브·NAS가 연결되어 있는지, 폴더가 이동·삭제되었는지 확인하세요. 위치가 바뀌었다면 작업 설정 또는 클라우드 위치 다시 연결을 사용하세요. 연결 실패를 파일 삭제로 처리하지 않습니다.";}
        else if(code=="Storage")
        {kind="Storage";title="저장 공간을 확인하세요";guide="원본 임시 사본 저장 위치와 백업 위치의 여유 공간을 확인한 뒤 다시 시도하세요. SafeSync는 공간 확보를 위해 기존 백업 파일을 임의로 삭제하지 않습니다.";}
        else if(code=="Conflict")
        {kind="Conflict";title="처리 방법을 선택해야 하는 파일이 있습니다";guide="‘충돌 처리 보기’에서 원본/백업 정보와 파일별 처리 방법을 확인하세요. 다른 파일의 백업은 계속 진행됩니다.";}
        else
        {kind="Other";title="작업을 완료하지 못했습니다";guide="아래 오류 원문과 작업 위치를 확인하세요. 문제가 해결되었다면 ‘이 작업 다시 시도’를, 위치가 잘못되었다면 작업 설정을 선택하세요. ‘일단 대기’는 반복 실행만 중단하며 파일이나 스냅샷을 삭제하지 않습니다.";}
        if(!cloud && kind=="Binding")guide="원본·백업 폴더가 교체되거나 이동했는지 확인한 뒤 작업 설정에서 다시 선택하세요. 이전 삭제 기준은 변경된 위치에 재사용하지 않습니다.";
        return new(kind,title,message,guide,file);
    }
}

// Diagnostic state only. Clearing a notice must not erase recovery options.
public sealed class JobProblemStore
{
    private readonly string path;
    private readonly Dictionary<string,JobProblem> problems;
    public JobProblemStore(string root)
    {
        path=Path.Combine(root,"job-problems-v2.json");
        try{problems=File.Exists(path) ? JsonFile.Read<Dictionary<string,JobProblem>>(path) : new();}
        catch(Exception ex) when(ex is IOException or JsonException){problems=new();}
    }
    public JobProblem? Get(string id)=>problems.GetValueOrDefault(id);
    public void Set(string id,JobProblem? problem)
    {if(problem==null)problems.Remove(id);else problems[id]=problem;JsonFile.Save(path,problems);}
}
