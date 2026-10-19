using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SafeSync.Core.Cloud;

public sealed class CloudAccount
{
    public string AppKey {get;set;}="";
    public string ClientId {get;set;}="";
    public string ClientSecretProtected {get;set;}="";
    public string RefreshTokenProtected {get;set;}="";
    public string AccountName {get;set;}="";
    public string AccountId {get;set;}="";
    [JsonExtensionData] public Dictionary<string,JsonElement>? Extra {get;set;}
}
public sealed class CloudAccounts
{
    public CloudAccount Dropbox {get;set;}=new();
    public CloudAccount GoogleDrive {get;set;}=new();
    [JsonExtensionData] public Dictionary<string,JsonElement>? Extra {get;set;}
    public CloudAccount For(string provider)=>provider switch {"Dropbox"=>Dropbox,"GoogleDrive"=>GoogleDrive,_=>throw new ArgumentException("Unknown cloud provider.")};
    public static CloudAccounts Read(AppConfig config)=>PublicCloudRegistration.Apply(config.Extra!=null && config.Extra.TryGetValue("CloudAccounts",out var value)
        ? value.Deserialize<CloudAccounts>(JsonFile.Options) ?? new() : new());
    public void Write(AppConfig config)
    {
        config.Extra??=new();config.Extra["CloudAccounts"]=JsonSerializer.SerializeToElement(this,JsonFile.Options);
    }
}

public interface ISecretVault
{
    string Protect(string plain);
    string Unprotect(string encrypted,byte[]? legacyKey=null);
}

public sealed class WindowsSecretVault : ISecretVault
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob {public int Length;public IntPtr Data;}
    [DllImport("crypt32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input,string? description,IntPtr entropy,IntPtr reserved,IntPtr prompt,int flags,out Blob output);
    [DllImport("crypt32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input,IntPtr description,IntPtr entropy,IntPtr reserved,IntPtr prompt,int flags,out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public string Protect(string plain)
    {
        if(string.IsNullOrWhiteSpace(plain))return "";
        var bytes=Encoding.UTF8.GetBytes(plain);
        try{return "dpapi:"+Convert.ToBase64String(Transform(bytes,true));}
        finally{CryptographicOperations.ZeroMemory(bytes);}
    }
    public string Unprotect(string encrypted,byte[]? legacyKey=null)
    {
        if(string.IsNullOrWhiteSpace(encrypted))return "";
        byte[] plain;
        if(encrypted.StartsWith("aes:",StringComparison.Ordinal))
        {
            if(legacyKey?.Length!=64)throw new CryptographicException("기존 AES 인증 정보를 옮기려면 원본 secrets.key가 필요합니다.");
            var all=Convert.FromBase64String(encrypted[4..]);
            if(all.Length<64)throw new CryptographicException("Invalid encrypted credential.");
            var payload=all.AsSpan(0,all.Length-32);
            var expected=HMACSHA256.HashData(legacyKey.AsSpan(32,32),payload);
            if(!CryptographicOperations.FixedTimeEquals(expected,all.AsSpan(all.Length-32)))throw new CryptographicException("Credential integrity verification failed.");
            using var aes=Aes.Create();aes.Key=legacyKey[..32];aes.IV=payload[..16].ToArray();
            plain=aes.DecryptCbc(payload[16..],aes.IV,PaddingMode.PKCS7);
        }
        else
        {
            var bytes=Convert.FromBase64String(encrypted.StartsWith("dpapi:",StringComparison.Ordinal) ? encrypted[6..] : encrypted);
            plain=Transform(bytes,false);
        }
        try{return Encoding.UTF8.GetString(plain);}finally{CryptographicOperations.ZeroMemory(plain);}
    }
    private static byte[] Transform(byte[] bytes,bool protect)
    {
        var input=new Blob {Length=bytes.Length,Data=Marshal.AllocHGlobal(bytes.Length)};
        Blob output=default;
        try
        {
            Marshal.Copy(bytes,0,input.Data,bytes.Length);
            bool success=protect ? CryptProtectData(ref input,null,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output)
                : CryptUnprotectData(ref input,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,1,out output);
            if(!success)throw new CryptographicException("Windows 사용자 인증 정보 보호에 실패했습니다.",new Win32Exception(Marshal.GetLastWin32Error()));
            var result=new byte[output.Length];Marshal.Copy(output.Data,result,0,result.Length);return result;
        }
        finally
        {
            for(int i=0;i<input.Length;i++)Marshal.WriteByte(input.Data,i,0);Marshal.FreeHGlobal(input.Data);
            if(output.Data!=IntPtr.Zero){for(int i=0;i<output.Length;i++)Marshal.WriteByte(output.Data,i,0);LocalFree(output.Data);}
        }
    }
}
