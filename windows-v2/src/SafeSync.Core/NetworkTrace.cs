using System.Collections.Concurrent;
using System.Diagnostics;
using System.Diagnostics.Tracing;

namespace SafeSync.Core;

// Public networking events only. Payload strings (host/path/IP/errors) are
// deliberately ignored. Connection work can outlive its originating request.
public sealed class NetworkTrace : EventListener
{
    private static readonly object configuration=new();
    private static NetworkTrace? listener;
    public static void Configure(bool enabled)
    {
        lock(configuration)
        {
            if(enabled){listener ??= new();foreach(var source in EventSource.GetSources())listener.OnEventSourceCreated(source);}
            else {listener?.Dispose();listener=null;}
        }
    }
    private readonly ConcurrentDictionary<string,long> starts=new();
    protected override void OnEventSourceCreated(EventSource source)
    {
        if(OperationLog.IsEnabled && source.Name is "System.Net.NameResolution" or "System.Net.Sockets" or "System.Net.Security" or "System.Net.Http")EnableEvents(source,EventLevel.Informational);
    }
    protected override void OnEventWritten(EventWrittenEventArgs data)
    {
        try
        {
            if(!OperationLog.IsEnabled)return;
            var phase=data.EventSource.Name switch {"System.Net.NameResolution"=>"dns","System.Net.Sockets"=>"connect","System.Net.Security"=>"tls",_=>"http"};
            var name=data.EventName ?? "";
            if(name is "ResolutionStart" or "ConnectStart" or "HandshakeStart")
            {
                if(data.ActivityId!=Guid.Empty && starts.Count<2048)starts[phase+data.ActivityId]=Stopwatch.GetTimestamp();
                OperationLog.Event("network.start",phase,detail:$"activity={data.ActivityId:N};related={data.RelatedActivityId:N}");
            }
            else if(name is "ResolutionStop" or "ConnectStop" or "HandshakeStop" or "ResolutionFailed" or "ConnectFailed" or "HandshakeFailed")
            {
                var elapsed=data.ActivityId!=Guid.Empty && starts.TryRemove(phase+data.ActivityId,out var start) ? Stopwatch.GetElapsedTime(start).TotalMilliseconds : (double?)null;
                OperationLog.Event("network.end",phase,detail:$"activity={data.ActivityId:N};failed={name.EndsWith("Failed",StringComparison.Ordinal)};durationMs={elapsed?.ToString("F3",System.Globalization.CultureInfo.InvariantCulture) ?? "unavailable"}");
            }
            else if(name=="RequestLeftQueue" && data.PayloadNames!=null && data.Payload!=null)
            {
                var i=data.PayloadNames.IndexOf("timeOnQueueMilliseconds");
                if(i>=0 && data.Payload[i] is double ms)OperationLog.Event("network.queue","http",detail:$"activity={data.ActivityId:N};queueMs={ms:F3}");
            }
        }
        catch { }
    }
}
