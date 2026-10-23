#!/usr/bin/env python3
"""Collects the licenses of the code shipped inside Ramble into Ramble/Resources/Legal/licenses.md,
which the app shows in Settings › About › Open-Source Licenses. MIT and Apache 2.0 both ask for
the license text to go with the software.

Run after changing dependencies (needs a build first, for the package checkouts):

    python3 scripts/make_licenses.py
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKOUTS = ROOT / "build" / "DerivedData" / "SourcePackages" / "checkouts"
OUT = ROOT / "Ramble" / "Resources" / "Legal" / "licenses.md"

# (name, home page, license file). Only what ends up in the app; swift-syntax is build-time only.
COMPONENTS = [
    ("MLX Swift", "https://github.com/ml-explore/mlx-swift", CHECKOUTS / "mlx-swift/LICENSE"),
    ("MLX", "https://github.com/ml-explore/mlx", CHECKOUTS / "mlx-swift/Source/Cmlx/mlx/LICENSE"),
    ("MLX C", "https://github.com/ml-explore/mlx-c", CHECKOUTS / "mlx-swift/Source/Cmlx/mlx-c/LICENSE"),
    ("metal-cpp", "https://developer.apple.com/metal/cpp/", CHECKOUTS / "mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt"),
    ("{fmt}", "https://github.com/fmtlib/fmt", CHECKOUTS / "mlx-swift/Source/Cmlx/fmt/LICENSE"),
    ("JSON for Modern C++", "https://github.com/nlohmann/json", CHECKOUTS / "mlx-swift/Source/Cmlx/json/LICENSE.MIT"),
    ("MLX Swift LM (with Ramble's patches)", "https://github.com/ml-explore/mlx-swift-lm", ROOT / "Vendor/mlx-swift-lm/LICENSE"),
    ("XGrammar", "https://github.com/mlc-ai/xgrammar", ROOT / "Vendor/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE"),
    ("MLX Audio Swift (with Ramble's patches)", "https://github.com/Blaizzy/mlx-audio-swift", ROOT / "Vendor/mlx-audio-swift/LICENSE"),
    ("Swift Transformers", "https://github.com/huggingface/swift-transformers", CHECKOUTS / "swift-transformers/LICENSE"),
    ("Swift Hugging Face", "https://github.com/huggingface/swift-huggingface", CHECKOUTS / "swift-huggingface/LICENSE"),
    ("Swift Jinja", "https://github.com/huggingface/swift-jinja", CHECKOUTS / "swift-jinja/LICENSE"),
    ("EventSource", "https://github.com/mattt/EventSource", CHECKOUTS / "EventSource/LICENSE.md"),
    ("yyjson", "https://github.com/ibireme/yyjson", CHECKOUTS / "yyjson/LICENSE"),
    ("Swift Collections", "https://github.com/apple/swift-collections", CHECKOUTS / "swift-collections/LICENSE.txt"),
    ("Swift Numerics", "https://github.com/apple/swift-numerics", CHECKOUTS / "swift-numerics/LICENSE.txt"),
    ("Swift Crypto", "https://github.com/apple/swift-crypto", CHECKOUTS / "swift-crypto/LICENSE.txt"),
    ("Swift ASN.1", "https://github.com/apple/swift-asn1", CHECKOUTS / "swift-asn1/LICENSE.txt"),
]
NOTICES = [("XGrammar", ROOT / "Vendor/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/NOTICE")]


def find(path: pathlib.Path) -> pathlib.Path:
    if path.exists():
        return path
    for candidate in path.parent.glob("LICENSE*"):
        return candidate
    raise SystemExit(f"missing license: {path}")


def kind(text: str) -> str:
    if "Apache License" in text:
        return "Apache License 2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT License"
    return "see below"


def main() -> None:
    texts = [(name, url, find(path).read_text(encoding="utf-8", errors="replace").strip()) for name, url, path in COMPONENTS]
    apache = next(text for _, _, text in texts if kind(text) == "Apache License 2.0")
    lines = [
        "# 开源许可 Open-Source Licenses",
        "随口记（Ramble）本身以 MIT 许可开源：https://github.com/hellomyworkid-tech/Ramble",
        "App 里用到了下面这些开源软件，感谢它们的作者。下载的模型（通义千问 Qwen3、Qwen3-ASR）不随 App 分发，采用 Apache 2.0 许可。",
        "Ramble is open source under the MIT License. It includes the open-source software below. The downloadable models (Qwen3, Qwen3-ASR) aren't part of the app and are under the Apache License 2.0.",
    ]
    for name, url, text in texts:
        lines.append(f"## {name}")
        lines.append(f"- {url}")
        lines.append(f"- {kind(text)}")
        if kind(text) != "Apache License 2.0":
            # MIT texts differ in their copyright lines: each one in full.
            lines.extend(line for line in text.splitlines() if line.strip())
    for name, path in NOTICES:
        lines.append(f"## NOTICE: {name}")
        lines.extend(line for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
    lines.append("## Apache License 2.0")
    lines.extend(line for line in apache.splitlines() if line.strip())
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(texts)} components")


if __name__ == "__main__":
    main()
