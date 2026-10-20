#!/usr/bin/env python3
"""Extract only the public Desktop client's registration; never log its values."""
import json
import plistlib
import sys
from pathlib import Path


def registration_from_document(document):
    installed = document.get("installed") if isinstance(document, dict) else None
    if not isinstance(installed, dict):
        raise ValueError("Use a Desktop OAuth JSON file, not a web client.")
    client_id = installed.get("client_id", "")
    client_secret = installed.get("client_secret", "")
    if not isinstance(client_id, str) or not client_id.strip().endswith(".apps.googleusercontent.com"):
        raise ValueError("Desktop client ID is missing or invalid.")
    if not isinstance(client_secret, str) or not client_secret.strip():
        raise ValueError("Desktop client secret is missing.")
    return {"clientID": client_id.strip(), "clientSecret": client_secret.strip()}


def main():
    try:
        values = registration_from_document(json.loads(Path(sys.argv[1]).read_text()))
        Path(sys.argv[2]).write_bytes(plistlib.dumps(values))
    except (ValueError, OSError, IndexError):
        # Input and parsing errors can include credential content; deliberately redact them.
        print("Could not package Google Desktop OAuth registration. Check the local OAuth JSON file.", file=sys.stderr)
        return 1
    print("Google Desktop OAuth registration packaged.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
