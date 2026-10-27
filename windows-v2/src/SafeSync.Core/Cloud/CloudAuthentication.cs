using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed class CloudAuthentication(HttpClient client,ISecretVault vault)
{
    private readonly SemaphoreSlim tokenGate=new(1,1);
    private readonly Dictionary<string,(string Fingerprint,string Token,DateTime Expires)> tokens=[];
    public const int CallbackPort=53682;
    public const string DropboxScopes="account_info.read files.metadata.read files.content.read files.content.write";
    public static string Base64Url(byte[] bytes)=>Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_');
    public static (string Verifier,string Challenge,string State) NewPkce()
    {
        var verifier=Base64Url(RandomNumberGenerator.GetBytes(48));
        return (verifier,Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))),Base64Url(RandomNumberGenerator.GetBytes(32)));
    }
    public static bool ValidState(string expected,string actual)=>CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected),Encoding.UTF8.GetBytes(actual));
    public static Uri AuthorizationUri(string provider,CloudAccount account,string challenge,string state,int port=CallbackPort,bool pickFolder=false)
    {
        var clientId=provider=="Dropbox" ? account.AppKey : account.ClientId;
        if(string.IsNullOrWhiteSpace(clientId))throw new InvalidOperationException("App Key 또는 OAuth Client ID를 입력하세요.");
        var redirect=$"http://127.0.0.1:{port}/";
        var common=new List<(string,string)> {("client_id",clientId),("response_type","code"),("redirect_uri",redirect),("state",state),("code_challenge",challenge),("code_challenge_method","S256")};
        var endpoint=provider switch
        {
            "Dropbox"=>"https://www.dropbox.com/oauth2/authorize",
            "GoogleDrive"=>"https://accounts.google.com/o/oauth2/v2/auth",
            _=>throw new ArgumentException("Unknown cloud provider.")
        };
        if(provider=="Dropbox")common.AddRange([("token_access_type","offline"),("scope",DropboxScopes)]);
        else
        {
            common.AddRange([("scope",GoogleFileAccess.Scope),("access_type","offline"),("prompt","consent"),("include_granted_scopes","false")]);
            if(pickFolder)common.AddRange([("trigger_onepick","true"),("allow_folder_selection","true"),("allow_multiple","false"),("mimetypes","application/vnd.google-apps.folder")]);
        }
        return new Uri(endpoint+"?"+CloudJson.Query(common.ToArray()));
    }
    public async Task<string[]> ConnectAsync(string provider,CloudAccount account,CancellationToken token,
        Func<Uri,Task>? launchBrowser=null,bool pickFolder=false)
    {
        var pkce=NewPkce();
        using var listener=new TcpListener(IPAddress.Loopback,CallbackPort);
        listener.Server.ExclusiveAddressUse=true;listener.Start();
        var uri=AuthorizationUri(provider,account,pkce.Challenge,pkce.State,pickFolder:pickFolder);
        if(launchBrowser!=null)await launchBrowser(uri);
        else Process.Start(new ProcessStartInfo(uri.AbsoluteUri){UseShellExecute=true});
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromMinutes(3));
        var callback=await ReceiveAuthorizationAsync(listener,pkce.State,timeout.Token);
        var code=callback.Code;
        if(pickFolder && callback.FileIds.Length!=1)throw new InvalidOperationException("Google Drive에서 상위 폴더 하나를 선택하세요.");
        var values=new Dictionary<string,string>
        {
            ["grant_type"]="authorization_code",["code"]=code,["code_verifier"]=pkce.Verifier,
            ["redirect_uri"]=$"http://127.0.0.1:{CallbackPort}/",["client_id"]=provider=="Dropbox" ? account.AppKey : account.ClientId
        };
        if(provider=="GoogleDrive" && account.ClientSecretProtected.Length>0)values["client_secret"]=vault.Unprotect(account.ClientSecretProtected);
        var response=await FormAsync(provider,values,timeout.Token);
        if(provider=="GoogleDrive")GoogleFileAccess.ValidateScope(response.String("scope"));
        var refresh=response.String("refresh_token");var access=response.String("access_token");
        if(string.IsNullOrEmpty(refresh) || string.IsNullOrEmpty(access))throw new IOException("서비스가 오프라인 연결 토큰을 반환하지 않았습니다. 다시 동의해 주세요.");
        var transport=new CloudHttp(client,(_,_)=>Task.FromResult(access));
        var profile=provider=="GoogleDrive"
            ? await transport.JsonAsync(HttpMethod.Get,"https://www.googleapis.com/drive/v3/about?fields=user",null,token)
            : await transport.JsonAsync(HttpMethod.Post,"https://api.dropboxapi.com/2/users/get_current_account",null,token);
        string name=provider=="GoogleDrive" ? profile.GetProperty("user").String("emailAddress") : profile.String("email");
        string id=provider=="GoogleDrive" ? profile.GetProperty("user").String("permissionId") : profile.String("account_id");
        if(id.Length==0)throw new IOException("클라우드 계정 ID를 확인하지 못했습니다.");
        if(pickFolder && account.AccountId.Length>0 && account.AccountId!=id)throw new CloudBindingException("폴더를 선택한 Google 계정이 연결 계정과 다릅니다. 같은 계정으로 다시 선택하세요.");
        var encrypted=vault.Protect(refresh);
        account.RefreshTokenProtected=encrypted;account.AccountName=name;account.AccountId=id;
        if(provider=="GoogleDrive")account.AccessMode=GoogleFileAccess.Mode;
        await tokenGate.WaitAsync(token);
        try{tokens.Remove(provider);}finally{tokenGate.Release();}
        return callback.FileIds;
    }
    public async Task<string> AccessAsync(string provider,CloudAccount account,bool force,CancellationToken token)
    {
        if(provider=="GoogleDrive")GoogleFileAccess.ValidateAccount(account);
        if(string.IsNullOrEmpty(account.RefreshTokenProtected))throw new InvalidOperationException("클라우드 계정을 먼저 연결하세요.");
        string fingerprint=account.RefreshTokenProtected+"|"+account.ClientId+"|"+account.AppKey+"|"+account.ClientSecretProtected;
        await tokenGate.WaitAsync(token);
        try
        {
            if(!force && tokens.TryGetValue(provider,out var cached) && cached.Fingerprint==fingerprint && cached.Expires>DateTime.UtcNow)return cached.Token;
            var form=new Dictionary<string,string> { ["grant_type"]="refresh_token",["refresh_token"]=vault.Unprotect(account.RefreshTokenProtected),["client_id"]=provider=="Dropbox" ? account.AppKey : account.ClientId };
            if(provider=="GoogleDrive" && account.ClientSecretProtected.Length>0)form["client_secret"]=vault.Unprotect(account.ClientSecretProtected);
            var response=await FormAsync(provider,form,token);var access=response.String("access_token");
            if(provider=="GoogleDrive")GoogleFileAccess.ValidateScope(response.String("scope"));
            if(access.Length==0)throw new IOException("클라우드 액세스 토큰을 받지 못했습니다.");
            var expires=response.Number("expires_in");tokens[provider]=(fingerprint,access,DateTime.UtcNow.AddSeconds(Math.Max(1,expires>120 ? expires-120 : expires>0 ? expires/2 : 60)));
            return access;
        }
        finally{tokenGate.Release();}
    }
    private async Task<JsonElement> FormAsync(string provider,Dictionary<string,string> values,CancellationToken token)
    {
        using var timing=OperationLog.Measure("prepare.oauth_token_exchange");
        var endpoint=provider=="GoogleDrive" ? "https://oauth2.googleapis.com/token" : provider=="Dropbox" ? "https://api.dropboxapi.com/oauth2/token" : throw new ArgumentException("Unknown cloud provider.");
        using var request=new HttpRequestMessage(HttpMethod.Post,endpoint){Content=new FormUrlEncodedContent(values)};
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(45));
        var started=System.Diagnostics.Stopwatch.GetTimestamp();
        using var response=await client.SendAsync(request,timeout.Token);
        OperationLog.Http("oauth.token",started,request.Content.Headers.ContentLength,(int)response.StatusCode,0);
        if(!response.IsSuccessStatusCode)throw new CloudApiException(response.StatusCode,"OAuth token exchange");
        return await CloudJson.ReadAsync(response,token);
    }
    public sealed record AuthorizationResponse(string Code,string[] FileIds);
    public static async Task<string> ReceiveCodeAsync(TcpListener listener,string expectedState,CancellationToken token)=>(await ReceiveAuthorizationAsync(listener,expectedState,token)).Code;
    public static async Task<AuthorizationResponse> ReceiveAuthorizationAsync(TcpListener listener,string expectedState,CancellationToken token)
    {
        while(true)
        {
            using var connection=await listener.AcceptTcpClientAsync(token);
            using var peerTimeout=CancellationTokenSource.CreateLinkedTokenSource(token);peerTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            await using var stream=connection.GetStream();using var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);
            string? request;
            try
            {
                var line=new StringBuilder();var character=new char[1];
                while(line.Length<=8192 && await reader.ReadAsync(character.AsMemory(),peerTimeout.Token)>0)
                {if(character[0]=='\n')break;line.Append(character[0]);}
                request=line.ToString().TrimEnd('\r');
            }
            catch(OperationCanceledException) when(!token.IsCancellationRequested){continue;}
            catch(IOException){continue;}
            bool valid=false;string code="";bool denied=false;string[] fileIds=[];
            try
            {
                if(request==null || request.Length>8192)throw new InvalidDataException();
                var parts=request.Split(' ');
                if(parts.Length!=3 || parts[0]!="GET" || !parts[1].StartsWith('/'))throw new InvalidDataException();
                var uri=new Uri("http://127.0.0.1"+parts[1]);
                if(uri.AbsolutePath!="/")throw new InvalidDataException();
                var query=new Dictionary<string,string>();
                foreach(var pair in uri.Query.TrimStart('?').Split('&',StringSplitOptions.RemoveEmptyEntries))
                {
                    var value=pair.Split('=',2);if(!query.TryAdd(Uri.UnescapeDataString(value[0]),value.Length==2 ? Uri.UnescapeDataString(value[1].Replace('+',' ')) : ""))throw new InvalidDataException();
                }
                valid=query.TryGetValue("state",out var state) && ValidState(expectedState,state);
                denied=valid && query.ContainsKey("error");query.TryGetValue("code",out var returned);code=returned ?? "";
                valid=valid && (denied || code.Length>0);
                if(valid && query.TryGetValue("picked_file_ids",out var ids))
                {
                    fileIds=ids.Split(',',StringSplitOptions.RemoveEmptyEntries);
                    valid=fileIds.Length<=100 && fileIds.All(i=>System.Text.RegularExpressions.Regex.IsMatch(i,"^[a-zA-Z0-9_-]{1,200}$"));
                }
            }
            catch(Exception ex) when(ex is InvalidDataException or UriFormatException){}
            var body=Encoding.UTF8.GetBytes(valid ? "SafeSync authorization response received. Return to the app." : "Invalid authorization callback.");
            var head=Encoding.ASCII.GetBytes($"HTTP/1.1 {(valid ? "200 OK" : "400 Bad Request")}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            try{await stream.WriteAsync(head,peerTimeout.Token);await stream.WriteAsync(body,peerTimeout.Token);}
            catch(IOException){if(!valid)continue;}
            catch(OperationCanceledException) when(!token.IsCancellationRequested){if(!valid)continue;}
            if(denied)throw new InvalidOperationException("클라우드 로그인이 취소되었습니다.");
            if(valid)return new(code,fileIds);
        }
    }
}
