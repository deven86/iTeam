# iTeam relay

Store-and-forward server for end-to-end encrypted iTeam messages (iPhone/iPad ↔ Android).
One Go program, standard library only — no database server, no Docker, no third-party libraries.

- **Holds:** account list (user id, public key, name, photo, push tokens), encrypted envelopes until
  every device of the recipient has them (then deleted; 30-day limit), encrypted files (45-day limit).
- **Cannot read:** any message, file or preview — all encrypted on the phones.
- **Login:** Sign in with Apple (iOS) / Sign in with Google (Android); "Move my account" link codes.
- **Push:** APNs (.p8 key) and FCM HTTP v1 (service account). Payloads carry only encrypted hints.
- **HTTPS:** built-in Let's Encrypt client, auto-renewal. **Backups:** daily, AES-256-GCM, last 14 kept.
- **Status page:** `/status` (public: ok) and `/status?token=STATUS_TOKEN` (counts, disk, last backup).

## API (JSON, bearer token)
| Call | Purpose |
|---|---|
| `POST /v1/login` | `{provider: apple|google, idToken, linkCode?, device:{id, platform, pushToken, sandbox}}` → token, userID |
| `POST /v1/link` | one-time "Move my account" code (10 min) |
| `PUT /v1/me/profile` · `PUT /v1/me/seen` · `PUT /v1/me/device` | profile, last seen (null = hidden), push token |
| `POST /v1/profiles` | `{ids, seenOnly?}` public keys, names, photos, last seen |
| `POST /v1/send` | up to 300 envelopes `{id, rcpt, conv, kind, loud, body, hint}`; sender is set by the server |
| `GET /v1/inbox?after=&wait=` | new envelopes; `wait` (≤55 s) holds the request for instant delivery |
| `POST /v1/ack` | `{upTo}` this device has stored everything up to seq |
| `PUT/GET /v1/blobs/{id}` | encrypted files, 100 MB max |
| `DELETE /v1/me` | delete account and everything stored for it |

## Run
- Test: `go test -race ./...` · Local: `RELAY_DEV=1 RELAY_DATA=/tmp/r go run .` (plain HTTP on :8080).
- Server: `sudo sh deploy/install.sh relay.example.com you@email.com`, then run the **Relay server**
  workflow with deploy=yes (secrets `RELAY_HOST`, `RELAY_SSH_KEY`).

## Not done yet (needs the app side)
- Migrating current CloudKit users to keep their user id; sealed sender; off-server backup copy (S3).
