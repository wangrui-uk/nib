# Security policy

Nib reads and writes text in other apps through macOS Accessibility, and sends text to the AI provider the user chose. Security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through GitHub: **[Report a vulnerability](https://github.com/wangrui-uk/nib/security/advisories/new)** (the repository's Security tab → *Report a vulnerability*).

Please include:

- what an attacker could do (for example, read text Nib shouldn't, send it somewhere other than the chosen provider, or get code run);
- the steps to reproduce it, and the Nib and macOS versions;
- no real API keys, and no private text.

You'll get an answer within a few days. A fix is released as soon as possible, and you'll be credited unless you'd rather not be.

## Scope

In scope: the Nib app and its update mechanism (release signing, the Sparkle appcast and update signatures), and the build and release scripts in this repository.

Out of scope: the AI providers' own services and policies, and problems that need an attacker who already controls the user's Mac account.

## Supported versions

Only the latest release gets security fixes. Nib updates itself, and you can check from the menu with **Check for Updates…**.
