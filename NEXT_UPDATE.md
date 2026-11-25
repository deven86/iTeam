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
- Needs a decision on: hosting cost, login method (not Apple ID), migration plan, privacy policy + DPDP Act update.

## 6. Already built, waiting for App Store
- 1.0.2 (build 86) on TestFlight: Care Medical, family on iTeam, People + claim, online dot/last seen/music, faster sending.
  Submit after 1.0.1 is approved.
- Tutorials screen in Settings (videos hosted on iteam-web, add new videos without app updates) — planned for 1.0.3.
