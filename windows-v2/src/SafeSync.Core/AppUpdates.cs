using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SafeSync.Core;

public sealed class AppUpdateVersion : IComparable<AppUpdateVersion>
{
    private static readonly Regex Pattern=new(@"\Av?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z",RegexOptions.CultureInvariant);
    private readonly uint major,minor,patch;
    private readonly string[] prerelease;
    public string Value {get;}
    public bool IsPreview=>prerelease.Length>0;
    public AppUpdateVersion(string value)
    {
        if(value==null || value.Length>100)throw new InvalidDataException("업데이트 버전 형식이 잘못되었습니다.");
        var match=Pattern.Match(value);
        if(!match.Success || !uint.TryParse(match.Groups[1].Value,out major) || !uint.TryParse(match.Groups[2].Value,out minor) || !uint.TryParse(match.Groups[3].Value,out patch))
            throw new InvalidDataException("업데이트 버전 형식이 잘못되었습니다.");
        prerelease=match.Groups[4].Success ? match.Groups[4].Value.Split('.') : [];
        if(prerelease.Any(p=>p.All(char.IsAsciiDigit) && p.Length>1 && p[0]=='0'))throw new InvalidDataException("업데이트 사전 버전 번호가 잘못되었습니다.");
        Value=value.TrimStart('v');
    }
    public int CompareTo(AppUpdateVersion? other)
    {
        if(other==null)return 1;
        int compare=major.CompareTo(other.major);if(compare!=0)return compare;
        compare=minor.CompareTo(other.minor);if(compare!=0)return compare;
        compare=patch.CompareTo(other.patch);if(compare!=0)return compare;
        if(prerelease.Length==0 || other.prerelease.Length==0)return (prerelease.Length==0 ? 1 : 0).CompareTo(other.prerelease.Length==0 ? 1 : 0);
        for(int i=0;i<Math.Min(prerelease.Length,other.prerelease.Length);i++)
        {
            string a=prerelease[i],b=other.prerelease[i];bool an=a.All(char.IsAsciiDigit),bn=b.All(char.IsAsciiDigit);
            compare=an && bn ? a.Length.CompareTo(b.Length) : an!=bn ? (an ? -1 : 1) : 0;
            if(compare==0)compare=string.CompareOrdinal(a,b);
            if(compare!=0)return compare;
        }
        return prerelease.Length.CompareTo(other.prerelease.Length);
    }
    public bool IsNewerThan(string current)
    {
        var installed=new AppUpdateVersion(current);
        return !(IsPreview && !installed.IsPreview) && CompareTo(installed)>0;
    }
}

public sealed record AppUpdateRelease(string Version,string Url,string Sha256,long Size,string Notes="");
public sealed class AppUpdateFeed
{
    public int SchemaVersion {get;set;}
    public AppUpdateRelease? Windows {get;set;}
    public AppUpdateRelease? MacOS {get;set;}
}
public sealed record AppUpdateProgress(long Received,long Total);

// A release is announced only after its installer and checksums are published.
// This client never follows redirects or executes a response chosen by a server.
public sealed class AppUpdateClient : IDisposable
{
    public static readonly Uri FeedUri=new("https://raw.githubusercontent.com/limfrog/SafeSync/main/updates/latest.json");
    private readonly HttpClient http;
    public AppUpdateClient(HttpMessageHandler? handler=null)
    {
        http=new(handler ?? new HttpClientHandler {AllowAutoRedirect=false,UseCookies=false,AutomaticDecompression=DecompressionMethods.None}) {Timeout=Timeout.InfiniteTimeSpan};
        http.DefaultRequestHeaders.UserAgent.ParseAdd("SafeSync-Updater/1.0");
    }
    public static string FileName(AppUpdateRelease release,string platform)
    {
        var version=new AppUpdateVersion(release.Version);
        if(version.Value!=release.Version)throw new InvalidDataException("배포 버전은 v 접두사 없이 지정해야 합니다.");
        return platform switch {"windows-x64"=>$"SafeSync-Setup-{version.Value}.exe","macos-universal"=>$"SafeSync-macOS-{version.Value}-universal.zip",_=>throw new InvalidDataException("지원하지 않는 업데이트 플랫폼입니다.")};
    }
    public static Uri Validate(AppUpdateRelease release,string platform)
    {
        string name=FileName(release,platform);
        if(release.Size is <=0 or >1024L*1024*1024 || release.Sha256?.Length!=64 || !Regex.IsMatch(release.Sha256,"\u005e[a-fA-F0-9]{64}$") || release.Notes==null || release.Notes.Length>8000)
            throw new InvalidDataException("업데이트 파일 검증 정보가 잘못되었습니다.");
        string expected="https://raw.githubusercontent.com/limfrog/SafeSync/main/dist/"+name;
        if(!string.Equals(release.Url,expected,StringComparison.Ordinal) || !Uri.TryCreate(release.Url,UriKind.Absolute,out var uri))
            throw new InvalidDataException("SafeSync 공식 저장소의 업데이트 파일이 아닙니다.");
        return uri;
    }
    public async Task<AppUpdateRelease?> CheckAsync(string current,string platform,CancellationToken token)
    {
        using var limit=CancellationTokenSource.CreateLinkedTokenSource(token);limit.CancelAfter(TimeSpan.FromSeconds(25));
        using var request=new HttpRequestMessage(HttpMethod.Get,FeedUri);
        request.Headers.CacheControl=new(){NoCache=true};
        using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,limit.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if(response.Content.Headers.ContentLength>65536)throw new InvalidDataException("업데이트 정보가 너무 큽니다.");
        await using var stream=await response.Content.ReadAsStreamAsync(limit.Token).ConfigureAwait(false);
        using var bytes=new MemoryStream();byte[] buffer=new byte[4096];int read;
        while((read=await stream.ReadAsync(buffer,limit.Token).ConfigureAwait(false))>0)
        {if(bytes.Length+read>65536)throw new InvalidDataException("업데이트 정보가 너무 큽니다.");bytes.Write(buffer,0,read);}
        var feed=JsonSerializer.Deserialize<AppUpdateFeed>(bytes.ToArray(),JsonFile.Options) ?? throw new InvalidDataException("업데이트 정보가 비어 있습니다.");
        if(feed.SchemaVersion!=1)throw new InvalidDataException("지원하지 않는 업데이트 정보 형식입니다.");
        var release=platform switch {"windows-x64"=>feed.Windows,"macos-universal"=>feed.MacOS,_=>throw new InvalidDataException("지원하지 않는 업데이트 플랫폼입니다.")};
        if(release==null)return null;
        Validate(release,platform);
        return new AppUpdateVersion(release.Version).IsNewerThan(current) ? release : null;
    }
    public static async Task<bool> VerifyAsync(string path,AppUpdateRelease release,CancellationToken token)
    {
        try
        {
            PathPolicy.RejectLinks(Path.GetDirectoryName(path)!,path);
            await using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,131072,FileOptions.Asynchronous|FileOptions.SequentialScan);
            return input.Length==release.Size && Convert.ToHexStringLower(await SHA256.HashDataAsync(input,token).ConfigureAwait(false)).Equals(release.Sha256,StringComparison.OrdinalIgnoreCase);
        }
        catch(FileNotFoundException){return false;}
        catch(DirectoryNotFoundException){return false;}
    }
    public async Task<string> DownloadAsync(AppUpdateRelease release,string platform,string cache,IProgress<AppUpdateProgress>? progress,CancellationToken token)
    {
        var uri=Validate(release,platform);string name=FileName(release,platform);
        PathPolicy.RejectLinks(cache,cache);Directory.CreateDirectory(cache);
        string final=PathPolicy.Combine(cache,name);
        if(await VerifyAsync(final,release,token).ConfigureAwait(false)){progress?.Report(new(release.Size,release.Size));return final;}
        string partial=final+"."+Guid.NewGuid().ToString("N")+".part";
        using var limit=CancellationTokenSource.CreateLinkedTokenSource(token);limit.CancelAfter(TimeSpan.FromMinutes(20));
        try
        {
            using var response=await http.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,limit.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if(response.Content.Headers.ContentLength is long length && length!=release.Size)throw new InvalidDataException("다운로드 크기가 게시된 정보와 다릅니다.");
            await using(var source=await response.Content.ReadAsStreamAsync(limit.Token).ConfigureAwait(false))
            await using(var target=new FileStream(partial,FileMode.CreateNew,FileAccess.Write,FileShare.None,131072,FileOptions.Asynchronous|FileOptions.SequentialScan))
            {
                byte[] buffer=new byte[131072];long total=0;int read;
                while((read=await source.ReadAsync(buffer,limit.Token).ConfigureAwait(false))>0)
                {
                    if(read>release.Size-total)throw new InvalidDataException("게시된 크기를 초과한 업데이트 파일입니다.");
                    await target.WriteAsync(buffer.AsMemory(0,read),limit.Token).ConfigureAwait(false);total+=read;progress?.Report(new(total,release.Size));
                }
                await target.FlushAsync(limit.Token).ConfigureAwait(false);target.Flush(true);
            }
            if(!await VerifyAsync(partial,release,limit.Token).ConfigureAwait(false))throw new InvalidDataException("업데이트 체크섬 검증에 실패했습니다. 설치하지 않았습니다.");
            PathPolicy.RejectLinks(cache,final);File.Move(partial,final,true);return final;
        }
        finally{if(File.Exists(partial))File.Delete(partial);}
    }
    public void Dispose()=>http.Dispose();
}
