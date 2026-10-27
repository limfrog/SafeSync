using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SafeSync.Core;

public sealed record UsnCheckpoint(string Root,long RootId,ulong JournalId,long Cursor);
public sealed record OfflineChanges(UsnCheckpoint? Checkpoint,bool RequiresScan,IReadOnlyList<string> Paths);

// Read-only optimization. Unsupported filesystems, permissions, record versions,
// journal gaps and unresolved deleted ancestors all fall back to metadata scans.
public static class OfflineJournal
{
    [StructLayout(LayoutKind.Sequential)] private struct JournalData {public ulong Id;public long First,Next,Lowest,Maximum;public ulong Size,Delta;}
    [StructLayout(LayoutKind.Sequential)] private struct ReadData {public long Start;public uint Reasons,Close;public ulong Timeout,Wait,Id;}
    [StructLayout(LayoutKind.Sequential)] private struct FileId {public uint Size,Type;public ulong Id;public ulong Padding;}
    [StructLayout(LayoutKind.Sequential)] private struct FileInfoData {public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;public uint Volume,High,Low,Links,IndexHigh,IndexLow;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool DeviceIoControl(SafeFileHandle handle,uint code,IntPtr input,int inputSize,IntPtr output,int outputSize,out int returned,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInfoData info);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern SafeFileHandle OpenFileById(SafeFileHandle volume,ref FileId id,uint access,uint share,IntPtr security,uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint size,uint flags);
    public static long FileIdentity(string root)
    {
        using var handle=CreateFile(root,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
        return !handle.IsInvalid && GetFileInformationByHandle(handle,out var info) ? unchecked(((long)info.IndexHigh<<32)|info.IndexLow) : 0;
    }
    public static string RootIdentity(string root)
    {
        using var handle=CreateFile(root,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
        // Samba may expose POSIX ctime as Windows CreationTime; adding a child
        // then changes it. Use the filesystem identity, not that mutable time.
        return !handle.IsInvalid && GetFileInformationByHandle(handle,out var info) && (info.IndexHigh!=0 || info.IndexLow!=0)
            ? $"volume:{info.Volume}:id:{info.IndexHigh}:{info.IndexLow}"
            : "created:"+Directory.GetCreationTimeUtc(root).Ticks;
    }
    // Unlike the optional journal optimization, destructive decisions must not
    // fall back to a fabricated timestamp when opening the directory fails.
    public static string RequiredRootIdentity(string root)
    {
        PathPolicy.RejectLinks(root,root);
        using var handle=CreateFile(root,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
        if(handle.IsInvalid || !GetFileInformationByHandle(handle,out var info))
            throw new IOException("백업 폴더의 연결 및 식별 정보를 확인할 수 없습니다.",new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
        if((info.Attributes&0x10)==0)throw new IOException("백업 위치가 폴더가 아닙니다.");
        if((info.Attributes&0x400)!=0)throw new IOException("연결 지점은 백업 루트로 사용하지 않습니다.");
        return info.IndexHigh!=0 || info.IndexLow!=0
            ? $"volume:{info.Volume}:id:{info.IndexHigh}:{info.IndexLow}"
            : $"volume:{info.Volume}:created:{info.Created.dwHighDateTime}:{info.Created.dwLowDateTime}";
    }
    private static string? Resolve(SafeFileHandle volume,long id)
    {
        var descriptor=new FileId {Size=(uint)Marshal.SizeOf<FileId>(),Id=unchecked((ulong)id)};
        using var file=OpenFileById(volume,ref descriptor,0x80,7,IntPtr.Zero,0x02000000);
        if(file.IsInvalid)return null;var buffer=new StringBuilder(32768);uint length=GetFinalPathNameByHandle(file,buffer,(uint)buffer.Capacity,0);
        if(length==0 || length>=buffer.Capacity)return null;
        var path=buffer.ToString();return path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase) ? @"\\"+path[8..] : path.StartsWith(@"\\?\") ? path[4..] : path;
    }
    public static bool Valid(UsnCheckpoint previous,string root,long rootId,ulong journal,long first,long next)=>
        previous.Root.Equals(root,StringComparison.OrdinalIgnoreCase) && rootId!=0 && previous.RootId==rootId && previous.JournalId==journal && previous.Cursor>=first && previous.Cursor<=next;
    public static IReadOnlyDictionary<long,string[]> TrackedIds(IEnumerable<FileEntry> files,bool backup=false)=>files.Where(f=>(backup ? f.BackupFileId : f.SourceFileId)!=0).GroupBy(f=>backup ? f.BackupFileId : f.SourceFileId).ToDictionary(g=>g.Key,g=>g.Select(f=>f.RelativePath).ToArray());
    public static OfflineChanges Read(string root,UsnCheckpoint? previous,CancellationToken token=default,IReadOnlyDictionary<long,string[]>? tracked=null)
    {
        using var timing=OperationLog.Measure("prepare.offline_journal");
        root=PathPolicy.Root(root);var volumeRoot=Path.GetPathRoot(root);
        if(!OperatingSystem.IsWindows() || volumeRoot==null || volumeRoot.Length!=3 || volumeRoot[1]!=':')return new(null,true,[]);
        // A metadata-only (zero-access) handle can open successfully while NTFS
        // rejects FSCTL_QUERY_USN_JOURNAL with ERROR_INVALID_FUNCTION. Request
        // read access, never write access or an elevation prompt. If the current
        // account cannot open that handle, retain the metadata-only compatibility
        // path; failure still means a safe scan, not an empty change set.
        using var volume=OpenJournalVolume(volumeRoot);
        if(volume.IsInvalid)return new(null,true,[]);
        int outputSize=1024*1024;var output=Marshal.AllocHGlobal(outputSize);var input=Marshal.AllocHGlobal(Marshal.SizeOf<ReadData>());
        try
        {
            if(!DeviceIoControl(volume,0x000900f4,IntPtr.Zero,0,output,outputSize,out var returned,IntPtr.Zero) || returned<Marshal.SizeOf<JournalData>())return new(null,true,[]);
            var journal=Marshal.PtrToStructure<JournalData>(output);long identity=FileIdentity(root);
            var checkpoint=new UsnCheckpoint(root,identity,journal.Id,journal.Next);
            if(previous==null || !Valid(previous,root,identity,journal.Id,journal.First,journal.Next))return new(checkpoint,true,[]);
            long cursor=previous.Cursor;var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var parents=new Dictionary<long,string?>();int passes=0;
            while(cursor<journal.Next)
            {
                token.ThrowIfCancellationRequested();if(++passes>4096)return new(checkpoint,true,[]);
                var request=new ReadData {Start=cursor,Reasons=uint.MaxValue,Id=journal.Id};Marshal.StructureToPtr(request,input,false);
                if(!DeviceIoControl(volume,0x000900bb,input,Marshal.SizeOf<ReadData>(),output,outputSize,out returned,IntPtr.Zero))return new(checkpoint,true,[]);
                if(returned<8)return new(checkpoint,true,[]);long next=Marshal.ReadInt64(output);if(next<=cursor)return new(checkpoint,true,[]);
                int offset=8;
                while(offset<returned)
                {
                    if(offset+60>returned)return new(checkpoint,true,[]);var record=IntPtr.Add(output,offset);int size=Marshal.ReadInt32(record);ushort version=(ushort)Marshal.ReadInt16(record,4);
                    if(version!=2 || size<60 || offset+size>returned)return new(checkpoint,true,[]);
                    long usn=Marshal.ReadInt64(record,24);if(usn>=journal.Next)break;
                    // A write through a hard link outside this root still changes
                    // every tracked alias inside it. Preserve all aliases by ID.
                    long fileId=Marshal.ReadInt64(record,8);
                    if(tracked!=null && tracked.TryGetValue(fileId,out var aliases))foreach(var alias in aliases)paths.Add(PathPolicy.Relative(alias));
                    long parent=Marshal.ReadInt64(record,16);int nameLength=(ushort)Marshal.ReadInt16(record,56),nameOffset=(ushort)Marshal.ReadInt16(record,58);
                    if(nameLength==0 || nameLength%2!=0 || nameOffset<60 || nameOffset+nameLength>size)return new(checkpoint,true,[]);
                    if(!parents.TryGetValue(parent,out var parentPath)){parentPath=Resolve(volume,parent);parents[parent]=parentPath;}
                    if(parentPath==null)return new(checkpoint,true,[]);
                    var name=Marshal.PtrToStringUni(IntPtr.Add(record,nameOffset),nameLength/2)!;
                    var path=Path.Combine(parentPath,name);
                    if(path.Equals(root,StringComparison.OrdinalIgnoreCase))return new(checkpoint,true,[]);
                    if(PathPolicy.Inside(root,path))
                    {
                        var relative=PathPolicy.Relative(Path.GetRelativePath(root,path));if(!PathPolicy.Internal(relative))paths.Add(relative);
                    }
                    offset+=size;
                }
                cursor=next;
            }
            return new(checkpoint,false,paths.ToArray());
        }
        finally{Marshal.FreeHGlobal(input);Marshal.FreeHGlobal(output);}
    }
    private static SafeFileHandle OpenJournalVolume(string volumeRoot)
    {
        var name=@"\\.\"+volumeRoot[..2];
        var handle=CreateFile(name,0x80000000,7,IntPtr.Zero,3,0,IntPtr.Zero);
        if(!handle.IsInvalid)return handle;
        handle.Dispose();
        return CreateFile(name,0,7,IntPtr.Zero,3,0,IntPtr.Zero);
    }
}
