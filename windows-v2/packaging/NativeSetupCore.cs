// Deliberately C# 5/.NET Framework compatible: the bootstrapper must run before
// the bundled .NET desktop runtime is installed. No PowerShell is launched.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

internal static class NativeSetupCore
{
    internal const string Product="SafeSync.Native.2";
    internal const string DisplayName="SafeSync";
    internal const string Marker=".safesync2-install";
    internal const string Inventory="installed-files.sha256";
    internal static string DefaultRoot {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","SafeSync2");}}
    internal static string Canonical(string path)
    {
        if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))path=@"\\"+path.Substring(8);
        else if(path.StartsWith(@"\\?\",StringComparison.Ordinal))path=path.Substring(4);
        return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
    }
    private static string Long(string path){path=Canonical(path);if(path.Length==2&&path[1]==':')path+="\\";return path.StartsWith(@"\\",StringComparison.Ordinal) ? @"\\?\UNC\"+path.Substring(2) : @"\\?\"+path;}
    internal static bool Same(string left,string right){return String.Equals(Canonical(left),Canonical(right),StringComparison.OrdinalIgnoreCase);}
    internal static void NoLinks(string path)
    {
        for(string current=Canonical(path);!String.IsNullOrEmpty(current);current=Path.GetDirectoryName(current))
            if((Directory.Exists(Long(current))||File.Exists(Long(current))) && (File.GetAttributes(Long(current))&FileAttributes.ReparsePoint)!=0)throw new IOException("설치 경로에 연결 폴더가 있습니다.");
    }
    internal static void ValidateRoot(string root,bool test)
    {
        root=Canonical(root);
        if(!test && !Same(root,DefaultRoot))throw new IOException("허용하지 않은 설치 위치입니다.");
        if(test && !File.Exists(Path.Combine(Path.GetDirectoryName(root),".safesync2-test-sandbox")))throw new IOException("격리된 설치 검사 폴더가 아닙니다.");
        if(Same(root,Path.GetPathRoot(root)) || Same(root,Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)))throw new IOException("안전하지 않은 설치 위치입니다.");
        NoLinks(root);
    }
    internal static string Name(string value)
    {
        if(String.IsNullOrWhiteSpace(value)||value.Contains('\\')||value.Contains(':')||value.StartsWith("/")||value.Split('/').Any(p=>p==""||p=="."||p==".."||p.EndsWith(".")||p.EndsWith(" ")||p.IndexOfAny(Path.GetInvalidFileNameChars())>=0))throw new InvalidDataException("잘못된 패키지 경로입니다.");
        if(value.Equals(Marker,StringComparison.OrdinalIgnoreCase)||value.Equals(Inventory,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("예약된 패키지 경로입니다.");
        return value;
    }
    private static string Combine(string root,string name)
    {
        string path=Path.GetFullPath(Path.Combine(root,Name(name).Replace('/',Path.DirectorySeparatorChar)));
        if(!path.StartsWith(Canonical(root)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("설치 범위 이탈입니다.");
        NoLinks(path);return Long(path);
    }
    internal static string Hash(string path){using(var stream=File.OpenRead(Long(path)))using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant();}
    internal static Dictionary<string,string> ReadHashes(string text)
    {
        var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(string line in text.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries))
        {
            if(line.Length<67||line.Substring(64,2)!="  "||line.Take(64).Any(c=>!Uri.IsHexDigit(c)))throw new InvalidDataException("파일 검증 목록이 잘못되었습니다.");
            string name=Name(line.Substring(66));if(result.ContainsKey(name))throw new InvalidDataException("중복 패키지 파일입니다.");result.Add(name,line.Substring(0,64).ToLowerInvariant());
        }
        if(!result.ContainsKey("SafeSync.exe")||!result.ContainsKey("Uninstall.exe")||result.Count>4000)throw new InvalidDataException("필수 설치 파일이 없습니다.");
        return result;
    }
    private static void AtomicWrite(string path,string value)
    {
        string temporary=Path.Combine(Path.GetDirectoryName(path),".write-"+Guid.NewGuid().ToString("N"));
        try
        {
            using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None))using(var writer=new StreamWriter(stream,new UTF8Encoding(false)))
            {writer.Write(value);writer.Flush();stream.Flush(true);}
            if(File.Exists(path))File.Replace(temporary,path,null);else File.Move(temporary,path);
        }
        finally{if(File.Exists(temporary))File.Delete(temporary);}
    }
    internal static bool Owned(string root)
    {return OwnedAt(root,root);}
    private static bool OwnedAt(string folder,string root)
    {
        string path=Path.Combine(folder,Marker);NoLinks(path);if(!File.Exists(path))return false;
        var lines=File.ReadAllLines(path);return lines.Length==3 && lines[0]==Product && Same(lines[1],root);
    }
    internal static void Extract(Stream zip,string manifest,string stage)
    {
        var hashes=ReadHashes(manifest);Directory.CreateDirectory(stage);var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using(var archive=new ZipArchive(zip,ZipArchiveMode.Read,true))
        {
            long total=0;
            foreach(var entry in archive.Entries)
            {
                string name=Name(entry.FullName);
                if(!hashes.ContainsKey(name)||!seen.Add(name)||entry.Length>256L*1024*1024||(total+=entry.Length)>1024L*1024*1024)throw new InvalidDataException("패키지 파일명/크기 오류입니다.");
                string target=Combine(stage,name);Directory.CreateDirectory(Path.GetDirectoryName(target));
                using(var input=entry.Open())using(var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write,FileShare.None))
                {
                    byte[] buffer=new byte[65536];long copied=0;int count;
                    while((count=input.Read(buffer,0,buffer.Length))>0){copied+=count;if(copied>entry.Length)throw new InvalidDataException("압축 파일 크기 오류입니다.");output.Write(buffer,0,count);}
                    if(copied!=entry.Length)throw new InvalidDataException("불완전한 설치 파일입니다.");output.Flush(true);
                }
                if(Hash(target)!=hashes[name])throw new InvalidDataException("설치 파일의 체크섬이 다릅니다: "+name);
            }
        }
        if(seen.Count!=hashes.Count)throw new InvalidDataException("패키지 파일이 누락되었습니다.");
        AtomicWrite(Path.Combine(stage,Inventory),manifest);
    }
    private static string Journal(string root){return Path.Combine(Path.GetDirectoryName(root),"SafeSync2.install-transaction.txt");}
    private static void CheckTree(string folder)
    {NoLinks(folder);foreach(string child in Directory.GetFileSystemEntries(Long(folder))){NoLinks(child);if(Directory.Exists(child))CheckTree(child);}}
    private static void DeleteWork(string folder,string root,string kind)
    {
        if(!Same(Path.GetDirectoryName(folder),Path.GetDirectoryName(root))||!Path.GetFileName(folder).StartsWith("SafeSync2."+kind+"-",StringComparison.Ordinal))throw new IOException("설치 복구 경로 오류입니다.");
        if(Directory.Exists(folder)){CheckTree(folder);Directory.Delete(Long(folder),true);}
    }
    internal static void Recover(string root)
    {
        string journal=Journal(root);NoLinks(journal);if(!File.Exists(journal))return;
        var lines=File.ReadAllLines(journal);
        if(lines.Length!=5||lines[0]!=Product||!Same(lines[1],root)||(lines[4]!="pending"&&lines[4]!="committed"))throw new IOException("설치 복구 기록이 손상되었습니다. 파일을 보존했습니다.");
        string stage=lines[2],previous=lines[3];
        foreach(var pair in new[]{new[]{stage,"install"},new[]{previous,"previous"}})
            if(!Same(Path.GetDirectoryName(pair[0]),Path.GetDirectoryName(root))||!Path.GetFileName(pair[0]).StartsWith("SafeSync2."+pair[1]+"-",StringComparison.Ordinal))throw new IOException("설치 복구 범위가 잘못되었습니다.");
        NoLinks(stage);NoLinks(previous);
        if(lines[4]=="pending")
        {
            if(Directory.Exists(previous))
            {
                if(!OwnedAt(previous,root))throw new IOException("이전 설치본을 확인할 수 없습니다.");
                if(Directory.Exists(root)){if(!Owned(root)||Directory.Exists(stage))throw new IOException("설치 폴더가 변경되었습니다.");Directory.Move(root,stage);}
                Directory.Move(previous,root);
            }
            else if(!Directory.Exists(stage)&&Directory.Exists(root))
            {if(!Owned(root))throw new IOException("설치 폴더가 변경되었습니다.");Directory.Move(root,stage);}
            DeleteWork(stage,root,"install");
        }
        else DeleteWork(previous,root,"previous");
        File.Delete(journal);
    }
    private static void PreserveUnknown(string old,string stage,Dictionary<string,string> owned)
    {
        CheckTree(old);
        foreach(string file in Directory.GetFiles(Long(old),"*",SearchOption.AllDirectories))
        {
            string relative=Canonical(file).Substring(Canonical(old).Length+1).Replace('\\','/');
            if(relative==Marker||relative==Inventory||owned.ContainsKey(relative))continue;
            string target=Combine(stage,relative);Directory.CreateDirectory(Path.GetDirectoryName(target));File.Copy(file,target,false);
            if(Hash(file)!=Hash(target))throw new IOException("사용자 추가 파일 보존에 실패했습니다.");
        }
    }
    internal static void Install(Stream zip,string manifest,string root,bool test,string version,Action<string> status,Action<string> boundary)
    {
        root=Canonical(root);ValidateRoot(root,test);Directory.CreateDirectory(Path.GetDirectoryName(root));Recover(root);
        if(Directory.Exists(root)&&Directory.GetFileSystemEntries(root).Length>0&&!Owned(root))throw new IOException("설치 위치에 다른 파일이 있습니다. 삭제하지 않았습니다.");
        string stage=Path.Combine(Path.GetDirectoryName(root),"SafeSync2.install-"+Guid.NewGuid().ToString("N"));
        string previous=Path.Combine(Path.GetDirectoryName(root),"SafeSync2.previous-"+Guid.NewGuid().ToString("N"));bool recorded=false;
        try
        {
            status("설치 파일과 체크섬을 확인하고 있습니다…");Extract(zip,manifest,stage);
            if(Owned(root))PreserveUnknown(root,stage,ReadHashes(File.ReadAllText(Path.Combine(root,Inventory))));
            AtomicWrite(Path.Combine(stage,Marker),String.Join(Environment.NewLine,new[]{Product,root,version}));
            AtomicWrite(Journal(root),String.Join(Environment.NewLine,new[]{Product,root,stage,previous,"pending"}));recorded=true;
            status("프로그램 파일을 안전하게 교체하고 있습니다…");
            if(Owned(root))Directory.Move(root,previous);else if(Directory.Exists(root))Directory.Delete(root,false);
            if(boundary!=null)boundary("old-moved");
            Directory.Move(stage,root);if(boundary!=null)boundary("published");
            AtomicWrite(Journal(root),String.Join(Environment.NewLine,new[]{Product,root,stage,previous,"committed"}));
        }
        catch{if(recorded)Recover(root);else DeleteWork(stage,root,"install");throw;}
        try{Recover(root);}catch(IOException){status("설치는 완료됐습니다. 이전 파일은 다음 설치 시 정리됩니다.");}
    }
    internal static void Remove(string root,bool test)
    {
        root=Canonical(root);ValidateRoot(root,test);Recover(root);if(!Owned(root))throw new IOException("설치 표시를 확인할 수 없어 제거하지 않았습니다.");
        var hashes=ReadHashes(File.ReadAllText(Path.Combine(root,Inventory)));
        CheckTree(root);
        // Validate every target before deleting anything. Unknown/user data is
        // never in this inventory and remains untouched, even under app root.
        foreach(string name in hashes.Keys)Combine(root,name);
        foreach(string name in hashes.Keys){string path=Combine(root,name);if(File.Exists(path))File.Delete(path);}
        // Keep the tiny ownership receipt + inventory. A power loss at any
        // point during uninstall can then be repaired by reinstalling, without
        // mistaking leftover binaries/user files for an unowned directory.
        PruneEmpty(root);
    }
    private static void PruneEmpty(string folder)
    {
        foreach(string child in Directory.GetDirectories(Long(folder))){NoLinks(child);PruneEmpty(child);}
        if(!Directory.EnumerateFileSystemEntries(Long(folder)).Any())Directory.Delete(Long(folder),false);
    }
    internal static bool Running(){Mutex mutex;if(!Mutex.TryOpenExisting(@"Local\SafeSync2.Preview",out mutex))return false;mutex.Dispose();return true;}
}
