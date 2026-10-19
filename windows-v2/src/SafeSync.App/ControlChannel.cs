using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;

namespace SafeSync.App;

// CurrentUserOnly rejects requests from other Windows accounts. The installer
// requests a graceful shutdown; it never kills a live backup process.
internal sealed class ControlChannel : IDisposable
{
    private readonly CancellationTokenSource stop=new();
    private readonly Task listening;
    internal ControlChannel(Func<Task> exit,string name="SafeSync2.Control")=>listening=ListenAsync(exit,name);
    private async Task ListenAsync(Func<Task> exit,string name)
    {
        try
        {
            while(!stop.IsCancellationRequested)
            {
                await using var pipe=new NamedPipeServerStream(name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stop.Token);
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(stop.Token);timeout.CancelAfter(TimeSpan.FromSeconds(3));
                using var reader=new StreamReader(pipe);
                // Only a fixed-size command is accepted; no file/argument paths.
                char[] command=new char[5];int read=0;
                try{while(read<5){int count=await reader.ReadAsync(command.AsMemory(read),timeout.Token);if(count==0)break;read+=count;}}
                catch(OperationCanceledException) when(!stop.IsCancellationRequested){continue;}
                catch(IOException){continue;}
                if(new string(command,0,read) is "exit\n" or "exit\r"){await exit();return;}
            }
        }
        catch(OperationCanceledException) when(stop.IsCancellationRequested){}
        catch(IOException){} // Deployment remains fail-closed if IPC is unavailable.
    }
    public void Dispose(){stop.Cancel();_=listening.ContinueWith(_=>stop.Dispose(),TaskScheduler.Default);}
}
