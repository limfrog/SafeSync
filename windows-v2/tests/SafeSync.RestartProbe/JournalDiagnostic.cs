using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using SafeSync.Core;

// Read-only test diagnostics. Never changes the production journal reader or its access rights.
internal static class JournalDiagnostic
{
    [StructLayout(LayoutKind.Sequential)] private struct ReadData
    { public long Start; public uint Reasons, Close; public ulong Timeout, Wait, Id; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);

    public static object Read(string root, UsnCheckpoint? checkpoint)
    {
        var volume = Path.GetPathRoot(root);
        if (volume == null || volume.Length != 3 || volume[1] != ':') return new { SupportedLocalVolume = false, Root = root };
        return new
        {
            SupportedLocalVolume = true, Root = root, SavedCheckpoint = checkpoint,
            ProductionAccessZero = NativeRead(volume, checkpoint, 0),
            DiagnosticGenericRead = NativeRead(volume, checkpoint, 0x80000000)
        };
    }
    private static object NativeRead(string volume, UsnCheckpoint? checkpoint, uint access)
    {
        using var handle = CreateFile(@"\\.\" + volume[..2], access, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) return new { OpenError = Marshal.GetLastWin32Error() };
        var output = Marshal.AllocHGlobal(1024 * 1024); var input = Marshal.AllocHGlobal(Marshal.SizeOf<ReadData>());
        try
        {
            bool query = DeviceIoControl(handle, 0x000900f4, IntPtr.Zero, 0, output, 1024 * 1024, out int querySize, IntPtr.Zero);
            int queryError = query ? 0 : Marshal.GetLastWin32Error();
            ulong journal = query && querySize >= 8 ? unchecked((ulong)Marshal.ReadInt64(output)) : 0;
            long first = query && querySize >= 16 ? Marshal.ReadInt64(output, 8) : 0;
            long next = query && querySize >= 24 ? Marshal.ReadInt64(output, 16) : 0;
            if (!query) return new { QuerySucceeded = false, QueryError = queryError };
            Marshal.StructureToPtr(new ReadData { Start = checkpoint?.Cursor ?? first, Reasons = uint.MaxValue, Id = journal }, input, false);
            bool read = DeviceIoControl(handle, 0x000900bb, input, Marshal.SizeOf<ReadData>(), output, 1024 * 1024, out int readSize, IntPtr.Zero);
            int readError = read ? 0 : Marshal.GetLastWin32Error();
            return new { QuerySucceeded = true, JournalId = journal, First = first, Next = next, ReadSucceeded = read, ReadError = readError, BytesReturned = readSize, FirstRecordVersion = read && readSize >= 14 ? Marshal.ReadInt16(output, 12) : 0 };
        }
        finally { Marshal.FreeHGlobal(input); Marshal.FreeHGlobal(output); }
    }
}
