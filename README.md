# Shelf

A native iOS player for [Audiobookshelf](https://www.audiobookshelf.org), built with a focus on reliability, battery life and data use.

Requires Xcode 26.1+ and iOS 26.1+ (it uses Liquid Glass and the tab bar accessory slot for the mini player). There are no third-party dependencies.

## Running it

Open `Shelf.xcodeproj`, choose your development team under Signing & Capabilities (for all three targets: Shelf, ShelfWidgetsExtension and ShelfWatch), and run. The app and its widget extension share data through the App Group `group.nz.galengreen.shelf`; Xcode must be signed in to your Apple account (Settings → Accounts) so automatic signing can register the App Group and create profiles for the widget extension and watch app; or create the group under Identifiers → App Groups in the developer portal and enable it for `nz.galengreen.shelf` and `nz.galengreen.shelf.widgets`. Sign in with your server address plus a username and password, or with an API key (server Settings → API Keys). A bare address such as `192.168.1.10:13378` works: local addresses try HTTP first, everything else tries HTTPS first.

## Features

- **Home:** where you left off, with the chapter list, plus the server's shelves (continue listening, recently added, series, authors, newest episodes). When you finish a book, the next one in its series is offered (or started automatically, if you turn that on).
- **Library:** your books with instant local search, filters and sorting, and shortcuts to Series, Collections, Playlists, Narrators, Genres, Tags and Languages.
- **Search:** searches the whole library on the server (books, series, authors, narrators, genres, tags, podcast episodes), with cached results offline.
- **Player:** chapter scrubber, speed, AirPlay, sleep timer, bookmarks, and an Up Next queue. Lists of chapters, bookmarks and the queue replace the artwork.
- **Bookmarks:** stored on the server, so they sync with the web app and other clients. Changes made offline upload later.
- **Playlists:** play straight through as a queue, skipping anything finished. Add books or episodes from their menus.
- **Podcasts:** podcast libraries with episode lists, progress, downloads and playback.
- **Listening stats:** today, the last week, streak, all time, this year so far, most listened and recent sessions across devices.
- **Live sync:** progress and bookmarks from your other devices appear straight away (Socket.IO, only while the app is open).
- **Sign-in:** password, API key, or single sign-on through the server's OpenID provider.
- **Siri and Shortcuts:** Resume Listening, Pause, Skip Forward/Back, Set Sleep Timer (minutes or end of chapter), Turn Off Sleep Timer, Play Book (pick a title from your library) and Play Next in Series. Phrases such as "Resume my audiobook in Shelf" and "Sleep timer in Shelf" work without setup. Intents that play audio run in the app and reuse the same player as the UI.
- **Widgets:** Now Playing (cover, chapter, progress, play/pause and skip, plus Lock Screen versions), Listening Streak (Home and Lock Screen) and Past Year (a small activity grid like the one in Listening Stats).
- **Live Activity:** the chapter, its progress and time left, the sleep timer countdown and controls on the Lock Screen and in the Dynamic Island while you listen. It can be turned off in Settings.
- **Control Centre:** Play or Pause, Skip Back, and a Sleep Timer toggle (its length is set when you add it).
- **iPad:** a sidebar, cover grids in Library, two-column book pages, and a two-column player in landscape (artwork on the left, chapters and controls on the right).
- **Apple Watch:** a remote for the iPhone: what's playing, chapter progress, play/pause, skip, chapters and the sleep timer.
- **CarPlay:** written and built in, but switched off until Apple grants the CarPlay audio entitlement (see [CarPlay](#carplay)).

## Layout

| Folder | Contents |
| --- | --- |
| `Shelf/Core` | API client, wire models, settings, progress, bookmarks, offline sessions, library store, live updates, single sign-on |
| `Shelf/Playback` | `AudioEngine` (AVQueuePlayer wrapper), `PlaybackController` (sessions, sync, sleep timer, recovery), lock-screen integration |
| `Shelf/Downloads` | Background-session download manager |
| `Shelf/Images` | Cover pipeline, palette extraction, cover views |
| `Shelf/Features` | Home, Library, Browse (series, collections, playlists), Search, Authors, Book detail, Podcasts, Player, Stats, Settings, Login |
| `Shelf/Intents` | App-only intents (Play Book, Play Next in Series), the book entity and query, Siri phrases, and `AppModel`'s intent and watch command handling |
| `Shelf/Integrations` | `PlaybackBroadcaster` (one snapshot of what's playing, fanned out on real changes), widget snapshot writer, Live Activity controller, watch link |
| `Shelf/CarPlay` | CarPlay scene delegate and list templates (inactive, see below) |
| `Shared` | Built into the app, widget extension and watch app: App Group files, the now-playing snapshot, listening-day maths, formatting, playback intents, Live Activity attributes, the watch message protocol |
| `ShelfWidgets` | Widget extension: Now Playing, Listening Streak and Past Year widgets, the Live Activity, Control Centre controls |
| `ShelfWatch` | watchOS remote (WatchConnectivity) |
| `Config` | The app's and extension's Info.plist files and entitlements |

## Reliability

- **Expiring stream tokens.** Audiobookshelf access tokens last an hour, and AVPlayer keeps fetching byte ranges throughout a long book. Tokens are refreshed at pause boundaries before they expire. If a stream still fails, the player rebuilds at the same position with a fresh token (at most three attempts a minute).
- **Single-flight token refresh.** Refresh tokens rotate, so two concurrent refreshes can log you out. All refreshes go through one task.
- **Progress never goes backwards.** Positions are written locally first, and the newest of local and server progress wins. Anything recorded offline uploads in one batch when the server is reachable again. If you've listened on another device since pausing, resuming jumps to that position.
- **Nothing waits on a slow server.** Closing a session, switching books and stopping all record locally and sync in the background. Downloaded books play even when the server is unreachable.
- **Server restarts.** If the server forgets the playback session (404 on sync), the app falls back to plain progress updates.
- **Finishing a book.** The player unloads before anything is sent, so a late position sync can't reset a finished book to the start. Position syncs never send "not finished"; only Mark as Unfinished does.
- **Offline listening counts.** Time listened without a server session is saved as a local session and uploaded later, so it appears in your server stats.
- **Interruptions.** Calls, Siri and unplugged headphones are handled. Playback only resumes after an interruption if the system asks it to and you didn't pause it yourself.

## Battery and data

- **Direct play.** Original files are streamed, with no server-side transcoding unless the format needs it. Only the current file and the next one are queued.
- **No polling in the background.** The UI time observer only exists while a playhead is on screen. Chapter changes in the background come from a single boundary observer. Lock-screen info is only pushed on real changes, because the system extrapolates elapsed time itself. Progress syncs every 30 seconds in the foreground and every 60 in the background.
- **Live updates instead of polling.** While the app is open, a WebSocket delivers changes from other devices (a ping every 25 seconds). It disconnects in the background.
- **One request for in-progress details.** Chapters for every book you're listening to arrive in a single batch request and are kept on disk, so they're there offline.
- **Browsing is computed locally.** Narrators, genres, tags and languages come from the cached library listing, so they cost no requests and work offline.
- **ETag caching.** The library, home shelves, authors and progress are revalidated with `If-None-Match`, so an unchanged library costs a few empty 304 responses. Library pages are fetched oldest-first, so adding a book only changes the last page.
- **Right-sized artwork.** Covers are requested at display size as WebP, bucketed so any larger cached copy satisfies a smaller request, and downsampled straight to display size. In Low Data Mode, artwork is capped at a lower resolution.
- **Downloads.** Downloads use a background URLSession and are Wi-Fi only by default. "Download While Listening" fetches the book you start so the rest of it plays from disk.
- **Static visuals.** The player's mesh-gradient background is sampled once from the cover, and nothing animates in a loop while playing.
- **Widgets, Live Activity, Control Centre and the watch are pushed, never polled.** The player publishes one snapshot when the book, chapter, play state, speed, sleep timer or position (a seek) changes, coalesced to one per run-loop turn. Each destination drops snapshots that wouldn't look different. Progress bars, time left and the sleep countdown are drawn by the system from dates, so nothing is sent while a chapter simply plays on. Widget data is a small JSON file plus a 320 px cover in the App Group container. Listening stats for the streak and Past Year widgets are only fetched when one of those widgets is installed, at most every half hour, and ETag-cached.

## Known gaps

- CarPlay is inactive until Apple grants the `com.apple.developer.carplay-audio` entitlement (see below).
- The watch app is a remote for the iPhone; it doesn't play downloaded books on its own yet.
- A Live Activity can only be started while Shelf is in the foreground. Playback started from Siri, a widget or headphones gets its Live Activity the next time you open the app.
- Siri and Shortcuts book titles come from the library that's selected in Shelf.
- Ebooks and custom request headers (for example, Cloudflare Access) aren't supported.
- Single sign-on needs `audiobookshelf://oauth` in the server's OpenID mobile redirect URIs, which is the default.

## CarPlay

The CarPlay code is compiled into every build but stays inactive, because an app can't be signed with the CarPlay entitlement until Apple grants it. Already in place:

- `Shelf/CarPlay/CarPlaySceneDelegate.swift`: tab bar with Continue Listening, Library and Downloads lists (`CPListTemplate`), playing a book pushes the system Now Playing screen (`CPNowPlayingTemplate`) with a speed button. Lists come from the cached library, progress and downloads, so browsing costs no requests.
- `Config/Info.plist`: the `CPTemplateApplicationSceneSessionRoleApplication` scene configuration. Scene manifest generation is off for the app target (`INFOPLIST_KEY_UIApplicationSceneManifest_Generation = NO`) so this manifest is used; the phone and iPad windows still come from SwiftUI's `WindowGroup`.

To switch it on once Apple approves the request (https://developer.apple.com/carplay/, "Request the CarPlay entitlement", category: audio):

1. In the developer portal, open the App ID `nz.galengreen.shelf` and enable the CarPlay Audio capability (it appears under Additional Capabilities once granted). With automatic signing, Xcode regenerates the provisioning profile on the next build.
2. Add the entitlement to `Config/Shelf.entitlements`:

   ```xml
   <key>com.apple.developer.carplay-audio</key>
   <true/>
   ```

3. Build and run, then test with the CarPlay external display in the iOS Simulator (or a CarPlay head unit). Nothing else needs changing.

Without step 2 the scene configuration is ignored and the app signs and runs normally.

## Testing

Debug builds can sign in without the login form, for simulator automation:

```sh
SIMCTL_CHILD_SHELF_SERVER=http://localhost:13378 SIMCTL_CHILD_SHELF_API_KEY=… \
  xcrun simctl launch --terminate-running-process booted nz.galengreen.shelf
```

`SHELF_USERNAME` and `SHELF_PASSWORD` work instead of `SHELF_API_KEY`. This is compiled out of release builds.
