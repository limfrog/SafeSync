using System;
using System.IO;
using Microsoft.Win32;

namespace SafeSync.App;

internal static class AutoStart
{
    private const string ValueName="SafeSync2";
    internal static string Command(string executable)
    {
        if(!Path.IsPathFullyQualified(executable) || executable.Contains('"') || executable.IndexOfAny(Path.GetInvalidPathChars())>=0)throw new ArgumentException("자동 시작 실행 경로를 확인하세요.");
        return "\""+executable+"\"";
    }
    public static void Set(bool enabled,string executable)
    {
        var command=Command(executable);
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true);
        if(enabled)
        {
            key.SetValue(ValueName,command,RegistryValueKind.String);
            // Only the exact standard legacy launcher registration is migrated.
            // Unknown/manual commands and all other startup entries are preserved.
            var legacy=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","SafeSync","SafeSync.exe");
            var old=key.GetValue("SafeSync") as string;
            if(string.Equals(old,"\""+legacy+"\" -Minimized",StringComparison.OrdinalIgnoreCase) || string.Equals(old,"\""+legacy+"\"",StringComparison.OrdinalIgnoreCase))key.DeleteValue("SafeSync",false);
        }
        else key.DeleteValue(ValueName,false);
    }
}
