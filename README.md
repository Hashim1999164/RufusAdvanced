<p align="center">
  <img src="docs/icon.png" width="128" alt="RufusAdvanced icon">
</p>

<h1 align="center">RufusAdvanced</h1>

<p align="center">
  <b>Make a bootable USB stick on your Mac — to install Windows, macOS or Linux.</b><br>
  Free, simple, and it picks the right settings for you.
</p>

<p align="center">
  <a href="https://github.com/Hashim1999164/RufusAdvanced/releases/latest"><b>⬇︎ Download for Mac</b></a>
  &nbsp;·&nbsp; macOS 13 or newer &nbsp;·&nbsp; Apple silicon and Intel
</p>

---

## What is it?

A bootable USB stick lets you install an operating system on a computer. RufusAdvanced makes one for you:

- 🪟 **Windows 10 / 11** installer for a PC
- 🍎 **macOS** installer for a Mac
- 🐧 **Linux** (Ubuntu, Mint, Fedora, Debian and more), to try or install

It can also download Windows, macOS and Linux for you, straight from Microsoft, Apple and the Linux projects.

## Install

1. [Download the latest version](https://github.com/Hashim1999164/RufusAdvanced/releases/latest) — the file ending in `.dmg`.
2. Open it and drag **RufusAdvanced** into your **Applications** folder.
3. Open RufusAdvanced from Applications.
   If your Mac says it can't be opened, go to **System Settings › Privacy & Security**, scroll down and click
   **Open Anyway**. (This happens because the app isn't registered with Apple — it's safe and open source.)

Already use [Homebrew](https://brew.sh)? Run `brew install --cask hashim1999164/tap/rufusadvanced` instead.

## How to use it

1. **Plug in a USB stick.** ⚠️ Everything on it will be erased — copy your files off first.
2. **Choose what to put on it:** drag a file (`.iso`, `.dmg`, macOS installer…) onto the window,
   or click **Download** to get Windows, macOS or Linux.
3. **Click START**, confirm, and type your Mac password. Wait until it says **Ready**.

That's it — the right settings are chosen automatically.

### Making a macOS installer

Click **Download › macOS…**, then **Get Installer** next to the version you want.
The app downloads it from Apple, installs it into Applications, checks it, and selects it for you. Then click **START**.

### Making a Windows installer

Click **Download › Windows…**, choose the version and your language, click **Get download links**, then
**Download & Use**. When it's done, click **START**. For Windows 11, the options to skip the TPM / Secure Boot check
and the Microsoft account sign-in are already turned on.

## Questions

**What size USB stick do I need?**
16 GB or more for Windows and macOS. 8 GB is usually enough for Linux.

**Why does it ask for my password?**
macOS only lets you write to a USB stick after you confirm with your password.

**Can it erase the wrong disk?**
No. Your Mac's own disks are never shown — only USB sticks and SD cards.

**How do I start a computer from the USB stick?**
On a PC: plug it in, turn the PC on and press the boot menu key (often **F12**, **F11**, **F8** or **Esc**), then pick
the USB stick. On a Mac (macOS installer): hold the **power button** (Apple silicon) or **Option ⌥** (Intel) while it
starts, then pick the installer.

**Something went wrong?**
Click **Log** at the bottom of the window, copy it, and
[open an issue](https://github.com/Hashim1999164/RufusAdvanced/issues) — we'll help.

**Is it free?**
Yes. Free and open source.

---

<sub>
More details — every feature and option, the command line tool, building from source: <a href="docs/DETAILS.md">docs/DETAILS.md</a>.
Want to help? See <a href="CONTRIBUTING.md">CONTRIBUTING.md</a>.<br>
RufusAdvanced is an independent project inspired by and partly based on <a href="https://rufus.ie">Rufus</a> by Pete Batard
(not affiliated). Credits: <a href="docs/DETAILS.md#credits">docs/DETAILS.md</a>. License: <a href="LICENSE">GPLv3</a>.
</sub>
