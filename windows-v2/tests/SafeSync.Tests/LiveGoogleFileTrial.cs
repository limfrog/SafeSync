using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class LiveGoogleFileTrial
{
    // Copies client registration only. Existing refresh tokens, jobs, snapshots
    // and configuration are never modified by this opt-in real-account test.
    public static async Task RunAsync(string root,string existingConfig,bool picker)
    {
        var vault=new WindowsSecretVault();var registration=CloudAccounts.Read(JsonFile.Read<AppConfig>(existingConfig)).GoogleDrive;
        var account=new CloudAccount {ClientId=registration.ClientId,ClientSecretProtected=registration.ClientSecretProtected};
        var accounts=new CloudAccounts {GoogleDrive=account};var config=new AppConfig();accounts.Write(config);
        var state=new ConfigStore(Path.Combine(root,"drive-file-trial-state"));
        using var services=new CloudServices(()=>config,vault:vault);
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(10));var token=timeout.Token;
        Console.WriteLine(picker ? "브라우저에서 Google 로그인 후 시험 폴더를 만들 상위 폴더를 선택하세요." : "브라우저에서 Google 제한 권한 연결을 승인하세요.");
        var ids=await services.Authentication.ConnectAsync("GoogleDrive",account,token,pickFolder:picker);
        accounts.Write(config);state.Save(config);
        var parent=picker ? services.ForSelectedRoot("GoogleDrive",ids.Single()) : services.ForAccountRoot("GoogleDrive");
        await parent.InitializeAsync(token);
        var folderName="SafeSync-test-"+Guid.NewGuid().ToString("N");
        Exception? failure=null;bool cleaned=false;
        try
        {
            await parent.EnsureFolderAsync(folderName,token);
            var folder=await parent.StatAsync(folderName,token) ?? throw new IOException("시험 폴더를 확인할 수 없습니다.");
            var selected=services.ForSelectedRoot("GoogleDrive",folder.Id,folder.Id);
            Console.WriteLine(await CloudConnectionDiagnostics.RunAsync(selected,new Progress<BackupProgress>(p=>Console.WriteLine(p.Stage)),token));
            // A new services instance must refresh the new narrow token and
            // reopen the same managed root without touching the old account.
            using var restarted=new CloudServices(()=>config,vault:vault);
            await restarted.ForSelectedRoot("GoogleDrive",folder.Id,folder.Id).InitializeAsync(token);
            Console.WriteLine("PASS: drive.file authorization, managed folder, backup/skip/replace/trash/restore and restarted connection.");
        }
        catch(Exception ex){failure=ex;throw;}
        finally
        {
            try
            {
                using var cleanup=new CancellationTokenSource(TimeSpan.FromSeconds(90));
                await parent.DeleteAsync(folderName,cleanup.Token);cleaned=true;Console.WriteLine("PASS: 이번 시험 폴더와 파일 자동 정리.");
            }
            finally
            {
                JsonFile.Save(Path.Combine(root,"drive-file-trial-result.json"),new{Status=failure==null && cleaned ? "OK" : "FAILED",Scope=GoogleFileAccess.Scope,Picker=picker,Cleanup=cleaned,Error=failure?.Message});
            }
        }
    }
}
