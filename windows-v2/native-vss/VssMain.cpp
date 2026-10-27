#define UNICODE
#define _UNICODE
#include <windows.h>
#include <vss.h>
#include <vswriter.h>
#include <vsbackup.h>
#include <iostream>
#include <string>

static void check(HRESULT hr) { if (FAILED(hr)) throw hr; }
static void wait(IVssAsync* task) {
    if (!task) throw E_POINTER;
    HRESULT result = E_FAIL; HRESULT waited = task->Wait(120000);
    if (SUCCEEDED(waited)) waited = task->QueryStatus(&result, nullptr);
    if (FAILED(waited) || result == VSS_S_ASYNC_PENDING) task->Cancel();
    task->Release(); check(waited); if (result == VSS_S_ASYNC_PENDING) throw HRESULT_FROM_WIN32(WAIT_TIMEOUT); check(result);
}
static void privilege(const wchar_t* name) {
    HANDLE token = nullptr; if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) throw HRESULT_FROM_WIN32(GetLastError());
    TOKEN_PRIVILEGES state = {}; state.PrivilegeCount = 1;
    if (!LookupPrivilegeValue(nullptr, name, &state.Privileges[0].Luid)) { CloseHandle(token); throw HRESULT_FROM_WIN32(GetLastError()); }
    state.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED; SetLastError(ERROR_SUCCESS);
    BOOL okay = AdjustTokenPrivileges(token, FALSE, &state, 0, nullptr, nullptr); DWORD error = GetLastError(); CloseHandle(token);
    if (!okay || error != ERROR_SUCCESS) throw HRESULT_FROM_WIN32(error);
}
int wmain(int argc, wchar_t** argv) {
    IVssBackupComponents* backup = nullptr; VSS_ID set = GUID_NULL, id = GUID_NULL;
    VSS_SNAPSHOT_PROP property = {}; bool ready = false, initialized = false; HRESULT failure = S_OK;
    try {
        if (argc != 2 || wcslen(argv[1]) != 3 || argv[1][1] != L':' || argv[1][2] != L'\\') throw E_INVALIDARG;
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); initialized = true;
        check(CoInitializeSecurity(nullptr, -1, nullptr, nullptr, RPC_C_AUTHN_LEVEL_PKT_PRIVACY, RPC_C_IMP_LEVEL_IMPERSONATE, nullptr, EOAC_NONE, nullptr));
        privilege(SE_BACKUP_NAME); privilege(SE_RESTORE_NAME);
        wchar_t volume[MAX_PATH] = {}; if (!GetVolumeNameForVolumeMountPoint(argv[1], volume, MAX_PATH)) throw HRESULT_FROM_WIN32(GetLastError());
        check(CreateVssBackupComponents(&backup)); check(backup->InitializeForBackup()); check(backup->SetContext(VSS_CTX_BACKUP));
        // Copy backup does not truncate application logs or alter full-backup chains.
        check(backup->SetBackupState(FALSE, FALSE, VSS_BT_COPY, FALSE));
        IVssAsync* task = nullptr; check(backup->GatherWriterMetadata(&task)); wait(task);
        check(backup->StartSnapshotSet(&set)); check(backup->AddToSnapshotSet(volume, GUID_NULL, &id));
        task = nullptr; check(backup->PrepareForBackup(&task)); wait(task);
        task = nullptr; check(backup->DoSnapshotSet(&task)); wait(task);
        task = nullptr; check(backup->GatherWriterStatus(&task)); wait(task);
        UINT writers = 0; check(backup->GetWriterStatusCount(&writers));
        for (UINT i = 0; i < writers; ++i) {
            VSS_ID instance, writer; BSTR name = nullptr; VSS_WRITER_STATE state; HRESULT result;
            HRESULT status = backup->GetWriterStatus(i, &instance, &writer, &name, &state, &result); SysFreeString(name); check(status); check(result);
            if (state >= VSS_WS_FAILED_AT_IDENTIFY) throw VSS_E_WRITERERROR_NONRETRYABLE;
        }
        backup->FreeWriterStatus(); check(backup->GetSnapshotProperties(id, &property)); ready = true;
        wchar_t text[40] = {}; StringFromGUID2(id, text, 40);
        std::wcout << L"READY|" << text << L"|" << property.m_pwszSnapshotDeviceObject << std::endl;
        // Parent owns stdin. EOF on app exit/crash releases this snapshot as well.
        std::string command; std::getline(std::cin, command);
        task = nullptr; check(backup->BackupComplete(&task)); wait(task);
    } catch (HRESULT hr) { failure = hr; std::wcerr << L"VSS HRESULT 0x" << std::hex << static_cast<unsigned long>(hr) << std::endl; }
    if (backup) {
        if (!ready) backup->AbortBackup();
        if (set != GUID_NULL) { LONG deleted = 0; VSS_ID remaining = GUID_NULL; HRESULT cleaned = backup->DeleteSnapshots(set, VSS_OBJECT_SNAPSHOT_SET, TRUE, &deleted, &remaining); if (FAILED(cleaned) && SUCCEEDED(failure)) failure = cleaned; }
        VssFreeSnapshotProperties(&property); backup->FreeWriterMetadata(); backup->Release();
    }
    if (initialized) CoUninitialize();
    return FAILED(failure) ? 1 : 0;
}
