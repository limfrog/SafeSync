namespace SafeSync.Core;

public sealed class ActivityLog(string root)
{
    private readonly object gate=new();
    public void Append(string message)
    {
        lock(gate)
        {
            var folder=Path.Combine(root,"logs");Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder,"SafeSync-"+DateTime.Now.ToString("yyyy-MM")+".log"),DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+"  "+message+Environment.NewLine,System.Text.Encoding.UTF8);
        }
    }
}
