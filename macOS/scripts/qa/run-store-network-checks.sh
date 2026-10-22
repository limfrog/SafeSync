#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
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
