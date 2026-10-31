# Derby Owners Club Online: public release

This is how the Derby Owners Club online arcade is put together, and the toolkit community hosts use to
run a cabinet of their own that shows up in the lobby at [play.johnreevesiii.com](https://play.johnreevesiii.com).

| | |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit: cabinets, the lobby, video, saves and DOC Bot |
| [HOSTING.md](HOSTING.md) | What hosting takes, and where to start |
| [`toolkit/`](toolkit) | The scripts inside the DOC Host pack, so you can read exactly what runs on your PC |
| [PUBLIC-MANIFEST.json](PUBLIC-MANIFEST.json) | Every file here, where it came from, and its SHA-256 |

## What this repo is, and is not

It is the readable source of the host-side tools, plus a plain explanation of the system. Read it,
learn from it, point out problems.

It is **not** a complete install. The working host pack is downloaded from the arcade (see
[HOSTING.md](HOSTING.md)), because it carries things that can't be published here. There are no game files
in this repo.

Some parts of the arcade stay private on purpose: the account and stable services, the saves pipeline
behind the website, and the systems that keep the game fair. Publishing those would make the arcade
easier to cheat, not easier to host.

## Questions and problems

Ask in the Derby Owners Club Discord. For a cabinet that won't start or stream, run **Cabinet Doctor**
from your pack and post its `hardware-report.json` in #bug-reports. DOC Bot reads it and answers.

This repo is generated from the arcade's private repos by an allowlist export: only files picked on
purpose are copied, and the export refuses to publish if a scan finds a key, a private address or
personal data. If you ever spot something here that looks like it shouldn't be, please say so privately
in Discord instead of in a public issue.
