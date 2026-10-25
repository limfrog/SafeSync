using System.Net;
using System.Net.Sockets;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GoogleFileAccessTests
{
    public static async Task RunAsync(Action<bool,string> check)
    {
        var account=new CloudAccount {ClientId="client",AccountId="account",RefreshTokenProtected="old-protected"};
        var pkce=CloudAuthentication.NewPkce();
        var uri=CloudAuthentication.AuthorizationUri("GoogleDrive",account,pkce.Challenge,pkce.State,pickFolder:true);
        var query=uri.Query.TrimStart('?').Split('&').Select(v=>v.Split('=',2)).ToDictionary(v=>v[0],v=>Uri.UnescapeDataString(v[1]));
        check(query["scope"]==GoogleFileAccess.Scope && query["include_granted_scopes"]=="false" && query["trigger_onepick"]=="true" && query["allow_folder_selection"]=="true","Picker requested broad or inherited scopes.");
        foreach(var invalid in new[]{"","https://www.googleapis.com/auth/drive",GoogleFileAccess.Scope+" https://www.googleapis.com/auth/drive.readonly"})
        {bool rejected=false;try{GoogleFileAccess.ValidateScope(invalid);}catch(CloudBindingException){rejected=true;}check(rejected,"Missing/broad scope was trusted.");}
        GoogleFileAccess.ValidateScope(GoogleFileAccess.Scope);
        var job=new BackupJob {DestinationType="GoogleDrive",CloudAccountId="account",CloudFolderId="existing"};
        var config=new AppConfig();var accounts=new CloudAccounts {GoogleDrive=account};accounts.Write(config);
        check(CloudJobBinding.NeedsReview(config,job),"Legacy Drive account resumed without reauthorization.");
        account.AccessMode=GoogleFileAccess.Mode;accounts.Write(config);
        check(CloudJobBinding.NeedsReview(config,job),"Old baseline resumed after changing token scopes.");
        var rebound=CloudJobBinding.Rebind(config,job,"managed","new","account","managed");
        check(rebound.Id!=job.Id && rebound.CloudAccessMode==GoogleFileAccess.Mode && rebound.SyncMode=="OneWay" && rebound.Stopped,"Scope migration reused old deletion state or started automatically.");
        rebound.SyncMode="TwoWay";
        bool blocked=false;try{GoogleFileAccess.ValidateJob(account,rebound);}catch(CloudBindingException){blocked=true;}
        check(blocked,"Per-file authorization was permitted to propagate reverse deletion.");
        using(var listener=new TcpListener(IPAddress.Loopback,0))
        using(var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10)))
        {
            listener.Start();int port=((IPEndPoint)listener.LocalEndpoint).Port;
            var pending=CloudAuthentication.ReceiveAuthorizationAsync(listener,pkce.State,timeout.Token);
            var bad=await CloudProtocolTests.Callback(port,"/?state=wrong&code=bad&picked_file_ids=outside",timeout.Token);
            check(bad.Contains("400") && !pending.IsCompleted,"Unauthenticated Picker callback was accepted.");
            await CloudProtocolTests.Callback(port,"/?state="+pkce.State+"&code=good&picked_file_ids=folder-id",timeout.Token);
            var result=await pending;check(result.Code=="good" && result.FileIds.SequenceEqual(new[]{"folder-id"}),"Authorized Picker folder ID was lost.");
        }
        foreach(bool managed in new[]{false,true})
        {
            int writes=0;
            using var client=new HttpClient(new Handler(request=>
            {
                if(request.Method!=HttpMethod.Get)writes++;
                return request.RequestUri!.AbsolutePath.EndsWith("/about") ? CloudProtocolTests.Json(new{user=new{permissionId="account"}})
                    : CloudProtocolTests.Json(new{id="folder",name="Backup",mimeType="application/vnd.google-apps.folder",trashed=false,appProperties=managed ? new Dictionary<string,string>{{GoogleFileAccess.FolderKey,GoogleFileAccess.Mode}} : new()});
            }));
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"folder","account",requireManagedRoot:true,fileAccess:true);
            bool accepted=true;try{await remote.InitializeAsync(default);}catch(CloudBindingException){accepted=false;}
            check(accepted==managed && writes==0,"Unmanaged/legacy folder gained backup authority or initialization wrote data.");
        }
        using(var client=new HttpClient(new Handler(request=>
        {
            check(request.RequestUri!.AbsolutePath.EndsWith("/about"),"Restricted account root queried inaccessible root metadata.");
            return CloudProtocolTests.Json(new{user=new{permissionId="account"}});
        })))
        {
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"root","account",fileAccess:true);
            await remote.InitializeAsync(default);check(remote.Root=="root","Restricted account root lost Drive alias.");
        }
    }
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> run):HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)=>Task.FromResult(run(request));}
}
