#!/usr/bin/env python3
"""Sets up TestFlight external testing with a public link (App Store Connect API).

Creates/updates: Test Information, Beta review contact, the "Friends" external group with a
public link, adds the newest processed build, sets "What to test", and submits it to Beta App Review.
Prints the public link. Safe to run again (each step skips what already exists).
"""
import json, os, sys, time, urllib.request, urllib.error
import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE = "com.jondhale.iteam"
GROUP = "Friends"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


TOKEN = token()


def call(method, path, body=None, ok=(200, 201, 204)):
    url = path if path.startswith("http") else API + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        if e.code in ok:
            return e.code, {}
        return e.code, {"error": raw}


def must(status, data, what):
    if status >= 300:
        detail = data.get("error", "")
        try:
            errs = json.loads(detail).get("errors", [])
            detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errs)
        except Exception:
            pass
        print(f"::error title={what}::{status} {detail[:900]}")
        sys.exit(1)
    return data


def note(title, msg):
    print(f"::notice title={title}::{msg}")


email = os.environ.get("CONTACT_EMAIL") or "deven86@me.com"
phone = os.environ.get("CONTACT_PHONE", "").strip()
if not phone:
    print("::error title=phone::Add the repository secret BETA_CONTACT_PHONE (your phone with country code, e.g. +91…). Apple's beta reviewers need a contact number.")
    sys.exit(1)

# App
s, d = call("GET", f"/apps?filter[bundleId]={BUNDLE}")
apps = must(s, d, "app")["data"]
if not apps:
    print("::error title=app::App not found in App Store Connect"); sys.exit(1)
app = apps[0]["id"]

# Test information (English)
desc = ("iTeam is a private, chat-first app for families, friends and small teams. Chat 1:1 and in groups, "
        "assign tasks, share mini (24-hour) photos and videos, and add modules like Care, Gym and Mindfulness. "
        "Messages are end-to-end encrypted and sync through iCloud.")
s, d = call("GET", f"/apps/{app}/betaAppLocalizations")
locs = must(s, d, "localizations")["data"]
attrs = {"description": desc, "feedbackEmail": email}
en = next((l for l in locs if l["attributes"]["locale"].startswith("en")), None)
if en:
    must(*call("PATCH", f"/betaAppLocalizations/{en['id']}", {"data": {"type": "betaAppLocalizations", "id": en["id"], "attributes": attrs}}), "test info")
else:
    must(*call("POST", "/betaAppLocalizations", {"data": {"type": "betaAppLocalizations", "attributes": {**attrs, "locale": "en-US"},
                                                         "relationships": {"app": {"data": {"type": "apps", "id": app}}}}}), "test info")
note("step", "Test information saved")

# Beta review contact
s, d = call("GET", f"/apps/{app}/betaAppReviewDetail")
rid = must(s, d, "review detail")["data"]["id"]
must(*call("PATCH", f"/betaAppReviewDetails/{rid}", {"data": {"type": "betaAppReviewDetails", "id": rid, "attributes": {
    "contactFirstName": "Devendra", "contactLastName": "Jondhale", "contactEmail": email, "contactPhone": phone,
    "demoAccountRequired": False,
    "notes": "Sign in with Apple only — no demo account needed. Tap 'Try a demo team chat' on the Chats screen to see chats, tasks and modules without a second person."}}}), "review contact")
note("step", "Beta review contact saved")

# External group with public link
s, d = call("GET", f"/betaGroups?filter[app]={app}&filter[name]={GROUP}")
groups = must(s, d, "groups")["data"]
if groups:
    gid = groups[0]["id"]
    must(*call("PATCH", f"/betaGroups/{gid}", {"data": {"type": "betaGroups", "id": gid, "attributes": {
        "publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True}}}), "group")
else:
    s, d = call("POST", "/betaGroups", {"data": {"type": "betaGroups", "attributes": {
        "name": GROUP, "publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
    gid = must(s, d, "group")["data"]["id"]
note("step", f"External group '{GROUP}' ready")

# Newest processed build
s, d = call("GET", f"/builds?filter[app]={app}&filter[processingState]=VALID&sort=-uploadedDate&limit=1")
builds = must(s, d, "builds")["data"]
if not builds:
    print("::error title=build::No processed build yet — wait for TestFlight processing to finish and run again."); sys.exit(1)
build = builds[0]["id"]
bver = builds[0]["attributes"].get("version")
if builds[0]["attributes"].get("usesNonExemptEncryption") is None:
    call("PATCH", f"/builds/{build}", {"data": {"type": "builds", "id": build, "attributes": {"usesNonExemptEncryption": False}}})

s, d = call("GET", f"/builds/{build}/buildBetaDetail")
if s < 300:
    a = d["data"]["attributes"]
    note("build state", f"build {bver}: internal={a.get('internalBuildState')} external={a.get('externalBuildState')}")
s, d = call("GET", f"/builds?filter[app]={app}&sort=-uploadedDate&limit=4")
if s < 300:
    note("recent builds", ", ".join(f"{b['attributes'].get('version')}:{b['attributes'].get('processingState')}" for b in d["data"]))

# What to test
s, d = call("GET", f"/builds/{build}/betaBuildLocalizations")
if not must(s, d, "what to test")["data"]:
    call("POST", "/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US",
        "whatsNew": "Please try: chatting 1:1 and in groups, voice notes, tasks (assign, accept, complete), mini (24-hour status), Views posts, iCloud Backup in Settings, and notifications while the app is closed. Send feedback with a screenshot from TestFlight."},
        "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})

must(*call("POST", f"/betaGroups/{gid}/relationships/builds", {"data": [{"type": "builds", "id": build}]}, ok=(204, 409)), "add build")
note("step", f"Build {bver} added to '{GROUP}'")

# Submit for Beta App Review
s, d = call("POST", "/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
if s in (200, 201):
    note("review", f"Build {bver} submitted to Beta App Review (usually under 24 h)")
elif s == 409 or "already" in d.get("error", "").lower():
    note("review", f"Build {bver} is already submitted or approved")
else:
    print(f"::warning title=review::Build {bver} can't be submitted yet ({s}). It is probably still processing — run this again in 15 minutes.")

s, d = call("GET", f"/betaGroups/{gid}")
link = must(s, d, "group")["data"]["attributes"].get("publicLink")
note("PUBLIC LINK", link or "not created yet — run again in a minute")
