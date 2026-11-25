# iTeam — next update (saved 25 Nov 2026, do NOT build before Devendra says go)

GitHub Actions is blocked until billing resets on 1 Dec. Nothing here is started yet.

## 1. Tagline — use everywhere from now on
Approved privacy lines (true today, legally safe — no "most secure in the world" superlative):
- **"Your chats are yours. Not even we can read them."** (main tagline)
- "End-to-end encrypted. No ads. No tracking. No servers watching."
- "Your business, your family, your data — locked on your phone."

Put it in: App Store subtitle/promo text/description, website (iteam-web), Instagram bio, ad copy,
onboarding/welcome screen, Settings → About, share/invite messages, PDF footers if space allows.

## 2. Sealed sender + independent audit (stronger claim later)
- Hide the sender in the CloudKit mailbox (today an Envelope stores rcpt, sndr, conv, kind — readable as metadata).
- Then commission an independent security audit.
- Only after both: "Built for privacy, independently verified."

## 3. Safer "Delete account"
Before deleting, show: groups where I'm the ONLY admin, and companies I own, each with a
**"Transfer first"** button (reuse GroupDuties / TransferDutiesView). Then the final confirm.

## 4. iCloud backup — progress + resumable
- Visible progress bar (% and MB done / total) for backup and restore.
- Keeps going in the background / after swipe-up where iOS allows (long-lived CloudKit operations,
  BGProcessingTask), and **resumes from where it stopped** next time the app opens (chunked upload/download).
- One tap starts it; no need to go to iCloud settings.
- Waiting on Devendra's screenshots of the backup error (not received yet).

## 5. Android + optional relay server (decision pending)
- Problem: Android signs in to Apple CloudKit through the web, and that session expires → users get logged out.
- Idea: a small relay server only for connecting + notifications; data stays on devices and in each user's own
  cloud (iCloud / Google Drive). Server stores only encrypted messages briefly. iPhone ↔ Android talk through it.
- Decided so far (25 Nov): own small relay server only (no Firebase/Supabase; Cloudflare optional later);
  messages held encrypted only until delivered, then deleted; Apple + Google push for notifications.
- Login decided: **iPhone/iPad = Sign in with Apple only; Android = Sign in with Google only.**
  Our server verifies the Apple/Google token at login; they never see anything inside iTeam.
  Moving between iPhone and Android: "Move my account" by scanning a QR from the old phone (links both logins to one iTeam account).
- Hosting (25 Nov): online VPS, not home PC — leaning AWS Lightsail Mumbai $12 plan (2 GB/2 vCPU). No .exe:
  one Linux program (built-in SQLite + auto HTTPS), one setup command, auto-updates from GitHub, status page.
  Apps use the domain only (never the IP) so server moves/upgrades need no app update. Daily encrypted backup
  of the account list stored outside the server. Keep CloudKit working alongside during the switch.
- **Built 25 Nov: relay server program** in `relay/` (Go, standard library only, tests pass incl. fake Let's Encrypt).
  Setup script `relay/deploy/install.sh`, workflow `relay.yml` (manual; deploy=yes copies to server).
  **LIVE 25 Nov:** https://relay.iteamchat.in on AWS Lightsail Mumbai ($5 plan, 512 MB, static IP 13.200.78.128,
  auto snapshots on, AWS Free plan — upgrade AWS plan + server size before real users). Domain iteamchat.in
  (GoDaddy, renews 25 Nov 2027, ₹899/yr, DNSSEC on). Update = re-run bootstrap.sh (repo public for 5 min).
  Next: Apple push key + Firebase/Google client ID, then iTeam Next (iOS, separate app) + Android APK.
- Still to decide: domain, migration of current users, privacy policy + DPDP Act update.

## 5b. Follow-up reminders — add "Every year"
- Task follow-up / repeat options today: Never, Every day, Every week, Every month (`RepeatRule`).
  Add **Every year** (birthdays, renewals, yearly filings). Keep old values working (new case only).

## Marketing note (25 Nov)
- Meta ads paused (Business paused by Claude; Youth paused by Devendra in Ads Manager).
  Restart only after the new update is live. Adspirer calls reset 24 Dec — until then restart manually.

## 6. Already built, waiting for App Store
- 1.0.2 (build 86) on TestFlight: Care Medical, family on iTeam, People + claim, online dot/last seen/music, faster sending.
  Submit after 1.0.1 is approved.
- Tutorials screen in Settings (videos hosted on iteam-web, add new videos without app updates) — planned for 1.0.3.
