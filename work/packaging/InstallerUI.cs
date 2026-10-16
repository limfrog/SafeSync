using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal sealed class InstallerForm : Form
{
    internal readonly Button ActionButton;
    internal readonly CheckBox DesktopBox;
    internal readonly CheckBox LaunchBox;
    private readonly Label status;
    private readonly ProgressBar progress;
    private readonly Button cancel;
    private bool completed, working;

    internal InstallerForm(bool remove, Action<InstallerForm> action)
    {
        Text = remove ? "SafeSync 제거" : "SafeSync 설치";
        Font = new Font("Malgun Gothic", 10F);
        ClientSize = new Size(640, 432); FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Shield; AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Color.White;
        var title = new Label { Text = remove ? "SafeSync를 제거합니다" : "SafeSync 자동 백업", Location = new Point(28, 24), Size = new Size(580, 38), Font = new Font("Malgun Gothic", 18F, FontStyle.Bold) };
        var description = new Label {
            Text = remove ? "프로그램 파일과 바로 가기만 제거합니다.\r\n백업 작업 설정, 클라우드 연결 정보, 실제 백업 파일은 남습니다." : "파일 변경 감지 · 예약 백업 · 로컬 / 네트워크 / 클라우드\r\n현재 사용자 계정에 설치하며 관리자 권한은 필요하지 않습니다.",
            Location = new Point(30, 77), Size = new Size(580, 54)
        };
        var locationLabel = new Label { Text = remove ? "제거할 프로그램 위치" : "설치 위치", Location = new Point(30, 148), Size = new Size(580, 24) };
        var location = new TextBox { Text = InstallerCore.DefaultRoot, Location = new Point(30, 177), Size = new Size(578, 28), ReadOnly = true, BorderStyle = BorderStyle.FixedSingle };
        DesktopBox = new CheckBox { Text = "바탕 화면에 바로 가기 만들기", Location = new Point(30, 222), Size = new Size(560, 26), Visible = !remove };
        LaunchBox = new CheckBox { Text = "설치 완료 후 알림 영역에서 SafeSync 실행", Location = new Point(30, 255), Size = new Size(560, 26), Checked = true, Visible = !remove };
        if (remove) Controls.Add(new Label { Text = "실행 중이라면 알림 영역에서 ‘프로그램 종료’를 먼저 선택해 주세요.\r\n진행 중인 백업이 있으면 완료된 뒤에 제거할 수 있습니다.", Location = new Point(30, 222), Size = new Size(580, 62) });
        status = new Label { Text = remove ? "제거 후 다시 설치하면 기존 설정을 사용할 수 있습니다." : "기존 설정은 유지됩니다. 실행 시 창 대신 알림 영역에 표시됩니다.", Location = new Point(30, 303), Size = new Size(580, 43), ForeColor = Color.DimGray };
        progress = new ProgressBar { Location = new Point(30, 352), Size = new Size(580, 8), Visible = false };
        ActionButton = new Button { Text = remove ? "제거" : "설치", Location = new Point(399, 379), Size = new Size(102, 34) };
        cancel = new Button { Text = "취소", Location = new Point(511, 379), Size = new Size(99, 34) };
        cancel.Click += delegate { Close(); };
        ActionButton.Click += delegate {
            if (completed) { Close(); return; }
            working = true; ActionButton.Enabled = false; cancel.Enabled = false;
            DesktopBox.Enabled = false; LaunchBox.Enabled = false; progress.Visible = true;
            progress.Style = ProgressBarStyle.Marquee;
            try { action(this); }
            catch (Exception ex) {
                SetStatus(ex.Message); MessageBox.Show(this, ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                DesktopBox.Enabled = true; LaunchBox.Enabled = true;
            }
            finally { working = false; ActionButton.Enabled = true; cancel.Enabled = true; progress.Visible = false; }
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (working) e.Cancel = true; };
        AcceptButton = ActionButton; CancelButton = cancel;
        Controls.AddRange(new Control[] { title, description, locationLabel, location, DesktopBox, LaunchBox, status, progress, ActionButton, cancel });
    }
    internal void SetStatus(string message) { status.Text = message; status.Refresh(); }
    internal void Complete(string message)
    {
        completed = true; SetStatus(message); ActionButton.Text = "닫기"; cancel.Visible = false;
        DesktopBox.Enabled = false; LaunchBox.Enabled = false;
    }
}
