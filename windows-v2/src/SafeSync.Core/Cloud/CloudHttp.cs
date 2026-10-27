using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Diagnostics;

namespace SafeSync.Core.Cloud;

public sealed class CloudApiException(HttpStatusCode status,string operation,bool notFound=false,long? correctOffset=null,bool sessionExpired=false,TimeSpan? retryAfter=null) : IOException($"{operation}: HTTP {(int)status}. 인증 상태 또는 연결을 확인하세요.")
{
    public HttpStatusCode Status {get;}=status;
    public bool NotFound {get;}=notFound || status==HttpStatusCode.NotFound;
    public long? CorrectOffset {get;}=correctOffset;
    public bool SessionExpired {get;}=sessionExpired;
    public TimeSpan? RetryAfter {get;}=retryAfter;
}
public static class CloudJson
{
    public static string String(this JsonElement json,string name)=>json.TryGetProperty(name,out var item) ? item.ToString() : "";
    public static long Number(this JsonElement json,string name)=>long.TryParse(json.String(name),out var number) ? number : 0;
    public static bool True(this JsonElement json,string name)=>json.TryGetProperty(name,out var item) && item.ValueKind==JsonValueKind.True;
    public static DateTime Time(this JsonElement json,string name)=>DateTime.TryParse(json.String(name),System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.RoundtripKind,out var date) ? date.ToUniversalTime() : DateTime.MinValue;
    public static string Query(params (string Key,string Value)[] values)=>string.Join('&',values.Where(v=>v.Value.Length>0).Select(v=>Uri.EscapeDataString(v.Key)+"="+Uri.EscapeDataString(v.Value)));
    public static HttpContent Body(object? value)=>new StringContent(JsonSerializer.Serialize(value),Encoding.UTF8,"application/json");
    public static async Task<JsonElement> ReadAsync(HttpResponseMessage response,CancellationToken token)
    {
        await using var stream=await response.Content.ReadAsStreamAsync(token);
        using var document=await JsonDocument.ParseAsync(stream,cancellationToken:token);return document.RootElement.Clone();
    }
}

public sealed class CloudRetryState
{
    private readonly object gate=new();
    private DateTimeOffset notBefore;
    public TimeSpan Remaining {get{lock(gate)return notBefore>DateTimeOffset.UtcNow ? notBefore-DateTimeOffset.UtcNow : TimeSpan.Zero;}}
    public void Defer(TimeSpan delay)
    {
        if(delay<=TimeSpan.Zero)return;
        var now=DateTimeOffset.UtcNow;var until=delay.Ticks>DateTimeOffset.MaxValue.Ticks-now.Ticks ? DateTimeOffset.MaxValue : now+delay;
        lock(gate)if(until>notBefore)notBefore=until;
    }
}

public sealed class CloudHttp(HttpClient client,Func<bool,CancellationToken,Task<string>> accessToken,
    Func<TimeSpan,CancellationToken,Task>? retryDelay=null,CloudRetryState? retryState=null)
{
    public async Task<HttpResponseMessage> SendAsync(Func<HttpRequestMessage> request,CancellationToken token,bool allowResumeIncomplete=false)
    {
        int retries=0;bool refreshed=false,forceRefresh=false;
        while(true)
        {
            token.ThrowIfCancellationRequested();
            var remaining=retryState?.Remaining ?? TimeSpan.Zero;
            if(remaining>TimeSpan.FromMinutes(2))throw new CloudApiException(HttpStatusCode.TooManyRequests,"클라우드 서버가 지정한 대기 시간",retryAfter:remaining);
            if(remaining>TimeSpan.Zero){OperationLog.Event("retry.wait","http",bytes:(long)remaining.TotalMilliseconds);await DelayAsync(remaining,token);}
            using var message=request();ValidateUri(message.RequestUri!);
            bool readOnly=ReadOnly(message);
            var started=Stopwatch.GetTimestamp();var operation=OperationLog.Endpoint(message.RequestUri!);var authStarted=started;
            message.Headers.Authorization=new AuthenticationHeaderValue("Bearer",await accessToken(forceRefresh,token));forceRefresh=false;
            var authMs=Stopwatch.GetElapsedTime(authStarted).TotalMilliseconds;
            HttpResponseMessage response;
            try{response=await client.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,token);OperationLog.Http(message.Method+" "+operation,started,message.Content?.Headers.ContentLength,(int)response.StatusCode,retries,null,authMs);}
            catch(Exception ex) when(readOnly && retries<4 && !token.IsCancellationRequested && ex is HttpRequestException or TaskCanceledException)
            {OperationLog.Http(message.Method+" "+operation,started,message.Content?.Headers.ContentLength,null,retries,ex,authMs);await DelayAsync(Backoff(retries++),token);continue;}
            catch(Exception ex){OperationLog.Http(message.Method+" "+operation,started,message.Content?.Headers.ContentLength,null,retries,ex,authMs);throw;}
            if(response.StatusCode==HttpStatusCode.Unauthorized && !refreshed){response.Dispose();refreshed=true;forceRefresh=true;continue;}
            if(!response.IsSuccessStatusCode && !(allowResumeIncomplete && (int)response.StatusCode==308))
            {
                using var failedResponse=response;
                var status=response.StatusCode;bool notFound=false,expired=false;long? correctOffset=null;
                bool rateLimited=status==HttpStatusCode.TooManyRequests;
                var retryAfter=response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date is {} date ? date-DateTimeOffset.UtcNow : (TimeSpan?)null);
                if(retryAfter<TimeSpan.Zero)retryAfter=TimeSpan.Zero;
                if(status is HttpStatusCode.Conflict or HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests)
                {
                    try
                    {
                        var body=await CloudJson.ReadAsync(response,token);
                        if(status==HttpStatusCode.Conflict)
                        {
                            var summary=body.String("error_summary");notFound=summary.Split('/').Contains("not_found");
                            expired=summary.Contains("lookup_failed/not_found",StringComparison.Ordinal)||summary.Contains("lookup_failed/closed",StringComparison.Ordinal);correctOffset=FindOffset(body);
                        }
                        if(status==HttpStatusCode.Forbidden && message.RequestUri!.Host=="www.googleapis.com")rateLimited=RateLimitReason(body);
                    }
                    catch(Exception ex) when(ex is JsonException or InvalidOperationException){}
                }
                response.Dispose();
                // Rate-limit responses reject a request before execution. A 5xx,
                // timeout or lost response may have committed a mutation: never
                // blindly repeat creates/moves/upload chunks. Their journals and
                // upload-session status checks reconcile them on the next run.
                bool retryable=rateLimited || readOnly && status is HttpStatusCode.RequestTimeout or HttpStatusCode.InternalServerError or HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable or HttpStatusCode.GatewayTimeout;
                var delay=retryAfter ?? Backoff(retries);
                if(rateLimited)retryState?.Defer(delay);
                if(retryable && retries<4 && delay<=TimeSpan.FromMinutes(2))
                {retries++;await DelayAsync(delay,token);continue;}
                throw new CloudApiException(status,message.Method+" "+message.RequestUri!.AbsolutePath,notFound,correctOffset,expired,retryAfter);
            }
            return response;
        }
    }
    private async Task DelayAsync(TimeSpan delay,CancellationToken token)
    {OperationLog.Event("retry.wait","http",detail:$"delayMs={delay.TotalMilliseconds:F0}");using var timing=OperationLog.Measure("http.retry_delay");await (retryDelay ?? Task.Delay)(delay,token);}
    private static TimeSpan Backoff(int attempt)=>TimeSpan.FromMilliseconds(1000*(1<<attempt)+Random.Shared.Next(0,401));
    private static bool ReadOnly(HttpRequestMessage message)
    {
        if(message.Method==HttpMethod.Get || message.Method==HttpMethod.Head)return true;
        var uri=message.RequestUri!;
        return message.Method==HttpMethod.Post &&
            (uri.Host=="www.googleapis.com" && uri.AbsolutePath=="/batch/drive/v3" ||
             uri.Host=="api.dropboxapi.com" && uri.AbsolutePath is "/2/users/get_current_account" or "/2/files/get_metadata" or "/2/files/list_folder" or "/2/files/list_folder/continue" or "/2/files/list_folder/get_latest_cursor");
    }
    private static bool RateLimitReason(JsonElement value)
    {
        if(value.ValueKind==JsonValueKind.Array)return value.EnumerateArray().Any(RateLimitReason);
        if(value.ValueKind!=JsonValueKind.Object)return false;
        if(value.TryGetProperty("reason",out var reason) && reason.ValueKind==JsonValueKind.String && reason.GetString() is "rateLimitExceeded" or "userRateLimitExceeded")return true;
        return value.EnumerateObject().Any(p=>RateLimitReason(p.Value));
    }
    private static long? FindOffset(JsonElement value)
    {
        if(value.ValueKind!=JsonValueKind.Object)return null;
        if(value.TryGetProperty("correct_offset",out var offset) && offset.TryGetInt64(out var number))return number;
        foreach(var field in value.EnumerateObject())if(FindOffset(field.Value) is {} found)return found;
        return null;
    }
    public async Task<JsonElement> JsonAsync(HttpMethod method,string uri,object? body,CancellationToken token)
    {
        using var response=await SendAsync(()=>new HttpRequestMessage(method,uri){Content=body==null && method==HttpMethod.Get ? null : CloudJson.Body(body)},token);
        return await CloudJson.ReadAsync(response,token);
    }
    public static void ValidateUri(Uri uri)
    {
        if(uri.Scheme!="https" || !uri.IsDefaultPort || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment) ||
            uri.Host is not ("www.googleapis.com" or "content.googleapis.com" or "api.dropboxapi.com" or "content.dropboxapi.com"))
            throw new InvalidDataException("허용하지 않은 클라우드 전송 주소입니다.");
    }
}
