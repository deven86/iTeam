# iTeam roadmap — requested 27 Nov 2026 (Devendra)
Rule: whatever iOS has, Android must have too (full UI/UX). Android look: violet, rounded cards,
group-task cards (ref: task app), graphs with card effect (ref: Zenvest).

## Batch 1 (27 Nov) — done
- [x] Chats: "waiting to sync" moved to Settings; replaced by latest 10 unseen activities (tap = open, next one slides in)
- [x] iOS + Android TestFlight/APK with relay bridge, Violet Android look

## Batch 2 — notifications & speed (27 Nov: push live, instant media, link fix, presence done)
- [x] Apple push from relay (needs APNs .p8 key: Key ID + Team ID) → instant iPhone alerts for Android messages
- [ ] Android: instant FCM (done) — verify on device
- [x] Media: send instantly as a preview, full photo/document downloads only when tapped (both)
- [x] Online dot (red, as requested) + last seen + now playing in chat header — Android parity

## Batch 3 — backup + adding people (both)
- [x] Android encrypted backup & restore (Google Drive / any "Save to" app), daily auto backup
- [x] Paste-link add iPhone⇄Android (fix), Nearby across platforms, QR (works)
- [x] Share a contact (Recommend a contact on Android, tap to add)
- [x] Group join consent: "members can see and add you; private messages only after they're added"
- [x] @mention suggestions in groups (both)
- [x] Broadcast list (up to 200 people)

## Batch 4 — Android dashboards (match iOS)
- [x] Tasks dashboard with violet group-task cards + weekly chart
- [x] Attendance dashboard  - [x] Finance + violet tiles in all modules
- [x] Android Settings: Google wording; backup to Google Drive / other

## Batch 5 — modules
- [x] Attendance: admin daily QR (new every day), punch in/out by scanning, selfie (both)
- [x] Tasks yearly repeat with reminders: 1 month, 15 days, 1 week, 1 day, 1 hour before; after expiry 1 day,
      daily till renewed, 1 week, 15 days, 1 month — multi-select
- [x] X and O real-time (board checks every 2 s on both)
- [x] Above mini: last seen / online now / recent activity strip (scroll or tabs, tappable)

## Batch 6 — onboarding
- [x] Appearance setup step
- [x] "How to add members" step

## Batch 7 — 27 Nov list
- [x] Attendance: punch-in AND punch-out selfie kept; owner sets "keep photos" (default 60 days), auto-delete daily (both)
- [x] Android activity strip above chats (like iPhone)
- [x] iOS chat list: tighter spacing; mini between Chats/Rooms and the filters; add-person icon instead of scanner
- [ ] Gym (iOS): manual walk/run/cycle entry; walk that "disappeared" fix; body tests from iLife (full)
- [ ] Mind: keep music playing when phone locks (background audio), Live Activity timer, ask to turn on Focus/DND, manual meditation entry
- [ ] Recently asked questions (FAQ) in Settings
- [ ] Group join: show "members (incl. future) can see/add you; private chat only after they add you" — check exact wording at accept
- [ ] Invite to iTeam (share sheet + link) everywhere
- [ ] Crush: secret hearts, counter + "revealed" list with both timestamps, match blast (18+ only, private)
- [ ] Referral badges (5 active users / 1, 3, 10 active teams) — no cash; count only active users
- [ ] Smart "recommend iTeam" prompts (first task done, group made, project finished, 1 week active) — once each
- [ ] "Has iTeam helped?" → share / invite team / App Store review (Apple's review prompt)
- [ ] Referral analytics on our server (invites, opens, joins, active users/team, teams from referrals, 7/30-day retention, K = new active teams per team)
- [ ] Attendance QR scan code re-check
- [ ] Digital business card with team-invite QR
- [ ] "Made with iTeam" footer on all PDFs/shares (switch off per export) + "Continue this work in iTeam" link
- [ ] iTeam Moments (milestones, project done, monthly recap, anniversary, welcome, streaks)
- [ ] Rooms: welcome/sample posts — must be clearly labelled "iTeam Team / sample", NOT fake users (Apple 1.1.6 / 5.6)
- [ ] Trademark check (no "WhatsApp"/Apple marks in name, icon, screenshots, ads)

## Big projects (need a plan + your OK first)
- [ ] In-app voice/video calls on our server (WebRTC + TURN; server bandwidth cost grows with use)
- [ ] Web app
- [ ] Feature map FEATURES.md (every screen, both apps) → then multi-language

## Last
- [ ] App Store submission (after testing)
