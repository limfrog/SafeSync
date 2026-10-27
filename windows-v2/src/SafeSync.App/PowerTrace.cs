using System;
using Microsoft.Win32;
using SafeSync.Core;
namespace SafeSync.App;
internal sealed class PowerTrace : IDisposable
{
    public PowerTrace(){SystemEvents.PowerModeChanged+=Changed;}
    private static void Changed(object? sender,PowerModeChangedEventArgs args)=>OperationLog.Event("system.power",args.Mode.ToString());
    public void Dispose(){SystemEvents.PowerModeChanged-=Changed;}
}
