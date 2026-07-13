<div align="center">

# GitLab Duo CLI Switcher

### Multiple GitLab Duo accounts, one project, and local memory across switches

[![Version](https://img.shields.io/badge/version-8.3.2-7c3aed?style=for-the-badge)](CHANGELOG.md)
[![Windows](https://img.shields.io/badge/Windows-10%201809%2B-0078d4?style=for-the-badge&logo=windows)](#-requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391fe?style=for-the-badge&logo=powershell)](#-requirements)
[![GitLab Duo](https://img.shields.io/badge/GitLab-Duo-fc6d26?style=for-the-badge&logo=gitlab)](#-what-it-does)

**[Русский](README.md) · [English](README_EN.md) · [Download v8.3.2](dist/GitLabDuoCLI-Switcher-v8.3.2.zip) · [Web page](docs/index.html)**

</div>

---

## 💡 What it does

GitLab Duo CLI Switcher is a local Windows hub for multiple GitLab accounts that **belong to you**.

Each profile keeps an isolated `glab` OAuth configuration, while the selected repository and compact local memory stay on your computer. When one account reaches its limit, return to the Hub, select another profile, and continue in the same repository with prepared project context.

This is not a limit bypass and it is not a shared pool of third-party accounts. It only makes switching between accounts you are authorized to use easier.

## ✨ Features

- isolated `glab` OAuth configuration for every profile;
- quick account switching from one Hub;
- saved local Git projects;
- launch GitLab Duo CLI in the correct directory and with the selected model;
- compact local transcript of the visible terminal session;
- carry useful project context between profiles through project memory and `AGENTS.md`;
- account usage display when the GitLab API returns the required data;
- automatic installation or update of `glab` and GitLab Duo CLI;
- diagnostics, configuration recovery, and profile permission repair;
- safer defaults: command confirmation enabled and raw VT logs disabled.

> **Important:** server-side chats from different GitLab accounts are not merged. Switcher memory is a locally cleaned transcript of what was visible in the terminal, not a copy of GitLab's server-side conversation history.

## 🚀 Quick start

### 1. Download the archive

[**GitLabDuoCLI-Switcher-v8.3.2.zip**](dist/GitLabDuoCLI-Switcher-v8.3.2.zip)

### 2. Extract it completely

All four files must stay in the same directory:

```text
Run.cmd
GitLabDuoCLI-Switcher.ps1
DuoTerminalRecorder.cs
README.txt
```

Do not run `Run.cmd` from inside the ZIP archive.

### 3. Run `Run.cmd`

On first launch, Switcher will:

1. validate the PowerShell syntax;
2. create its local data directory;
3. install `glab` through WinGet when needed;
4. ask you to select a project and add a GitLab account;
5. open the official GitLab OAuth flow in your browser;
6. install or update GitLab Duo CLI.

## 👤 Add an account

1. Run `Run.cmd`.
2. Press `A`, or open `M → 1`.
3. Select a local Git repository.
4. Enter a clear profile name such as `Main`, `Account-2`, or `Testing`.
5. Sign in to the required GitLab account in the browser.
6. Select a namespace owned by that account.
7. Wait for GitLab Duo CLI installation to finish.
8. Return to the Hub and launch the profile by its number.

Repeat the same flow for additional accounts. Every profile gets its own authentication directory.

## 🔄 Switch without losing local context

1. Work in GitLab Duo CLI normally.
2. Enter `/exit` to return to the Hub.
3. Select another profile.
4. Switcher prepares compact project memory for that profile.
5. Continue the task in the same repository.

If the CLI exits with an error or a quota is exhausted, the Hub can offer the next available profile.

## 🧠 How local memory works

The local ConPTY recorder observes terminal output and builds useful pairs:

```text
USER → RESPONSE / RELEVANT OUTPUT
```

Spinners, menus, repeated TUI noise, and obvious service lines are removed. Compact memory belongs to the project rather than one account, allowing it to be delivered to the next profile.

Defaults include:

- up to 25 local session records;
- roughly 300 MB recorder storage cap;
- a bridge assembled from recent useful sessions;
- raw VT diagnostics disabled;
- common sensitive patterns redacted where possible.

Memory does not replace Git, proper project documentation, or human review.

## 🧭 Controls

### Hub

| Key | Action |
|---|---|
| `number` | Launch the selected account |
| `A` | Add an account |
| `P` | Select a project |
| `T` | Edit current task context |
| `C` | Check or safely compress context |
| `S` | Settings |
| `M` | Account management and diagnostics |
| `U` | Refresh usage |
| `Q` | Quit |

### Inside GitLab Duo CLI

```text
/exit       return to the Hub
/sessions   open server-side sessions for the current account
/model      change model
Tab         switch Plan / Build
```

## ⚙️ Safety settings

The `S` menu provides:

- tool auto-approval;
- local recording of visible conversations;
- raw VT diagnostic logs;
- transcript viewing and deletion;
- local recorder rebuild.

Auto-approving commands is dangerous and should only be enabled in a trusted repository. Raw VT logs may contain commands, pasted text, or secrets, so they are disabled by default.

## 📁 Local data

```text
%LOCALAPPDATA%\GitLabDuoCLISwitcher
```

This directory contains:

- isolated `glab` configurations;
- profile and project lists;
- usage cache;
- checkpoints;
- project memory and logs;
- the locally built `DuoTerminalRecorder.exe`;
- diagnostic logs.

Replacing the four application files during an update does not delete accounts, OAuth state, projects, or history.

## 🧰 Diagnostics

Open:

```text
M → 6  Diagnostics
```

The doctor checks:

- Windows version;
- `glab` presence and version;
- C# recorder build;
- ConPTY runtime;
- context integrity;
- GitLab authentication for every profile;
- local project memory.

Crash log:

```text
%LOCALAPPDATA%\GitLabDuoCLISwitcher\crash.log
```

## 🖥 Requirements

- Windows 10 1809 build 17763 or newer;
- Windows PowerShell 5.1;
- WinGet, or a preinstalled `glab` version 1.107.0+;
- Git;
- a GitLab account with access to the required GitLab Duo features;
- a local Git repository.

Available models and real usage limits are determined by GitLab and the subscription attached to each account. Switcher does not grant subscriptions or create additional quota by itself.

## 🔐 Security and privacy

- use only accounts you own or are authorized to use;
- keep secrets out of prompts and transcripts;
- leave raw VT logs disabled unless they are required for diagnostics;
- review `git diff` before committing;
- do not enable auto-approval in an untrusted project;
- protect your Windows account because OAuth configuration is stored locally;
- redact tokens, cookies, private code, and personal data before sharing logs.

See [SECURITY.md](SECURITY.md).

## 📦 Updating

1. Close the Hub and every GitLab Duo CLI window.
2. Download the new ZIP.
3. Extract it over the program directory.
4. Replace all four files.
5. Run `Run.cmd`.

User data remains under `%LOCALAPPDATA%\GitLabDuoCLISwitcher`.

## ⚖️ Project status

This is an unofficial community utility and is not affiliated with GitLab B.V. or OpenAI. GitLab, GitLab Duo, and related trademarks belong to their respective owners.

The supplied archive did not contain a license file. This repository does not invent a license or claim authorship of third-party code. Before copying, modifying, or redistributing the source, make sure you have permission from the original author.

---

<div align="center">

**GitLab Duo CLI Switcher 8.3.2**

[Русская документация](README.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

</div>
