# iTeam on Google Play — launch kit (personal account)

## Timeline
1. **Day 0** — Create the Play Console account (US$25, ID verification). Create the app, fill in the listing below.
2. **Day 0–1** — Run the **Android Play bundle** workflow → download `iTeam-play-bundle` → Play Console → *Test and release → Closed testing* → create a track, add testers, upload the `.aab`.
3. **Day 1–15** — Keep **at least 12 testers** opted in for **14 days in a row** (invite 15–20 in case some drop out). They install from the Play opt-in link and should actually use the app.
4. **Day 15** — *Apply for production access* (questions about the test). Review takes a few days.
5. **Launch** — Promote the release to Production. Then set `playLive: true` on the download page.

## Store listing
**App name (30):** iTeam: Chat, Tasks & Business
**Short description (80):** Encrypted chat, team tasks, attendance, finance, CRM & family safety. No ads.

**Full description:**
iTeam brings your chats, your team's work and your business together in one private app — with no ads and no tracking.

💬 PRIVATE CHAT
• End-to-end encrypted messages, photos, files and voice notes
• Groups, polls, reactions, replies, view-once photos and disappearing messages
• ✨ Magic moment: write now, it appears on their phone at the time you choose
• No phone number needed — chat with friends on Android, iPhone and iPad

✅ TASKS THAT GET DONE
• Assign tasks that people accept or decline
• Follow-up reminders, checklists, approvals, expenses and files
• Meetings with agenda, attendance, polls and minutes
• My Day: everything due today in one list

🏢 RUN YOUR BUSINESS — all free on Android
• Attendance: punch in/out, leave, holidays and monthly register
• Finance: income, expenses, dues and approvals
• CRM: leads, pipeline, follow-ups and quotes your client accepts
• Khata, Rent, Tuition, Legal, Clinic, Bills, Kids, Travel and Pet Care records
• Builder & Infra: projects, units, sales, stock with QR codes, approvals and an FSI calculator
• Housing Society and Gym & Training
• Branded PDF reports for every module

👨‍👩‍👧 FAMILY & SAFETY
• Hold-to-send SOS with your location to the chats you choose
• Check In: let family know when you've arrived
• Care: family medicines with Taken / Skip and reminders
• Doctor & Patient prescriptions, events with RSVPs and shared albums

🌍 ROOMS
Chat with people across the world under a room name you choose. Reveal who you are only when both of you agree.

🔒 PRIVACY
iTeam has no servers of its own. Messages travel end-to-end encrypted through Apple's iCloud and are deleted after 45 days; your chats live on your phone. Sign in uses a free Apple Account.

**Category:** Communication · **Tags:** Messaging, Productivity, Business
**Contact email:** deven86@me.com · **Website:** https://deven86.github.io/iTeam/
**Privacy policy:** https://github.com/deven86/iTeam/blob/main/PRIVACY.md

## Graphics
- App icon 512×512: `icon-512.png`
- Feature graphic 1024×500: `feature-graphic-1024x500.png`
- Phone screenshots: 2–8, take them on your Android phone (Chats, a task, Attendance, Builder, SOS, My Day).

## App content answers
- **App access:** sign-in required → give Google a *demo Apple Account* (email + password) made just for review, with 2-step verification that won't block them. Enter it only in Play Console.
- **Ads:** No ads.
- **Content rating:** Communication app; users can talk to each other and share location/photos → answer *Yes* to user interaction, sharing location.
- **Target audience:** 18+ (business, Rooms with strangers).
- **News app:** No. **Government app:** No. **Financial features:** No (records only, no payments).
- **Account deletion:** in-app *Settings → Delete my account*; web: https://deven86.github.io/iTeam/#delete-account

## Data safety (draft — check each answer in the form)
- **Encrypted in transit:** Yes. **Users can request deletion:** Yes.
- **Messages, photos, files, voice notes, tasks, records:** sent end-to-end encrypted — Google allows E2E-encrypted data to be left out of "collected"; say so.
- **Name, profile photo (optional):** collected → App functionality, shared with Apple (iCloud host) as a service provider.
- **Email:** read at Apple sign-in, stays on the phone → not collected.
- **Approximate location:** collected only when you use Nearby (public listing you choose), SOS/Check In (sent E2E to chats you pick) → optional, App functionality.
- **Grievances & module requests:** user-generated content, not E2E → collected, App functionality / Support.
- **No** analytics, advertising IDs, contacts, SMS, call logs or health data.

## After launch
- Sideloaded APK users: the Play version is signed by Google, so they must **uninstall the APK and install from Play once** (local chats on that phone are lost; contacts can resend). Do this switch early, while few people use the APK.
- Every update: run **Android Play bundle** → upload the `.aab` to Production.
