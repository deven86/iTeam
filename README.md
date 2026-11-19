# iTeam — chat first, tasks built in

Private chat for iPhone and iPad with a Business Tasks module. No servers of our own, no phone number, no ads.
SwiftUI · SwiftData (on device) · CloudKit public database as an encrypted mailbox · CryptoKit end-to-end encryption ·
Notification Service Extension · local reminders. Built and shipped to TestFlight entirely from GitHub Actions — no Mac needed.

## What's in v1.0

| Area | What it does |
|---|---|
| Chats | One-to-one and group chats, photos (up to 10 at once), files up to 25 MB, replies, reactions (double-tap = 👍), edit, delete for everyone, links, drafts, search, filters (All / Unread / Personal / Groups / Archived), pin, mute, archive |
| Honest status | 🕒 saved on this device → ✓ in iCloud → ◯✓ delivered → ●✓ read. Ticks appear only after the other phone acknowledged |
| Groups | Owner / admin / member roles, add and remove members, rename, group photo, leave. Removing someone rotates the group key |
| Contacts | Add face to face with a QR code, or by invite link. The key in the code is checked against iCloud. Message requests from strangers: Add / Block. Security codes to compare |
| Business Tasks | Long-press any message → Create Business Task. Separate dashboard: My Tasks, Assigned to me, Created by me, Group tasks, Completed; Overdue / Due today / Upcoming; summary tiles |
| Whole-group tasks | One task for the whole group. Completion policy: *anyone can complete* or *everyone finishes their part* (per-person progress). Checklists, comments, priority, due date, reopen with reason, activity |
| Notifications | New messages, assignments and comments arrive as real push notifications even when the app is closed (CloudKit subscription → Apple push → our extension decrypts the preview on the phone). Deadline reminders are local, work offline, with *Mark done* / *Snooze 1 h* buttons |
| Activity | Mentions (@name), assignments, completions, comments, group changes, sync status |
| Looks | **iLife Glass** (12 animated themes, time-of-day mode, own photo) · **Third Eye Calm** (6 themes, frosted/clear glass, 7 skins + own photo, dim slider) · **Classic Pastel** (regular iOS look, 8 pastel colours, light/dark/system). Per-chat wallpapers |
| iPad | Sidebar + split view (chat list beside the open chat), all orientations |
| Privacy | Face ID lock, Lock Screen previews on/off, JSON export, erase local data |
| Modules | `ModuleRegistry` with entitlements — Business Tasks can be switched off; future paid modules plug in without touching chat |

## How it works without a server

```
 Rahul's iPhone                        Apple iCloud (public DB, container iCloud.com.jondhale.iteam)        Priya's iPhone
 ───────────────                       ──────────────────────────────────────────────────────────          ──────────────
 save locally ──► Outbox ──encrypt──►  Envelope {rcpt: Priya, body: 🔒, hint: 🔒}  ──CKQuerySubscription──►  APNs push
                                       (one per recipient + one echo to my iPad)                           │
                                                                                                           ▼
                                                                         Notification extension decrypts "Rahul: Draft is ready"
                                                                         App opens → fetches envelopes → decrypts → applies event
```

* **Identity** = your iCloud account's anonymous CloudKit user ID + a Curve25519 key made on your device
  (synced to your iPad through iCloud Keychain). Public profile in iCloud: name, small photo, public key.
* **One-to-one keys** are computed by both sides (ECDH + HKDF). **Group keys** are random and sent to each member
  encrypted with that pairwise key. Messages: ChaChaPoly. Only Apple CryptoKit primitives are used.
* **Sender authentication**: CloudKit stamps every record with its real creator; envelopes whose `from` doesn't match are dropped.
* **Retention**: envelopes and files are deleted from iCloud by the sender's app after 45 days.
* **Cost**: CloudKit public database within Apple's free allowance (it grows with active users). Apple Developer Program only.

### Known limits (by design, documented in the app)
* Everyone needs an Apple device signed into iCloud. No Android, no web.
* A person offline for more than 45 days misses messages sent meanwhile.
* New group members see messages from the moment they join, not earlier history.
* Push delivery is Apple's best effort; the app also fetches every 20 s while open and in background refresh.

## One-time setup (same pattern as iLife)

1. **Create the GitHub repo** `deven86/iteam` (private) and push this code.
2. **Repo secrets** (Settings → Secrets → Actions):
   `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`, `CLOUDKIT_MANAGEMENT_TOKEN`,
   plus the two shared-signing secrets (identical in every app repo): `MATCH_PASSWORD`, `MATCH_GIT_TOKEN`.
   All apps share ONE distribution certificate stored encrypted in the private repo `deven86/apple-signing`.
3. **developer.apple.com → Identifiers** (the API can't do these):
   * App Groups → `group.com.jondhale.iteam`
   * iCloud Containers → `iCloud.com.jondhale.iteam`
4. Actions → **Signing setup** → Run. Registers `com.jondhale.iteam` and `com.jondhale.iteam.notify`,
   enables Push, iCloud and App Groups.
5. developer.apple.com → Identifiers → `com.jondhale.iteam`: tick the App Group and the iCloud container (CloudKit).
   On `com.jondhale.iteam.notify`: tick the same App Group. Then run **Signing setup** again with *force* ticked.
   If it says the certificate limit is reached, run **Portal check**, then Signing setup with `revoke_cert`.
6. **App Store Connect** → My Apps → + New App → bundle `com.jondhale.iteam`, name e.g. "iTeam Chat".
7. Actions → **CloudKit schema** → Run (uploads `cloudkit/schema.ckdb` to Development).
   Then **icloud.developer.apple.com → iCloud.com.jondhale.iteam → Deploy Schema Changes** to Production.
   *TestFlight builds use Production — without this step chats can't send.*
8. Actions → **TestFlight** → Run, type `UPLOAD`.

`CI` compiles for the Simulator only (run it by hand or on pull requests).

## Export compliance (before App Store release)
`ITSAppUsesNonExemptEncryption` is `false` so TestFlight builds go through. iTeam encrypts messages end to end with
standard algorithms (Apple CryptoKit). Before the public App Store release, answer App Store Connect's export compliance
questions for an app that uses standard encryption and file the annual self-classification report if required.

## Project layout
```
iTeam/App            app entry, deep links, push + background refresh
iTeam/Design         the three looks (VividTheme = iLife, CalmTheme = Third Eye, Classic pastel), components
iTeam/Model          SwiftData models, events
iTeam/Sync           CloudService (CloudKit), SyncEngine (outbox / inbox), EventApplier, Actions
iTeam/Services       attachments, reminders, Face ID lock, module registry
iTeam/Features       Onboarding, Chats, Contacts, Groups, Tasks, Activity, Settings
iTeamNotify          notification service extension (decrypts previews)
Shared               keychain + CryptoKit helpers shared by app and extension
cloudkit/schema.ckdb CloudKit record types
```
