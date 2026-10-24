#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test "$(grep -Fc 'Button("업데이트 확인")' Sources/SafeSyncApp/SettingsView.swift)" = 1
if grep -Fq 'Button("다운로드 / 업데이트")' Sources/SafeSyncApp/SettingsView.swift; then echo 'Duplicate update entry'; exit 1; fi
grep -Fq 'FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-connection-diagnostic-' Sources/SafeSyncApp/CloudDiagnostics.swift
grep -Fq 'try await storage.remove(remoteFolder)' Sources/SafeSyncApp/CloudDiagnostics.swift
grep -Fq '검증용 클라우드 폴더와 파일을 모두 정리했습니다.' Sources/SafeSyncApp/CloudDiagnostics.swift
if grep -Fq 'Storage.applicationDirectory.appendingPathComponent("diagnostics/' Sources/SafeSyncApp/CloudDiagnostics.swift; then echo 'Cloud diagnostics source is inside the protected application data tree'; exit 1; fi
binary_directory="$(swift build --disable-sandbox --show-bin-path)"
qa="$(mktemp -d /private/tmp/safesync-store-qa.XXXXXX)"
export SAFESYNC_TEST_DATA_DIRECTORY="$qa/data"
mkdir -p "$SAFESYNC_TEST_DATA_DIRECTORY"
sources=()
for source in Sources/SafeSyncApp/*.swift; do
    if [[ "$source" != 'Sources/SafeSyncApp/SafeSyncApp.swift' ]]; then sources+=("$source"); fi
done
# Compile the original application with only its process entry point replaced.
# No scheduler/UI implementation is copied or mocked; only RemoteStorage is fake.
sed 's/^@main struct SafeSyncApp: App {/struct SafeSyncApp: App {/' Sources/SafeSyncApp/SafeSyncApp.swift > "$qa/AppEntry.swift"
swiftc -parse-as-library -D DEBUG -swift-version 5 -I "$binary_directory/Modules" \
    "${sources[@]}" "$qa/AppEntry.swift" scripts/qa/StoreNetworkChecks.swift Sources/SafeSyncChecks/CloudChecks.swift \
    "$binary_directory"/SafeSyncCore.build/*.o -o "$qa/checks"
"$qa/checks"
