# Ramble Privacy Policy

Effective date: October 15, 2026

Ramble (随口记 in Chinese) is an iPhone app for keeping to-dos, expenses and notes by talking or typing. We, the developer of Ramble, run no servers and collect none of your data. This policy explains where your data is kept and when it leaves your iPhone.

## In short

- Your to-dos, ledger, bills, expiry reminders, notes and attachments are stored on your iPhone and, if you turn on iCloud Sync, in your own iCloud account. We can't see any of it.
- We don't collect personal information, run analytics, show ads, track you, or have an account system.
- Text is sent to an AI provider only if you set up cloud AI yourself, with your own API key, and agree to it.

## Where your data is kept

- **Your iPhone**: all records are kept in the app's own storage, protected by iOS.
- **Your iCloud (optional)**: if you turn on Settings › iCloud Sync, records sync through Apple's CloudKit to your private iCloud database, readable only by devices signed in to the same Apple Account. Apple keeps this data under its privacy policy; we have no access to it. You can turn sync off at any time.
- **Files you export**: you decide where full backups and CSV files are saved.

## Voice, photos and AI

- **Speech recognition**: the iPhone's built-in recognizer, or the Qwen3-ASR model if you download it, runs on your iPhone. Recordings are never uploaded or kept.
- **Photos and files**: only photos and files you pick or take are read, and text recognition happens on your iPhone.
- **On-device AI**: Apple Intelligence and any open-source model you download run on your iPhone; the text never leaves it.
- **Cloud AI (optional, off unless you set it up)**: if you enter your own API key for Claude (Anthropic), ChatGPT (OpenAI), Gemini (Google) or a custom endpoint in AI Tidying, and agree the first time it's needed, text that needs cloud processing is sent with your key directly to that provider, never through us. Only what's being processed is sent: a capture, a note being tidied, a question you ask (plus a few related note entries when it's about your notes), the totals and category amounts of a weekly or monthly report, and text recognized from files (with ID card numbers removed on your iPhone first). Original files are sent only after you confirm each time. How the provider handles this is governed by your agreement with them and their privacy policy. The app asks again if you switch providers, and you can turn cloud AI off in Settings at any time.
- **API keys** are stored only in this device's keychain; they don't sync and aren't in backups.

## Network services the app uses

Besides any cloud AI you set up, Ramble only contacts:

- **ExchangeRate-API** (open.er-api.com): about once a day, for exchange rates. The request contains only your base currency code.
- **Hugging Face** (huggingface.co): only when you choose to download an open-source model, to list and download its files.
- **Apple services**: iCloud Sync, notifications, and the language assets the system's speech recognition needs.

None of these requests contain your records. As with any network request, the server sees your IP address.

## Permissions

- **Microphone and speech recognition**: used only while you're dictating.
- **Camera**: used only when you photograph a receipt or a document.
- **Photos (add only)**: used only when you tap Save to Photos, to put a photo from your notes into your library. The app can't see what's in your library. Adding photos uses the system photo picker, so the app only gets the ones you choose.
- **Face ID / Touch ID**: iOS does the check; the app only learns whether it passed and never sees biometric data.
- **Notifications**: for your reminders, all scheduled on your iPhone.
- **Local network**: used only if you point the custom AI endpoint at an address on your local network.

## Open source

Ramble is free, and its source code is public at https://github.com/hellomyworkid-tech/Ramble (MIT License), so you can check for yourself what the app does.

## Deleting your data

- Delete records in the app, or delete the app, to remove the data on your iPhone.
- If you used iCloud Sync, delete Ramble's iCloud data in Settings › [your name] › iCloud › Manage Account Storage.
- For anything already sent to a cloud AI provider, use that provider's own deletion process.

## Children

Ramble is not directed at children under 13. We don't knowingly collect anyone's personal information.

## Changes

If this policy changes, we'll update this page and its effective date, and mention important changes in the app's release notes.

## Contact

Questions about this policy: email {{CONTACT_EMAIL}}.
