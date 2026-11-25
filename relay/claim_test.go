package main

import (
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClaimLegacyID(t *testing.T) {
	phoneKey, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pub := base64.StdEncoding.EncodeToString(phoneKey.PublicKey().Bytes())
	ck := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("ckAPIToken") != "TOK" {
			w.WriteHeader(401)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"records": []any{map[string]any{"fields": map[string]any{
			"name": map[string]any{"value": "Devendra"}, "pubkey": map[string]any{"value": pub}}}}})
	}))
	defer ck.Close()
	s, hs, _ := newTestServer(t, t.TempDir())
	s.ck = &CloudKitReader{Base: ck.URL, Token: "TOK"}
	c := &client{t: t, base: hs.URL}

	start := func() (string, []byte) {
		var o struct{ ChallengeID, ServerKey string }
		if code := c.do("POST", "/v1/claim/start", map[string]string{"legacyID": "_abc123legacy"}, &o); code != 200 {
			t.Fatalf("start %d", code)
		}
		k, _ := base64.StdEncoding.DecodeString(o.ServerKey)
		return o.ChallengeID, k
	}
	proof := func(key *ecdh.PrivateKey, id string, serverKey []byte) string {
		sp, _ := ecdh.X25519().NewPublicKey(serverKey)
		shared, _ := key.ECDH(sp)
		m := hmac.New(sha256.New, shared)
		m.Write([]byte("iteam-claim|" + id + "|_abc123legacy"))
		return base64.StdEncoding.EncodeToString(m.Sum(nil))
	}
	login := func(who, id, pr string) (int, string) {
		var o struct{ UserID string }
		code := c.do("POST", "/v1/login", map[string]any{"provider": "dev", "idToken": who,
			"device": map[string]any{"id": "dev-" + who, "platform": "ios"}, "claim": map[string]string{"challengeID": id, "proof": pr}}, &o)
		return code, o.UserID
	}
	// Wrong key: refused.
	thief, _ := ecdh.X25519().GenerateKey(rand.Reader)
	id, sk := start()
	if code, _ := login("thief", id, proof(thief, id, sk)); code != 401 {
		t.Fatalf("thief got %d", code)
	}
	// Right key: same ID, profile copied from iCloud.
	id, sk = start()
	code, uid := login("owner", id, proof(phoneKey, id, sk))
	if code != 200 || uid != "_abc123legacy" {
		t.Fatalf("owner %d %s", code, uid)
	}
	if u := s.st.users["_abc123legacy"]; u == nil || u.Name != "Devendra" || u.PubKey != pub {
		t.Fatal("profile not copied")
	}
	// Challenge can't be reused.
	if code, _ := login("owner", id, proof(phoneKey, id, sk)); code != 401 {
		t.Fatal("challenge reused")
	}
	// Later logins with the same Apple account land on the same ID without a claim.
	if again := login2(t, hs.URL, "owner"); again != "_abc123legacy" {
		t.Fatalf("relogin %s", again)
	}
}

func login2(t *testing.T, base, who string) string {
	return login(t, base, who, "dev2-"+who, "ios", "").user
}
