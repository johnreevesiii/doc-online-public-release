# Hosting a cabinet

Hosting turns your Windows PC into a Derby Owners Club cabinet that appears in the online lobby. Anyone
in the lobby can sit at it and race their own horses.

The official, always-current instructions are on the arcade site:

- **Host guide:** [play.johnreevesiii.com/host/guide](https://play.johnreevesiii.com/host/guide)
- **Install steps:** [play.johnreevesiii.com/host/install](https://play.johnreevesiii.com/host/install)

The DOC Host installer is downloaded from the Host page while signed in. It is not published here.

## What your PC needs

| Part | What to aim for |
|---|---|
| Windows | Windows 10 or 11, 64-bit. No Mac or Linux version. |
| CPU | Single-core speed matters most. Eight seats is ten game windows at once. |
| Graphics | A real graphics card helps: it encodes the video. |
| Memory | 16 GB is comfortable for eight seats. |
| Disk | About 2 GB free. |
| Internet | A steady **upload**. Every remote player watches video sent from your PC. Wired beats Wi-Fi. |

Run at least four seats: the race needs the other seats to fill the field. Not sure your PC can keep up?
Start at four and raise it later.

## The short version

1. Download **DOC Host** from the Host page and run the installer. Windows may warn that the installer
   isn't signed; the install guide shows the "More info, Run anyway" step.
2. Open DOC Host and pair it to your account (a one-time code).
3. Pick the game and the number of seats, then press **Start hosting**. Card broker, Game, Seat
   stations, Lobby link and Video should all go green within about two minutes.
4. Keep the PC awake while you host, and keep your upload free of other big streams or backups.
5. Press **Stop hosting** when nobody is seated, rather than shutting the PC down with players on it.

Your cabinet's private key lives in DOC Host's data folder (`%LOCALAPPDATA%\DOC Host\data`). Never copy
it anywhere shared: it is your cabinet's key to the lobby.

## When something goes wrong

Press **Doctor** in DOC Host for a full health report. For video problems, **Cabinet Doctor** tests your
graphics card's encoders and writes `hardware-report.json`: post that file in #bug-reports on Discord and
DOC Bot will read it.

## Reading the scripts

Everything in [`toolkit/`](toolkit) is copied from the source the DOC Host installer is built from, at
the commit listed in [PUBLIC-MANIFEST.json](PUBLIC-MANIFEST.json):

| Folder | What it does |
|---|---|
| `toolkit/doc-host-app/` | The DOC Host window and its buttons: pair, start, stop, fix picture, restart, Doctor, remote restart |
| `toolkit/host-pack/` | The host pack DOC Host runs: setup, launch, restart, the seat stations, Host Console, Cabinet Doctor |
| `toolkit/streaming/` | Screen and audio capture, and the push to the relay |
| `toolkit/board-config/` | Example board settings (main board and one seat) |
