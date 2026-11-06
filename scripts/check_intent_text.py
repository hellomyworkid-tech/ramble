#!/usr/bin/env python3
"""Stops an archive whose App Intent text names Apple.

App Store Connect turns such a build away with ITMS-90626, half an hour after the upload. This
looks at what the build really carries: every localizable string in its App Intents metadata, in
Chinese and through its English translation.
"""
import json
import pathlib
import re
import sys

archive = pathlib.Path(sys.argv[1])
metadata = archive / "Products/Applications/Ramble.app/Metadata.appintents/extract.actionsdata"
translations = json.loads(pathlib.Path("Ramble/Resources/Localizable.xcstrings").read_text())["strings"]


def keys(node):
    if isinstance(node, dict):
        for name, value in node.items():
            if name == "key" and isinstance(value, str):
                yield value
            yield from keys(value)
    elif isinstance(node, list):
        for value in node:
            yield from keys(value)


found = []
for key in sorted(set(keys(json.loads(metadata.read_text())))):
    english = translations.get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")
    if re.search("apple", key + english, re.IGNORECASE):
        found.append(key)

if found:
    print("App Intent text can't contain 'apple' (ITMS-90626):", *found, sep="\n  ")
    sys.exit(1)
print("App Intent text: fine")
