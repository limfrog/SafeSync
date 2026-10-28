using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

internal static class NativeSetupTests
{
    private static int count;
    private static void Check(bool value,string message){if(!value)throw new Exception(message);count++;}
    private static void Reject(Action action,string message){bool failed=false;try{action();}catch(IOException){failed=true;}catch(InvalidDataException){failed=true;}Check(failed,message);}
    private static MemoryStream Package(string version,out string manifest)
    {
        var files=new Dictionary<string,string>{{"SafeSync.exe",version},{"Uninstall.exe","uninstall-"+version},{"runtime/shared/desktop.dll","runtime-"+version}};
        var text=new StringBuilder();var stream=new MemoryStream();
        using(var zip=new ZipArchive(stream,ZipArchiveMode.Create,true))foreach(var file in files)
        {
            byte[] bytes=Encoding.UTF8.GetBytes(file.Value);using(var sha=SHA256.Create())text.Append(BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant()+"  "+file.Key+"\n");
            using(var entry=zip.CreateEntry(file.Key).Open())entry.Write(bytes,0,bytes.Length);
        }
        manifest=text.ToString();stream.Position=0;return stream;
    }
    private static void Install(string root,string version,Action<string> boundary)
    {string manifest;using(var package=Package(version,out manifest))NativeSetupCore.Install(package,manifest,root,true,version,delegate{},boundary);}
    private static int Main(string[] args)
    {
        AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling",false);
        AppContext.SetSwitch("Switch.System.IO.BlockLongPaths",false);
        try
        {
            if(args.Length==4 && args[0]=="/package")
            {
                string app=Path.Combine(args[1],"installed-package");File.WriteAllText(Path.Combine(args[1],".safesync2-test-sandbox"),"test");
                using(var payload=File.OpenRead(args[2]))NativeSetupCore.Install(payload,File.ReadAllText(args[3]),app,true,"preview.8",delegate{},null);
                foreach(var file in NativeSetupCore.ReadHashes(File.ReadAllText(args[3])))Check(NativeSetupCore.Hash(Path.Combine(app,file.Key))==file.Value,"Installed runtime file differs from package");
                Console.WriteLine("PASS: "+count+" installed payload hashes. "+app);return 0;
            }
            if(args.Length==2 && args[0]=="/remove-test")
            {
                NativeSetupCore.Remove(args[1],true);Check(!File.Exists(Path.Combine(args[1],"SafeSync.exe")),"Installed package not removed");return 0;
            }
            if(args.Length==3 && args[0]=="/crash")
            {
                Install(args[1],"interrupted",delegate(string phase){if(phase==args[2]){File.WriteAllText(Path.Combine(Path.GetDirectoryName(args[1]),"ready"),phase);Thread.Sleep(Timeout.Infinite);}});return 3;
            }
            if(args.Length!=1)return 2;
            Check(NativeSetupCore.DisplayName=="SafeSync" && Path.GetFileName(NativeSetupCore.DefaultRoot)=="SafeSync2","Public name changed compatibility storage/install paths.");
            string home=Path.Combine(Path.GetFullPath(args[0]),"setup-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(home);File.WriteAllText(Path.Combine(home,".safesync2-test-sandbox"),"test");
            string root=Path.Combine(home,"app"),data=Path.Combine(home,"user-data");Directory.CreateDirectory(data);File.WriteAllText(Path.Combine(data,"config.json"),"keep-settings");
            string verifyManifest;
            using(var payload=Package("verified",out verifyManifest))NativeSetupCore.Verify(payload,verifyManifest,home);
            Check(Directory.GetDirectories(home,"SafeSync2.verify-*").Length==0,"Successful verification left temporary payload");
            using(var payload=Package("corrupt",out verifyManifest))
            {verifyManifest=verifyManifest.Replace(verifyManifest.Substring(0,64),new string('0',64));Reject(delegate{NativeSetupCore.Verify(payload,verifyManifest,home);},"Verification accepted corrupt payload");}
            Check(Directory.GetDirectories(home,"SafeSync2.verify-*").Length==0 && File.ReadAllText(Path.Combine(data,"config.json"))=="keep-settings","Failed verification cleanup leaked payload or touched unrelated data");
            Install(root,"one",null);Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="one","First install failed");
            Directory.CreateDirectory(Path.Combine(root,"user-added"));File.WriteAllText(Path.Combine(root,"user-added","notes.txt"),"preserve");
            Install(root,"two",null);Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="two","Upgrade failed");
            Check(File.ReadAllText(Path.Combine(root,"user-added","notes.txt"))=="preserve","Upgrade discarded unknown file");
            foreach(string phase in new[]{"old-moved","published"})
            {
                Reject(delegate{Install(root,"bad",delegate(string boundary){if(boundary==phase)throw new IOException("injected failure");});},"Injected install failure ignored");
                Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="two","Upgrade exception failed rollback: "+phase);
                // Real child-process termination at each transaction boundary.
                string ready=Path.Combine(home,"ready");if(File.Exists(ready))File.Delete(ready);
                using(var process=Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"/crash \""+root+"\" "+phase){UseShellExecute=false,CreateNoWindow=true}))
                {
                    var watch=Stopwatch.StartNew();while(!File.Exists(ready)&&!process.HasExited&&watch.ElapsedMilliseconds<15000)Thread.Sleep(30);
                    Check(File.Exists(ready),"Installer crash fixture did not reach boundary");process.Kill();Check(process.WaitForExit(10000),"Crash process not terminated");
                }
                NativeSetupCore.Recover(root);Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="two","Process-kill rollback failed: "+phase);
                Check(File.ReadAllText(Path.Combine(root,"user-added","notes.txt"))=="preserve","Process-kill lost unknown file");
            }
            foreach(string name in new[]{"../outside","/absolute","a/../b","runtime//file","C:/outside","runtime/file:stream","a\\b","a./b"})Reject(delegate{NativeSetupCore.Name(name);},"Unsafe install path accepted");
            string manifest;using(var payload=Package("corrupted",out manifest))
            {manifest=manifest.Replace(manifest.Substring(0,64),new string('0',64));Reject(delegate{NativeSetupCore.Install(payload,manifest,root,true,"bad",delegate{},null);},"Corrupt payload accepted");}
            Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="two","Corrupt update changed installed files");
            NativeSetupCore.Remove(root,true);Check(!File.Exists(Path.Combine(root,"SafeSync.exe")),"Uninstall left executable");
            Check(File.ReadAllText(Path.Combine(root,"user-added","notes.txt"))=="preserve" && File.ReadAllText(Path.Combine(data,"config.json"))=="keep-settings","Uninstall removed user data");
            Install(root,"reinstalled",null);Check(File.ReadAllText(Path.Combine(root,"SafeSync.exe"))=="reinstalled","Reinstall after removal failed");
            File.Delete(Path.Combine(root,"runtime","shared","desktop.dll"));
            Install(root,"repaired",null);Check(File.ReadAllText(Path.Combine(root,"runtime","shared","desktop.dll"))=="runtime-repaired","Interrupted removal could not be repaired");
            string foreign=Path.Combine(home,"foreign");Directory.CreateDirectory(foreign);File.WriteAllText(Path.Combine(foreign,"important.txt"),"keep");
            Reject(delegate{Install(foreign,"bad",null);},"Unowned install folder overwritten");Reject(delegate{NativeSetupCore.Remove(foreign,true);},"Unowned folder removed");
            string empty=Path.Combine(home,"empty");Directory.CreateDirectory(empty);
            Reject(delegate{Install(empty,"bad",delegate(string phase){if(phase=="published")throw new IOException("first install failure");});},"First install error ignored");
            Check(!Directory.Exists(empty),"First install rollback left partially installed app");
            Console.WriteLine("PASS: "+count+" native installer assertions. "+home);return 0;
        }
        catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }
}
