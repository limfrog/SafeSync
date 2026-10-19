using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private readonly Dictionary<string,FileIssue[]> restoredLocked=[];
    private async Task LoadWaitingAsync()
    {
        var snapshot=jobs.ToArray();
        var loaded=await Task.Run(()=>snapshot.ToDictionary(j=>j.Id,j=>
        {
            try{return store.LoadState(j).Files.Where(e=>e.Status=="Locked").Select(e=>new FileIssue(j.Id,j.Name,e.RelativePath,"다른 프로그램에서 사용 중 · 재시도 대기",e.Length,0,e.LastWriteTimeUtc,"",e.LockedSinceUtc,e.LockRetryCount,e.LastAttemptUtc)).ToArray();}
            catch(Exception ex) when(ex is System.IO.IOException or System.Text.Json.JsonException){return Array.Empty<FileIssue>();}
        }));
        foreach(var pair in loaded)if(!results.ContainsKey(pair.Key))restoredLocked[pair.Key]=pair.Value;
        RefreshProgress();
    }
}
