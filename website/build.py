#!/usr/bin/env python3
"""Builds the static site (privacy policy + support page) for GitHub Pages.

The policy text comes from Ramble/Resources/Legal/*.md, the same files the app shows,
so the website and the app never disagree. Run after editing those files:

    python3 website/build.py

The contact address comes from AppLinks.contactEmail (PrivacyPolicyView.swift); pass one as an
argument to override it.

The output goes to website/docs/ (GitHub Pages can serve a repo's /docs folder).
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
LEGAL = ROOT.parent / "Ramble" / "Resources" / "Legal"
OUT = ROOT / "docs"

STYLE = """
:root { --bg:#ffffff; --fg:#1c1c1e; --muted:#6c6c70; --line:#e5e5ea; --accent:#d9480f; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#000000; --fg:#f2f2f7; --muted:#a1a1a6; --line:#2c2c2e; --accent:#ff8a4c; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 32px 16px 64px; }
nav { display:flex; gap:16px; font-size:14px; margin-bottom:24px; }
a { color: var(--accent); }
h1 { font-size: 28px; line-height:1.25; margin: 0 0 8px; }
h2 { font-size: 19px; margin: 32px 0 8px; padding-top: 16px; border-top: 1px solid var(--line); }
p, li { color: var(--fg); }
.muted { color: var(--muted); font-size: 14px; }
ul { padding-left: 1.2em; }
li { margin: 6px 0; }
"""


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"([\w.+-]+@[\w-]+\.[\w.-]+)", r'<a href="mailto:\1">\1</a>', text)
    return text


def markdown(text: str) -> str:
    out, in_list = [], False
    for line in text.splitlines():
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("## "):
            out.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("# "):
            out.append(f"<h1>{inline(line[2:])}</h1>")
        else:
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def page(lang: str, title: str, nav: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
<nav>{nav}</nav>
{body}
</main>
</body>
</html>
"""


def app_contact_email() -> str:
    """AppLinks.contactEmail in the app, so the address is set in one place."""
    source = (ROOT.parent / "Ramble" / "Features" / "Settings" / "PrivacyPolicyView.swift").read_text(encoding="utf-8")
    match = re.search(r'static let contactEmail = "([^"]*)"', source)
    return match.group(1) if match else "{{CONTACT_EMAIL}}"


def main() -> None:
    email = sys.argv[1] if len(sys.argv) > 1 else app_contact_email()
    if "@" not in email:
        print("warning: no contact email given; pages will show {{CONTACT_EMAIL}}", file=sys.stderr)
    OUT.mkdir(exist_ok=True)
    zh_nav = '<a href="index.html">随口记</a><a href="privacy.html">隐私政策</a><a href="support.html">支持</a><a href="en.html">English</a>'
    en_nav = '<a href="en.html">Ramble</a><a href="privacy-en.html">Privacy</a><a href="support-en.html">Support</a><a href="index.html">中文</a>'

    for name, lang, nav, title in [
        ("privacy", "zh-Hans", zh_nav, "随口记隐私政策"),
        ("privacy-en", "en", en_nav, "Ramble Privacy Policy"),
    ]:
        source = LEGAL / ("privacy-zh-Hans.md" if lang == "zh-Hans" else "privacy-en.md")
        text = source.read_text(encoding="utf-8").replace("{{CONTACT_EMAIL}}", email)
        (OUT / f"{name}.html").write_text(page(lang, title, nav, markdown(text)), encoding="utf-8")

    mail = inline(email)
    (OUT / "index.html").write_text(page("zh-Hans", "随口记", zh_nav, f"""
<h1>随口记</h1>
<p>想到什么，说一句就记下。待办、账本、账单和到期提醒、笔记，都由 AI 帮你整理。</p>
<ul>
<li>说一句「明天下午三点交房租 3200」，自动变成待办、账单和一笔支出。</li>
<li>可以完全离线：语音识别和 AI 整理都能在 iPhone 上完成。</li>
<li>数据只在你的 iPhone 和你自己的 iCloud 里，我们没有服务器。</li>
</ul>
<p>完全免费、开源（MIT 许可）：<a href="https://github.com/hellomyworkid-tech/Ramble">github.com/hellomyworkid-tech/Ramble</a></p>
<p class="muted"><a href="privacy.html">隐私政策</a> · <a href="support.html">支持</a></p>
"""), encoding="utf-8")
    (OUT / "en.html").write_text(page("en", "Ramble", en_nav, f"""
<h1>Ramble</h1>
<p>Say it once and it's kept. AI turns what you say into to-dos, ledger entries, bill and expiry reminders, and notes.</p>
<ul>
<li>Say "pay rent 3,200 tomorrow at 3pm" and get a to-do, a bill and an expense.</li>
<li>Works fully offline: speech recognition and AI tidying can both run on your iPhone.</li>
<li>Your data stays on your iPhone and in your own iCloud. We have no servers.</li>
</ul>
<p>Free and open source (MIT License): <a href="https://github.com/hellomyworkid-tech/Ramble">github.com/hellomyworkid-tech/Ramble</a></p>
<p class="muted"><a href="privacy-en.html">Privacy Policy</a> · <a href="support-en.html">Support</a></p>
"""), encoding="utf-8")
    (OUT / "support.html").write_text(page("zh-Hans", "随口记 · 支持", zh_nav, f"""
<h1>支持</h1>
<p>遇到问题或有建议，请发邮件到 {mail}，或者在 <a href="https://github.com/hellomyworkid-tech/Ramble/issues">GitHub</a> 上提 issue。尽量写上 iPhone 型号、iOS 版本和 App 版本（在「设置 › 关于」里）。</p>
<h2>常见问题</h2>
<ul>
<li><strong>换手机后数据还在吗？</strong>打开「设置 › iCloud 同步」后，用同一个 Apple 账户登录新手机即可。也可以在「设置 › 备份与导入导出」导出完整备份，再在新手机上恢复。</li>
<li><strong>AI 整理要付费吗？</strong>随口记完全免费，没有内购。Apple Intelligence 和下载的开源模型都在手机上运行，不花钱；用 Claude、ChatGPT、Gemini 等云端服务时用的是你自己的 API Key，费用由服务商向你收取。</li>
<li><strong>下载的模型占多大空间？</strong>在「设置 › AI 整理」和「设置 › 语音识别」里能看到每个模型的大小，不用时可以删掉。</li>
<li><strong>提醒没有响？</strong>请检查 iPhone「设置 › 通知 › 随口记」是否允许通知，以及专注模式是否屏蔽了它。</li>
</ul>
"""), encoding="utf-8")
    (OUT / "support-en.html").write_text(page("en", "Ramble · Support", en_nav, f"""
<h1>Support</h1>
<p>For problems or suggestions, email {mail} or open an issue on <a href="https://github.com/hellomyworkid-tech/Ramble/issues">GitHub</a>. It helps to include your iPhone model, iOS version and the app version (Settings › About).</p>
<h2>FAQ</h2>
<ul>
<li><strong>Will my data move to a new iPhone?</strong> Turn on Settings › iCloud Sync and sign in to the new iPhone with the same Apple Account. You can also export a full backup in Settings › Backup & Export and restore it on the new iPhone.</li>
<li><strong>Does AI tidying cost money?</strong> Ramble is free, with no in-app purchases. Apple Intelligence and the downloadable open-source models run on your iPhone at no cost. Cloud services such as Claude, ChatGPT or Gemini use your own API key and are billed to you by the provider.</li>
<li><strong>How much space do downloaded models take?</strong> Each model's size is shown in Settings › AI Tidying and Settings › Speech Recognition. Delete them when you don't need them.</li>
<li><strong>A reminder didn't go off?</strong> Check that notifications are allowed in the iPhone's Settings › Notifications › Ramble, and that a Focus isn't silencing it.</li>
</ul>
"""), encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
