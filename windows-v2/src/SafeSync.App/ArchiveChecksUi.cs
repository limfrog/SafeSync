using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;
using SafeSync.Core.Cloud;
namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task VerifyTrashSelectionAsync<T>(Window window,T[] items,Func<T,CancellationToken,Task<bool>> verify,CancellationToken token)
    {
        int okay=0,legacy=0,failed=0;
        void Status(T item,string text){if(item is TrashItem a)a.VerificationStatus=text;else if(item is CloudTrashItem b)b.VerificationStatus=text;}
        foreach(var item in items)
        {
            token.ThrowIfCancellationRequested();Status(item,"검증 중…");window.Find<DataGrid>("TrashGrid").Items.Refresh();
            try{if(await verify(item,token)){okay++;Status(item,"정상");}else{legacy++;Status(item,"기준 없음 · 읽기 확인");}}
            catch(OperationCanceledException){throw;}
            catch(Exception ex){failed++;Status(item,"실패: "+ex.Message);Log("복원 검증: "+ex.Message);}
            window.Find<TextBlock>("StatusText").Text=$"복원 검증 {okay+legacy+failed}/{items.Length} · 정상 {okay} · 이전 기준 없음 {legacy} · 실패 {failed}";
            window.Find<DataGrid>("TrashGrid").Items.Refresh();await Task.Yield();
        }
    }
}
