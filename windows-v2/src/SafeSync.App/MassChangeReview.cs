using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using SafeSync.Core;
namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private void ShowMassChangeReview()
    {
        if(Selected is not {} job || scheduler.IsRunning(job.Id))return;
        try
        {
            var proposal=MassChanges.Pending(store,job);
            if(proposal==null){Tell("이 작업에 보류된 대량 변경이 없습니다.");return;}
            var window=NewDialog("MassChangeReview");
            window.Find<TextBlock>("SummaryText").Text=$"{job.Name} · 기존 {proposal.Baseline:N0}개 / 변경·삭제 {proposal.Changes.Length:N0}건\n원본: {job.Source}\n백업: {job.Destination}";
            window.Find<DataGrid>("ChangesGrid").ItemsSource=proposal.Changes;
            Click(window,"CancelButton",window.Close);
            Click(window,"ApproveButton",()=>
            {
                if(scheduler.IsRunning(job.Id)){Tell("현재 작업이 끝난 뒤 확인하세요.");return;}
                try{MassChanges.Approve(store,job,proposal.Fingerprint);window.Close();Log(job.Name+": 검토한 대량 변경을 다음 실행에서 1회 허용했습니다. 지금 백업을 눌러 진행하세요.");}
                catch(Exception ex){Tell(ex.Message);}
            });
            window.ShowDialog();
        }
        catch(Exception ex){Tell(ex.Message);}
    }
}
