namespace SafeSync.Core.Cloud;

public sealed class CloudServices : IDisposable
{
    private readonly Func<AppConfig> config;
    private readonly HttpClient client;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string,CloudRetryState> retryStates=new();
    public ISecretVault Vault {get;}
    public CloudAuthentication Authentication {get;}
    public CloudServices(Func<AppConfig> config,HttpClient? client=null,ISecretVault? vault=null)
    {
        this.config=config;this.client=client ?? new HttpClient(new HttpClientHandler{AllowAutoRedirect=false}){Timeout=TimeSpan.FromMinutes(10)};
        Vault=vault ?? new WindowsSecretVault();Authentication=new(this.client,Vault);
    }
    public IRemoteStore ForJob(BackupJob job)
    {
        var account=CloudAccounts.Read(config()).For(job.DestinationType);
        if(job.DestinationType=="GoogleDrive")GoogleFileAccess.ValidateJob(account,job);
        if(CloudJobBinding.NeedsReview(config(),job))throw new CloudBindingException("가져온 작업 또는 변경된 클라우드 계정·폴더를 확인해야 합니다. ‘클라우드 위치 다시 연결’에서 사용할 폴더를 선택하세요.");
        return Create(job.DestinationType,job.CloudFolderId,account,job.CloudFolderIdentity,job.DestinationType=="GoogleDrive");
    }
    public IRemoteStore ForAccountRoot(string provider)=>Create(provider,provider=="GoogleDrive" ? "root" : "/",CloudAccounts.Read(config()).For(provider));
    public IRemoteStore ForSelectedRoot(string provider,string root,string folderIdentity="")=>Create(provider,root,CloudAccounts.Read(config()).For(provider),folderIdentity);
    private IRemoteStore Create(string provider,string root,CloudAccount account,string folderIdentity="",bool requireManagedRoot=false)
    {
        if(account.RefreshTokenProtected.Length==0 || account.AccountId.Length==0)throw new InvalidOperationException("클라우드 계정을 먼저 연결하세요.");
        if(provider=="GoogleDrive")GoogleFileAccess.ValidateAccount(account);
        var retryState=retryStates.GetOrAdd(provider+"|"+account.AccountId,_=>new());
        var http=new CloudHttp(client,(force,token)=>Authentication.AccessAsync(provider,account,force,token),retryState:retryState);
        return provider switch {"GoogleDrive"=>new GoogleDriveStore(http,Vault,root,account.AccountId,requireManagedRoot || (root!="root" && folderIdentity.Length>0),fileAccess:true),"Dropbox"=>new DropboxStore(http,Vault,root,account.AccountId,folderIdentity),_=>throw new ArgumentException("Unknown cloud provider.")};
    }
    public void Dispose(){client.Dispose();}
}
