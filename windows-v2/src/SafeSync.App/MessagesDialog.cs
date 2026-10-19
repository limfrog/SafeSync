using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private Window? messagesWindow;
    private sealed record MessageRow(string Key,string JobName,string File,string Message,NoticeEntry? Notice);
    private MessageRow[] MessageRows()
    {
        var index=noticeLedger.Entries.GroupBy(NoticeKey).ToDictionary(g=>g.Key,g=>g.First());
        var names=jobs.ToDictionary(j=>j.Id,j=>j.Name);
        return notices.Select(key=>index.TryGetValue(key,out var entry) ? new MessageRow(key,names.GetValueOrDefault(entry.JobId,"이전 작업"),entry.File.Length>0 ? entry.File : "[작업]",entry.Message,entry) : new MessageRow(key,"프로그램","",key.Replace('|',' '),null)).ToArray();
    }
    private static string NoticeKey(NoticeEntry entry)=>entry.JobId+"|"+entry.File+"|"+entry.Message;
    private void RefreshMessages()
    {
        if(messagesWindow is not {} window)return;
        var grid=window.Find<DataGrid>("MessagesGrid");var key=(grid.SelectedItem as MessageRow)?.Key;
        var rows=MessageRows();grid.ItemsSource=rows;grid.SelectedItem=rows.FirstOrDefault(r=>r.Key==key) ?? rows.FirstOrDefault();
        window.Find<TextBlock>("MessageCountText").Text=$"확인할 메시지 {rows.Length:N0}개";
        window.Find<TextBlock>("MessagesEmptyText").Visibility=rows.Length==0 ? Visibility.Visible : Visibility.Collapsed;
        window.Find<Button>("ClearMessagesButton").IsEnabled=rows.Length>0;
        RefreshMessageRecovery();
    }
    private void RefreshMessageRecovery()
    {if(messagesWindow is {} window)window.Find<Button>("ResolveMessageButton").IsEnabled=window.Find<DataGrid>("MessagesGrid").SelectedItem is MessageRow {Notice:not null} row && jobs.Any(j=>j.Id==row.Notice.JobId);}
    private void ShowNotices()
    {
        if(messagesWindow is {} open){RefreshMessages();open.Show();open.Activate();return;}
        var window=NewDialog("Messages",false);messagesWindow=window;
        foreach(DictionaryEntry resource in Main.Resources)if(!window.Resources.Contains(resource.Key))window.Resources[resource.Key]=resource.Value;
        Theme.Apply(window,config.ThemeMode);
        Click(window,"CloseMessagesButton",window.Close);
        window.Find<DataGrid>("MessagesGrid").SelectionChanged+=(_,_)=>RefreshMessageRecovery();
        Click(window,"ResolveMessageButton",()=>
        {
            if(window.Find<DataGrid>("MessagesGrid").SelectedItem is MessageRow {Notice:not null} row && jobs.FirstOrDefault(j=>j.Id==row.Notice.JobId) is {} job)ShowJobRecovery(job);
        });
        Click(window,"ClearMessagesButton",()=>
        {
            var viewed=window.Find<DataGrid>("MessagesGrid").Items.OfType<MessageRow>().ToArray();
            try
            {
                noticeLedger.Dismiss(viewed.Where(r=>r.Notice!=null).Select(r=>r.Notice!));
                foreach(var row in viewed)notices.Remove(row.Key);
                foreach(var entry in noticeLedger.Entries)notices.Add(NoticeKey(entry));
                UpdateNotices();Log($"확인한 메시지 {viewed.Length:N0}개 비움 — 백업 상태는 유지했습니다.");
            }
            catch(Exception ex){Tell(ex.Message,"메시지 저장 실패");}
        });
        window.Closed+=(_,_)=>messagesWindow=null;RefreshMessages();window.Show();
    }
}
