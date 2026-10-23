using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private void ShowCloudAccounts()
    {
        var window=NewDialog("CloudAccounts");
        window.Height=Math.Min(window.Height,SystemParameters.WorkArea.Height);window.Width=Math.Min(window.Width,SystemParameters.WorkArea.Width);
        var accounts=CloudAccounts.Read(config);var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);bool busy=false;
        window.Find<TextBox>("DropboxKey").Text=accounts.Dropbox.AppKey;
        window.Find<TextBox>("GoogleClientId").Text=accounts.GoogleDrive.ClientId;
        void Refresh()
        {
            foreach(var provider in new[]{"Dropbox","GoogleDrive"})
            {
                var account=accounts.For(provider);var status=window.Find<TextBlock>(provider=="Dropbox" ? "DropboxStatus" : "GoogleStatus");
                status.Text=account.RefreshTokenProtected.Length==0 ? "연결되지 않음" : "연결됨: "+account.AccountName;
                window.Find<Button>(provider=="Dropbox" ? "DropboxValidate" : "GoogleValidate").IsEnabled=!busy && account.RefreshTokenProtected.Length>0 && account.AccountId.Length>0;
            }
        }
        void SetBusy(bool value)
        {
            busy=value;
            foreach(var name in new[]{"DropboxConnect","DropboxValidate","DropboxDisconnect","GoogleConnect","GoogleValidate","GoogleDisconnect","SaveCredentials"})window.Find<Button>(name).IsEnabled=!busy;
            foreach(var name in new[]{"DropboxKey","GoogleClientId"})window.Find<TextBox>(name).IsEnabled=!busy;
            window.Find<PasswordBox>("GoogleSecret").IsEnabled=!busy;
        }
        async Task ValidateAsync(string provider)
        {
            if(busy)return;
            var account=accounts.For(provider);
            if(account.RefreshTokenProtected.Length==0 || account.AccountId.Length==0){window.Find<TextBlock>(provider=="Dropbox" ? "DropboxStatus" : "GoogleStatus").Text="먼저 계정을 연결하세요.";return;}
            var panel=window.Find<Border>("ValidationPanel");var title=window.Find<TextBlock>("ValidationTitle");var result=window.Find<TextBlock>("ValidationResult");var bar=window.Find<ProgressBar>("ValidationProgress");
            panel.Visibility=Visibility.Visible;title.Text=(provider=="GoogleDrive" ? "Google Drive" : "Dropbox")+" 연결 검증 중";result.Text="계정과 클라우드 루트를 확인하는 중…";bar.IsIndeterminate=true;bar.Visibility=Visibility.Visible;
            try
            {
                SetBusy(true);
                var root=cloud.ForAccountRoot(provider);await root.InitializeAsync(lifetime.Token);
                var folderName="SafeSync-test-"+Guid.NewGuid().ToString("N");result.Text="전용 시험 폴더를 만드는 중…";
                await root.EnsureFolderAsync(folderName,lifetime.Token);
                var folder=await root.StatAsync(folderName,lifetime.Token) ?? throw new IOException("검증 폴더를 다시 확인할 수 없습니다.");
                if(!folder.Folder)throw new IOException("검증 위치가 폴더가 아닙니다.");
                var selectedRoot=provider=="GoogleDrive" ? folder.Id : "/"+folderName;
                var selected=cloud.ForSelectedRoot(provider,selectedRoot,folder.Id);
                var progress=new Progress<BackupProgress>(value=>result.Text=string.IsNullOrWhiteSpace(value.CurrentFile) ? value.Stage : value.Stage+" · "+value.CurrentFile);
                var report=await CloudConnectionDiagnostics.RunAsync(selected,progress,lifetime.Token);
                title.Text=(provider=="GoogleDrive" ? "Google Drive" : "Dropbox")+" 연결 검증 완료";result.Text=report+". 클라우드의 ‘"+folderName+"’ 폴더에 검증 파일을 남겼습니다.";Log(report);
            }
            catch(OperationCanceledException){title.Text="연결 검증 취소";result.Text="연결 검증을 취소했습니다.";}
            catch(Exception ex){title.Text="연결 검증 실패";result.Text=ex.Message;Log((provider=="GoogleDrive" ? "Google Drive" : "Dropbox")+" 연결 검증 실패: "+ex.Message);}
            finally{bar.IsIndeterminate=false;bar.Visibility=Visibility.Collapsed;SetBusy(false);Refresh();}
        }
        bool SaveInputs()
        {
            if(scheduler.RunningCount>0){Tell("진행 중인 백업이 끝난 뒤 계정 설정을 변경하세요.");return false;}
            var appKey=PublicCloudRegistration.ResolveDropboxAppKey(window.Find<TextBox>("DropboxKey").Text);var clientId=window.Find<TextBox>("GoogleClientId").Text.Trim();
            if(appKey.Length>1024 || clientId.Length>1024)throw new InvalidDataException("클라이언트 ID/키가 너무 깁니다.");
            if(accounts.Dropbox.AppKey!=appKey){accounts.Dropbox.RefreshTokenProtected="";accounts.Dropbox.AccountId="";accounts.Dropbox.AccountName="";}
            if(accounts.GoogleDrive.ClientId!=clientId){accounts.GoogleDrive.RefreshTokenProtected="";accounts.GoogleDrive.AccountId="";accounts.GoogleDrive.AccountName="";accounts.GoogleDrive.ClientSecretProtected="";}
            accounts.Dropbox.AppKey=appKey;accounts.GoogleDrive.ClientId=clientId;
            window.Find<TextBox>("DropboxKey").Text=appKey;
            var secret=window.Find<PasswordBox>("GoogleSecret");
            if(secret.Password.Length>0){accounts.GoogleDrive.ClientSecretProtected=cloud.Vault.Protect(secret.Password);secret.Clear();}
            accounts.Write(config);store.Save(config);Refresh();return true;
        }
        async Task ConnectAsync(string provider)
        {
            if(busy)return;
            try
            {
                if(!SaveInputs())return;SetBusy(true);
                window.Find<TextBlock>(provider=="Dropbox" ? "DropboxStatus" : "GoogleStatus").Text="시스템 브라우저에서 로그인 중…";
                await cloud.Authentication.ConnectAsync(provider,accounts.For(provider),lifetime.Token);
                accounts.Write(config);store.Save(config);Refresh();Log(provider+" 계정 연결 완료");
            }
            catch(OperationCanceledException){Refresh();}
            catch(Exception ex){window.Find<TextBlock>(provider=="Dropbox" ? "DropboxStatus" : "GoogleStatus").Text="연결 실패: "+ex.Message;}
            finally{SetBusy(false);}
        }
        void Disconnect(string provider)
        {
            if(busy || scheduler.RunningCount>0){Tell("백업이 끝난 뒤 계정을 해제하세요.");return;}
            var account=accounts.For(provider);account.RefreshTokenProtected="";account.AccountName="";account.AccountId="";
            try{accounts.Write(config);store.Save(config);Refresh();}catch(Exception ex){Tell(ex.Message);}
        }
        Click(window,"DropboxConnect",()=>TrackAuxiliary(ConnectAsync("Dropbox")));Click(window,"GoogleConnect",()=>TrackAuxiliary(ConnectAsync("GoogleDrive")));
        Click(window,"DropboxValidate",()=>TrackAuxiliary(ValidateAsync("Dropbox")));Click(window,"GoogleValidate",()=>TrackAuxiliary(ValidateAsync("GoogleDrive")));
        Click(window,"DropboxDisconnect",()=>Disconnect("Dropbox"));Click(window,"GoogleDisconnect",()=>Disconnect("GoogleDrive"));
        Click(window,"SaveCredentials",()=>{try{if(SaveInputs())Log("클라우드 입력값을 암호화 저장했습니다.");}catch(Exception ex){Tell(ex.Message);}});
        Click(window,"CloseButton",window.Close);window.Closed+=(_,_)=>lifetime.Cancel();Refresh();window.ShowDialog();
    }
    private CloudFolderChoice? ChooseCloudFolder(string provider,Window owner)
    {
        IRemoteStore remote;
        try{remote=cloud.ForAccountRoot(provider);}catch(Exception ex){Tell(ex.Message);return null;}
        var account=CloudAccounts.Read(config).For(provider);var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);
        var picker=new CloudFolderPicker(remote,account.AccountName,config.ThemeMode,owner,lifetime,TrackAuxiliary);
        auxiliary.Add(picker.Window);picker.Window.Closed+=(_,_)=>auxiliary.Remove(picker.Window);
        return picker.Window.ShowDialog()==true ? picker.Choice : null;
    }
}
