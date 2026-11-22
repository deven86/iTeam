"""Turns on Game Center for iTeam in App Store Connect and creates the Fluffy Fight wins leaderboard."""
import os, time, json, jwt, requests
E = os.environ
API = "https://api.appstoreconnect.apple.com/v1"
def tok():
    k = open(E["ASC_KEY_PATH"]).read(); n = int(time.time())
    return jwt.encode({"iss": E["ASC_ISSUER_ID"], "iat": n, "exp": n + 1100, "aud": "appstoreconnect-v1"}, k,
                      algorithm="ES256", headers={"kid": E["ASC_KEY_ID"], "typ": "JWT"})
def call(m, path, body=None):
    r = requests.request(m, API + path, headers={"Authorization": f"Bearer {tok()}", "Content-Type": "application/json"},
                         data=json.dumps(body) if body is not None else None)
    if r.status_code >= 300: print(f"::warning title=api::{m} {path.split('?')[0]} → {r.status_code}: {r.text[:600]}"); return None
    return r.json() if r.text else {}
def note(t, m): print(f"::notice title={t}::{m}")

aid = call("GET", "/apps?filter[bundleId]=com.jondhale.iteam")["data"][0]["id"]
# The App ID needs the Game Center capability (then run Signing setup with force).
bid = next(b["id"] for b in call("GET", "/bundleIds?filter[identifier]=com.jondhale.iteam&limit=20")["data"]
           if b["attributes"]["identifier"] == "com.jondhale.iteam")
caps = [c["attributes"]["capabilityType"] for c in (call("GET", f"/bundleIds/{bid}/bundleIdCapabilities") or {}).get("data", [])]
if "GAME_CENTER" not in caps:
    if call("POST", "/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities", "attributes": {"capabilityType": "GAME_CENTER"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}}): note("app id", "Game Center capability added")
else: note("app id", "Game Center capability already on")
gc = (call("GET", f"/apps/{aid}/gameCenterDetail") or {}).get("data")
if not gc:
    gc = (call("POST", "/gameCenterDetails", {"data": {"type": "gameCenterDetails", "attributes": {},
          "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}}) or {}).get("data")
if not gc: raise SystemExit("Could not turn on Game Center")
gid = gc["id"]; note("game center", f"on ({gid})")

boards = (call("GET", f"/gameCenterDetails/{gid}/gameCenterLeaderboards?limit=50") or {}).get("data", [])
lb = next((b for b in boards if b["attributes"].get("vendorIdentifier") == "iteam.fight.wins"), None)
if not lb:
    lb = (call("POST", "/gameCenterLeaderboards", {"data": {"type": "gameCenterLeaderboards", "attributes": {
        "defaultFormatter": "INTEGER", "referenceName": "Fluffy Fight wins", "vendorIdentifier": "iteam.fight.wins",
        "submissionType": "BEST_SCORE", "scoreSortType": "DESC"},
        "relationships": {"gameCenterDetail": {"data": {"type": "gameCenterDetails", "id": gid}}}}}) or {}).get("data")
if lb:
    lid = lb["id"]; note("leaderboard", f"iteam.fight.wins ({lid})")
    locs = (call("GET", f"/gameCenterLeaderboards/{lid}/localizations") or {}).get("data", [])
    if not locs:
        call("POST", "/gameCenterLeaderboardLocalizations", {"data": {"type": "gameCenterLeaderboardLocalizations", "attributes": {
            "locale": "en-US", "name": "Fluffy Fight wins", "formatterSuffix": " wins", "formatterSuffixSingular": " win"},
            "relationships": {"gameCenterLeaderboard": {"data": {"type": "gameCenterLeaderboards", "id": lid}}}}})
# Attach Game Center to the version being prepared, so it ships with the release.
vers = (call("GET", f"/apps/{aid}/appStoreVersions?filter[appStoreState]=PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED") or {}).get("data", [])
for v in vers:
    r = call("POST", "/gameCenterAppVersions", {"data": {"type": "gameCenterAppVersions",
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
    if r: note("version", f"Game Center enabled for {v['attributes']['versionString']}")
