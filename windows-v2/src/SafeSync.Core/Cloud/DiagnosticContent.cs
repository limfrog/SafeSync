using System.Net;
using System.Diagnostics;
namespace SafeSync.Core.Cloud;
internal sealed class DiagnosticContent : HttpContent
{
    private readonly HttpContent inner;private readonly string operation;
    public DiagnosticContent(HttpContent inner,string operation){this.inner=inner;this.operation=operation;foreach(var h in inner.Headers)Headers.TryAddWithoutValidation(h.Key,h.Value);}
    protected override bool TryComputeLength(out long length){length=inner.Headers.ContentLength ?? 0;return inner.Headers.ContentLength!=null;}
    protected override Task SerializeToStreamAsync(Stream stream,TransportContext? context)=>Copy(stream,context,CancellationToken.None);
    protected override Task SerializeToStreamAsync(Stream stream,TransportContext? context,CancellationToken token)=>Copy(stream,context,token);
    private async Task Copy(Stream stream,TransportContext? context,CancellationToken token)
    {using var timing=OperationLog.Measure("http.request_body");using var counter=new Counter(stream,operation,inner.Headers.ContentLength);await inner.CopyToAsync(counter,context,token);counter.Report(true);}
    protected override void Dispose(bool disposing){if(disposing)inner.Dispose();base.Dispose(disposing);}
    private sealed class Counter : Stream
    {
        private readonly Stream target;private readonly string operation;private readonly long? expected;
        private readonly long started=Stopwatch.GetTimestamp();private readonly Timer timer;
        private long sent,lastProgress=Stopwatch.GetTimestamp(),lastReport;
        public Counter(Stream target,string operation,long? expected)
        {this.target=target;this.operation=operation;this.expected=expected;timer=new(_=>OperationLog.Event("transfer.wait",operation,bytes:Interlocked.Read(ref sent),detail:$"idleMs={Stopwatch.GetElapsedTime(Interlocked.Read(ref lastProgress)).TotalMilliseconds:F0};expectedBytes={expected}"),null,10000,10000);}
        public void Report(bool force=false)
        {if(!force && Stopwatch.GetElapsedTime(Interlocked.Read(ref lastReport)).TotalSeconds<1)return;Interlocked.Exchange(ref lastReport,Stopwatch.GetTimestamp());OperationLog.Event("transfer.progress",operation,bytes:Interlocked.Read(ref sent),detail:$"elapsedMs={Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0};expectedBytes={expected}");}
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer,CancellationToken token=default)
        {await target.WriteAsync(buffer,token);Interlocked.Add(ref sent,buffer.Length);Interlocked.Exchange(ref lastProgress,Stopwatch.GetTimestamp());Report();}
        public override Task WriteAsync(byte[] buffer,int offset,int count,CancellationToken token)=>WriteAsync(buffer.AsMemory(offset,count),token).AsTask();
        public override void Write(byte[] buffer,int offset,int count){target.Write(buffer,offset,count);Interlocked.Add(ref sent,count);Interlocked.Exchange(ref lastProgress,Stopwatch.GetTimestamp());Report();}
        protected override void Dispose(bool disposing){if(disposing)timer.Dispose();base.Dispose(disposing);}
        public override bool CanRead=>false;public override bool CanSeek=>false;public override bool CanWrite=>true;
        public override long Length=>throw new NotSupportedException();public override long Position{get=>sent;set=>throw new NotSupportedException();}
        public override void Flush()=>target.Flush();public override Task FlushAsync(CancellationToken token)=>target.FlushAsync(token);
        public override int Read(byte[] buffer,int offset,int count)=>throw new NotSupportedException();public override long Seek(long offset,SeekOrigin origin)=>throw new NotSupportedException();public override void SetLength(long value)=>throw new NotSupportedException();
    }
}
