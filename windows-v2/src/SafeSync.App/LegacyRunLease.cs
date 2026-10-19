using System;
using System.Threading;

namespace SafeSync.App;

// The 1.x launcher checks whether this named object already exists. Keep an
// unowned handle alive during native backups so a later 1.x start is blocked.
internal sealed class LegacyRunLease : IDisposable
{
    private static readonly object Gate=new();
    private static Mutex? mutex;
    private static int users;
    private bool disposed;
    public static bool OwnedByThisProcess {get{lock(Gate)return users>0;}}
    public static IDisposable Acquire()
    {
        lock(Gate)
        {
            if(users==0)
            {
                var candidate=new Mutex(false,"Local\\SafeSync.Launch",out var created);
                if(!created){candidate.Dispose();throw new InvalidOperationException("기존 PowerShell 버전 SafeSync가 실행 중입니다. 완전히 종료한 뒤 이 프리뷰에서 백업하세요.");}
                mutex=candidate;
            }
            users++;
            return new LegacyRunLease();
        }
    }
    public void Dispose()
    {
        lock(Gate)
        {
            if(disposed)return;disposed=true;
            if(--users==0){mutex?.Dispose();mutex=null;}
        }
    }
}
