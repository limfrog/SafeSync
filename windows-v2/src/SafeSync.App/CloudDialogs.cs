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
            }
        }
        void SetBusy(bool value)
        {
            busy=value;
            foreach(var name in new[]{"DropboxConnect","DropboxDisconnect","GoogleConnect","GoogleDisconnect","SaveCredentials"})window.Find<Button>(name).IsEnabled=!busy;
            foreach(var name in new[]{"DropboxKey","GoogleClientId"})window.Find<TextBox>(name).IsEnabled=!busy;
            window.Find<PasswordBox>("GoogleSecret").IsEnabled=!busy;
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
