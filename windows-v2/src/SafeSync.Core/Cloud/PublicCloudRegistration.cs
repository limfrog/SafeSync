using System.Reflection;

namespace SafeSync.Core.Cloud;

// An app key identifies a PUBLIC desktop client; it is NOT an app secret.
// Release builds inject the registered public key, so end users never have to
// create their own Dropbox developer app. No private token belongs in a build.
public static class PublicCloudRegistration
{
    public static string DropboxAppKey=>typeof(PublicCloudRegistration).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a=>a.Key=="SafeSyncDropboxAppKey")?.Value ?? "";
    public static CloudAccounts Apply(CloudAccounts accounts)
    {
        if(accounts.Dropbox.AppKey.Length==0)accounts.Dropbox.AppKey=DropboxAppKey;
        return accounts;
    }
}
