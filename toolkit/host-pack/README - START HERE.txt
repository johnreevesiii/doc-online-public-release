DERBY OWNERS CLUB - HOST PACK V3 (3.2.0)

START HERE
----------
1. Make sure nobody is seated and no race is running, then run Stop Hosting in
   your old pack.
2. Extract this complete pack into a NEW folder, not over the old installation,
   and not inside a OneDrive or Google Drive folder. Keep the old folder: it is
   your way back.
3. To reuse this cabinet, copy your existing cabinet.json into this new pack root.
   Keep that file private.
4. Double-click SETUP - Start Here.cmd. Select the same seats and game as before
   (for example 8 seats, option 6 Rev C Rebalance) and Yes to start now.

Always update by extracting the whole pack. Do not copy single files from this
zip over an older install: 3.2.0 changes the broker and the relay agent, 3.1.0
changed the seat stations, Setup and every board's settings file, and a partial
copy misses some of them.

Rebalance automatically starts Main plus sat1 through sat8. Main has a separate
display child, so eight seats requires ten Flycast processes. Setup and Restart
Game wait up to 75 seconds for the full set and report incomplete startup.
Signed Microsoft x64 CRT/OpenMP runtimes and the loopback network fix are included.

WHAT IS NEW IN 3.2.0
--------------------
- DOC Host updates itself: it checks for a new release, and installs it when
  nobody is playing or when you press Update now. Your pairing, saved horses and
  logs are kept, and an update that fails is undone.
- The box tells the website which game it is running, so players are always
  offered the game this PC really runs. If you pick a different game on the
  website, DOC Host offers it at your next Start. Nothing restarts by itself.
- Safer seat sign-in: a seated player's browser now uses a seat token that works
  only for this cabinet. A player's account sign-in never reaches this PC.
- One cabinet per account: pairing a PC again moves your cabinet to it.

WHAT WAS NEW IN 3.1.0
---------------------
- Host Console is back: play at THIS PC with your own online horses (below).
- No card tools in the pack: the Station Managers, the card editor, the shared
  card shelf and the card vault are gone. Card editing is done by the operator
  only. Setup no longer writes per-seat station files (and no owner PIN).
- The seat stations refuse card writes from any web page. The broker still loads
  and saves cards as before.
- Current broker: seat-drop, waiting-line and mixed-game card fixes (a card from
  one game is never saved or replayed under another). The version-switch code is
  included but stays off on home cabinets.
- Quiet board logging is built into every board's emu.cfg, so Rebalance runs at
  full speed from a fresh extract (doc-ops #97: verbose logging held it near 6 FPS).

WHAT IS INCLUDED
----------------
Original five games, plus Rev C Rebalance RB01 B2 and S1 Sharpness correction.
Original foundation parents. Rebalance cards remain in the Rebalance edition.
Local Rebalance card rows have a blue accent and balance-scale icon marked RB01.
Exact source commit and every file's hash: PACK-MANIFEST.json.

EVERYDAY BUTTONS
----------------
Doctor: health check. Restart Game: restart this configured game.
Switch Game: choose another version. Stop Hosting: stop this installation.
Start Here: change seats/game/video or finish setup.
Host Console: play at THIS PC. Load your own online horses into your local seats
and save them back to your stable.

PLAYING AT THIS PC (HOST CONSOLE)
---------------------------------
A seat you play here yourself is a local seat: the lobby can't claim it.
1. Double-click Host Console (hosting must be running). A page opens.
2. Press "Play here" on an open seat to make it yours. A seat an online player has
   just left counts down first, because their race can still finish into it.
3. Choose the seat and press Load while it shows the Insert Card screen, then press I.
   (Making a new horse at the game? Press "Start playing here" on the seat first.)
4. When you finish, press "Save this seat's horse". That sends the races to your
   stable; without it the horse stays on this PC only.
5. To hand the seat back: Save it (or "Take it out" if never raced), then "Put back online".
A card the last online player left in a seat has a "Return it" button: it goes back to
them, never to you. Japanese version (DOC 2000): a card inside the game can't come out
while a race is running, so the seat waits for it; press the same button again after the
race. The page only works on this PC. Lobby players load and save on the website as before.

SAVED HORSES AND PAIRING
-----------------------
The archive contains no personal pairing or saved horses. Online horses stay in
the website stable. Do not copy pending_saves, seat_state.json, MyStable,
Card-Library-Shared or station.json files from an old pack. If the old folder has
a pending_saves folder with files in it, leave it there and tell the operator:
those horses are recovered separately. Cards an old pack kept in its own library
folders stay there. Do not run both packs together; they share local ports and
task names.

ROLLING BACK
------------
Run Stop Hosting in this folder, then run SETUP - Start Here.cmd in the old folder
you kept (its own cabinet.json is still there) with the same seats and game.
Horses already saved to the online stable stay there.

TEST STATUS
-----------
Broker scenarios, seat-station guard checks, scripts, manifest and archive
integrity are verified for each build. Each host PC's own hardware and a live
eight-player race remain to be tested. No claim of career balance. Setting the
machine to Rebalance alone does not update the website's game-version selector.

Version 3.2.0 (3.1.0 plus the in-app updater, the game report to the website
and cabinet-only seat tokens; 3.1.0 was 3.0.0 plus the Host Console, doc-ops
#111, and the #117 pack containment). Personal testing pack. Prior packs are preserved.
