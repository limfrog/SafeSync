using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using SafeSync.Core.Cloud;

namespace SafeSync.Core;

public static class NetworkFailures
{
    private static bool RetryStatus(HttpStatusCode status)=>status is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests or HttpStatusCode.InternalServerError or HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable or HttpStatusCode.GatewayTimeout;
    public static bool IsTransient(Exception error)
    {
        if(error is CloudConflictException or UnauthorizedAccessException or FileNotFoundException or DirectoryNotFoundException or InvalidDataException or AuthenticationException)return false;
        if(error is CloudApiException api)return RetryStatus(api.Status);
        if(error is HttpRequestException http)
            return http.InnerException is not AuthenticationException && (http.StatusCode is {} status ? RetryStatus(status) : true);
        if(error is SocketException socket)return socket.SocketErrorCode is SocketError.ConnectionAborted or SocketError.ConnectionReset or SocketError.TimedOut or SocketError.NetworkDown or SocketError.NetworkReset or SocketError.NetworkUnreachable or SocketError.HostUnreachable or SocketError.HostNotFound or SocketError.TryAgain or SocketError.ConnectionRefused;
        if(error is TimeoutException || error is TaskCanceledException {InnerException:TimeoutException})return true;
        if(error is IOException && (error.HResult&0xffff) is 53 or 54 or 55 or 58 or 59 or 64 or 67 or 71 or 121 or 1222 or 1231 or 1232 or 1236 or 1460 or 2250)return true;
        return error.InnerException!=null && IsTransient(error.InnerException);
    }
    // Old session records did not carry the exception code. Recognize only
    // known OS/service messages, not any text merely mentioning a network.
    public static bool LegacyMessage(string message)=>new[]{"예기치 않은 네트워크 오류가 발생했습니다","지정된 네트워크 이름을 더 이상 사용할 수 없습니다","An unexpected network error occurred","The specified network name is no longer available"}.Any(s=>message.StartsWith(s,StringComparison.OrdinalIgnoreCase)) || System.Text.RegularExpressions.Regex.IsMatch(message,@": HTTP (408|429|500|502|503|504)\.");
    public static bool Automatic(FileIssue issue)=>issue.AutomaticNetworkRetry || LegacyMessage(issue.Reason);
}
