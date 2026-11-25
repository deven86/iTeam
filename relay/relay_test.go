package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakePusher struct {
	mu   sync.Mutex
	sent []PushMsg
	to   []string
}

func (f *fakePusher) Send(d *Device, m PushMsg) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, m)
	f.to = append(f.to, d.ID)
	return false, nil
}

func newTestServer(t *testing.T, dir string) (*Server, *httptest.Server, *fakePusher) {
	st, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	fp := &fakePusher{}
	s := &Server{st: st, dev: true, started: time.Now(), links: map[string]linkCode{},
		limiter: newLimiter(1000, 1000), statusToken: "secret", apple: NewApple(nil), google: NewGoogle(nil),
		claims: claims{m: map[string]*claimChallenge{}}}
	s.pushes = startPushWorkers(fp, 1, func(string) {})
	hs := httptest.NewServer(s.Routes())
	t.Cleanup(hs.Close)
	return s, hs, fp
}

type client struct {
	t     *testing.T
	base  string
	token string
	user  string
	dev   string
}

func (c *client) do(method, path string, in any, out any) int {
	c.t.Helper()
	var body io.Reader
	if b, ok := in.([]byte); ok {
		body = bytes.NewReader(b)
	} else if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, body)
	if c.token != "" {
		req.Header.Set("authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if out != nil {
		if bp, ok := out.(*[]byte); ok {
			*bp = rb
		} else {
			json.Unmarshal(rb, out)
		}
	}
	return resp.StatusCode
}

func login(t *testing.T, base, who, devID, platform, linkCode string) *client {
	c := &client{t: t, base: base}
	var out struct {
		Token, UserID, DeviceID string
		IsNew                   bool
	}
	code := c.do("POST", "/v1/login", map[string]any{"provider": "dev", "idToken": who, "linkCode": linkCode,
		"device": map[string]any{"id": devID, "platform": platform, "pushToken": "tok-" + devID}}, &out)
	if code != 200 {
		t.Fatalf("login %s: %d", who, code)
	}
	c.token, c.user, c.dev = out.Token, out.UserID, out.DeviceID
	return c
}

type inboxResp struct {
	Envelopes []envOut `json:"envelopes"`
	More      bool     `json:"more"`
}

func TestEndToEnd(t *testing.T) {
	dir := t.TempDir()
	s, hs, fp := newTestServer(t, dir)
	ira := login(t, hs.URL, "ira", "ira-iphone", "ios", "")
	kabir := login(t, hs.URL, "kabir", "kabir-pixel", "android", "")
	if ira.user == kabir.user {
		t.Fatal("same user")
	}
	// Same login again = same account.
	if again := login(t, hs.URL, "ira", "ira-iphone", "ios", ""); again.user != ira.user {
		t.Fatal("login not stable")
	}
	if c := ira.do("PUT", "/v1/me/profile", map[string]any{"name": "Ira", "pubkey": "PUBKEY-IRA"}, nil); c != 200 {
		t.Fatal("profile", c)
	}
	kabir.do("PUT", "/v1/me/profile", map[string]any{"name": "Kabir", "pubkey": "PUBKEY-KABIR"}, nil)
	var prof struct{ Profiles []profileOut }
	kabir.do("POST", "/v1/profiles", map[string]any{"ids": []string{ira.user, "nobody"}}, &prof)
	if len(prof.Profiles) != 1 || prof.Profiles[0].Name != "Ira" || prof.Profiles[0].PubKey != "PUBKEY-IRA" {
		t.Fatalf("profiles %+v", prof)
	}

	// Long-poll: Kabir waits, Ira sends, Kabir gets it at once.
	got := make(chan inboxResp, 1)
	go func() {
		var r inboxResp
		kabir.do("GET", "/v1/inbox?wait=10", nil, &r)
		got <- r
	}()
	time.Sleep(200 * time.Millisecond)
	var sr struct {
		Accepted []string
		Failed   map[string]string
	}
	start := time.Now()
	ira.do("POST", "/v1/send", map[string]any{"envelopes": []map[string]any{
		{"id": "EV01", "rcpt": kabir.user, "conv": "c1", "kind": 1, "loud": true, "body": []byte("cipher-1"), "hint": []byte("h")},
		{"id": "EV02", "rcpt": "u_nobody", "conv": "c1", "kind": 1, "body": []byte("x")},
	}}, &sr)
	if len(sr.Accepted) != 1 || sr.Failed["EV02"] == "" {
		t.Fatalf("send %+v", sr)
	}
	select {
	case r := <-got:
		if len(r.Envelopes) != 1 || string(r.Envelopes[0].Body) != "cipher-1" || r.Envelopes[0].Sndr != ira.user {
			t.Fatalf("inbox %+v", r)
		}
		if time.Since(start) > 2*time.Second {
			t.Fatal("long poll too slow")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long poll never woke")
	}
	// Sender cannot be faked: server sets sndr from the login.
	time.Sleep(100 * time.Millisecond)
	fp.mu.Lock()
	if len(fp.sent) != 1 || !fp.sent[0].Loud || fp.to[0] != "kabir-pixel" {
		t.Fatalf("push %+v %v", fp.sent, fp.to)
	}
	fp.mu.Unlock()

	// Retrying the same id is accepted once, not duplicated.
	ira.do("POST", "/v1/send", map[string]any{"envelopes": []map[string]any{{"id": "EV01", "rcpt": kabir.user, "body": []byte("cipher-1")}}}, &sr)
	var r inboxResp
	kabir.do("GET", "/v1/inbox", nil, &r)
	if len(r.Envelopes) != 1 {
		t.Fatalf("dup %d", len(r.Envelopes))
	}

	// Kabir's second device (tablet, moved with a code) must also receive before deletion.
	var lk struct{ Code string }
	kabir.do("POST", "/v1/link", nil, &lk)
	tab := login(t, hs.URL, "kabir-on-apple", "kabir-ipad", "ios", lk.Code)
	if tab.user != kabir.user {
		t.Fatal("move my account failed")
	}
	if c := (&client{t: t, base: hs.URL}).do("POST", "/v1/login", map[string]any{"provider": "dev", "idToken": "x", "linkCode": lk.Code,
		"device": map[string]any{"id": "d", "platform": "ios"}}, nil); c != 400 {
		t.Fatal("link code reused", c)
	}
	seq := r.Envelopes[0].Seq
	kabir.do("POST", "/v1/ack", map[string]any{"upTo": seq}, nil)
	s.st.mu.Lock()
	n := len(s.st.inbox[kabir.user])
	s.st.mu.Unlock()
	if n != 1 {
		t.Fatal("deleted before the tablet got it")
	}
	tab.do("GET", "/v1/inbox?after=0", nil, &r)
	if len(r.Envelopes) != 1 {
		t.Fatalf("tablet inbox %d", len(r.Envelopes))
	}
	tab.do("POST", "/v1/ack", map[string]any{"upTo": seq}, nil)
	s.st.mu.Lock()
	n = len(s.st.inbox[kabir.user])
	s.st.mu.Unlock()
	if n != 0 {
		t.Fatal("not deleted after every device got it")
	}

	// Encrypted file.
	file := bytes.Repeat([]byte("Z"), 300000)
	if c := ira.do("PUT", "/v1/blobs/B123456", file, nil); c != 200 {
		t.Fatal("blob put", c)
	}
	if c := kabir.do("PUT", "/v1/blobs/B123456", []byte("evil"), nil); c != 409 {
		t.Fatal("blob overwrite allowed", c)
	}
	var fb []byte
	kabir.do("GET", "/v1/blobs/B123456", nil, &fb)
	if !bytes.Equal(fb, file) {
		t.Fatal("blob mismatch")
	}

	// Presence.
	ira.do("PUT", "/v1/me/seen", map[string]any{"seen": time.Now()}, nil)
	kabir.do("POST", "/v1/profiles", map[string]any{"ids": []string{ira.user}, "seenOnly": true}, &prof)
	if prof.Profiles[0].Seen == nil || prof.Profiles[0].Name != "" {
		t.Fatal("seen")
	}

	// Unauthenticated.
	if c := (&client{t: t, base: hs.URL}).do("GET", "/v1/inbox", nil, nil); c != 401 {
		t.Fatal("no auth allowed")
	}

	// Status page.
	var st []byte
	(&client{t: t, base: hs.URL}).do("GET", "/status?token=secret", nil, &st)
	if !strings.Contains(string(st), "Accounts") {
		t.Fatal("status")
	}

	// Restart: everything survives (journal replay), then again from snapshot.
	ira.do("POST", "/v1/send", map[string]any{"envelopes": []map[string]any{{"id": "EV03", "rcpt": kabir.user, "body": []byte("after-restart")}}}, nil)
	s.st.journal.Close()
	_, hs2, _ := newTestServer(t, dir)
	kabir.base = hs2.URL
	kabir.do("GET", "/v1/inbox", nil, &r)
	if len(r.Envelopes) != 1 || string(r.Envelopes[0].Body) != "after-restart" {
		t.Fatalf("after restart %+v", r)
	}
	s2, _ := OpenStore(dir)
	s2.Close() // writes snapshot, empties journal
	s3, _ := OpenStore(dir)
	if s3.users[ira.user] == nil || s3.users[ira.user].Name != "Ira" || len(s3.inbox[kabir.user]) != 1 || s3.blobs["B123456"] == nil {
		t.Fatal("snapshot lost data")
	}
	s3.journal.Close()

	// Delete account removes everything of that user.
	_, hs4, _ := newTestServer(t, dir)
	ira.base = hs4.URL
	ira.do("DELETE", "/v1/me", nil, nil)
	if c := ira.do("GET", "/v1/inbox", nil, nil); c != 401 {
		t.Fatal("token alive after delete")
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", "B123456")); !os.IsNotExist(err) {
		t.Fatal("file kept after delete")
	}
}

func TestTornJournal(t *testing.T) {
	dir := t.TempDir()
	st, _ := OpenStore(dir)
	st.mu.Lock()
	st.write("user", User{ID: "u1", Name: "A"})
	st.mu.Unlock()
	st.journal.Write([]byte(`{"op":"user","d":{"id":"u2"`)) // power cut mid-line
	st.journal.Close()
	st2, err := OpenStore(dir)
	if err != nil || st2.users["u1"] == nil || st2.users["u2"] != nil {
		t.Fatalf("torn journal: %v", err)
	}
}

func TestExpiry(t *testing.T) {
	s, hs, _ := newTestServer(t, t.TempDir())
	a := login(t, hs.URL, "a", "a1", "ios", "")
	b := login(t, hs.URL, "b", "b1", "ios", "")
	a.do("POST", "/v1/send", map[string]any{"envelopes": []map[string]any{{"id": "EV01", "rcpt": b.user, "body": []byte("x")}}}, nil)
	a.do("PUT", "/v1/blobs/BLOB0001", []byte("data"), nil)
	s.sweep(time.Now().Add(31 * 24 * time.Hour))
	if len(s.st.inbox[b.user]) != 0 {
		t.Fatal("old envelope kept")
	}
	s.sweep(time.Now().Add(46 * 24 * time.Hour))
	if s.st.blobs["BLOB0001"] != nil {
		t.Fatal("old file kept")
	}
	if err := s.backup([]byte("k")); err != nil {
		t.Fatal(err)
	}
	if m, _ := filepath.Glob(filepath.Join(s.st.dir, "backups", "*.enc")); len(m) != 1 {
		t.Fatal("no encrypted backup")
	}
}

// ---------- Apple / Google token checks ----------

func signRS(t *testing.T, k *rsa.PrivateKey, kid string, claims map[string]any) string {
	h, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": kid})
	c, _ := json.Marshal(claims)
	in := b64u(h) + "." + b64u(c)
	sum := sha256.Sum256([]byte(in))
	sig, _ := rsa.SignPKCS1v15(rand.Reader, k, crypto.SHA256, sum[:])
	return in + "." + b64u(sig)
}

func TestAppleVerify(t *testing.T) {
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	jw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kid": "K1", "kty": "RSA",
			"n": b64u(k.N.Bytes()), "e": b64u(big.NewInt(int64(k.E)).Bytes())}}})
	}))
	defer jw.Close()
	p := NewApple([]string{"com.jondhale.iteam"})
	p.JWKSURL = jw.URL
	now := time.Now().Unix()
	good := map[string]any{"iss": "https://appleid.apple.com", "aud": "com.jondhale.iteam", "sub": "001.abc", "iat": now, "exp": now + 600}
	id, err := p.Verify(signRS(t, k, "K1", good))
	if err != nil || id.Sub != "001.abc" {
		t.Fatalf("good token: %v", err)
	}
	bad := func(name string, mod func(m map[string]any)) {
		m := map[string]any{}
		for k, v := range good {
			m[k] = v
		}
		mod(m)
		if _, err := p.Verify(signRS(t, k, "K1", m)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	bad("other app", func(m map[string]any) { m["aud"] = "com.evil.app" })
	bad("expired", func(m map[string]any) { m["exp"] = now - 3600 })
	bad("wrong issuer", func(m map[string]any) { m["iss"] = "https://evil.example" })
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	if _, err := p.Verify(signRS(t, other, "K1", good)); err == nil {
		t.Error("forged signature accepted")
	}
	g := NewGoogle([]string{"123.apps.googleusercontent.com"})
	g.JWKSURL = jw.URL
	gc := map[string]any{"iss": "https://accounts.google.com", "aud": "123.apps.googleusercontent.com", "sub": "g1", "iat": now, "exp": now + 600}
	if _, err := g.Verify(signRS(t, k, "K1", gc)); err != nil {
		t.Fatalf("google: %v", err)
	}
}

// ---------- push ----------

func TestAPNsAndFCM(t *testing.T) {
	dir := t.TempDir()
	ek, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(ek)
	os.WriteFile(filepath.Join(dir, "k.p8"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	var gotPath, gotType, gotAuth string
	var gotBody map[string]any
	ap := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotType, gotAuth = r.URL.Path, r.Header.Get("apns-push-type"), r.Header.Get("authorization")
		json.NewDecoder(r.Body).Decode(&gotBody)
		if strings.HasSuffix(r.URL.Path, "/dead") {
			w.WriteHeader(410)
		}
	}))
	defer ap.Close()
	a, err := NewAPNs(filepath.Join(dir, "k.p8"), "KEYID", "TEAMID", "com.jondhale.iteam")
	if err != nil {
		t.Fatal(err)
	}
	a.Host = ap.URL
	if _, err := a.Send(&Device{PushToken: "abc"}, PushMsg{Conv: "c", Sndr: "u", Hint: []byte("h"), Loud: true}); err != nil {
		t.Fatal(err)
	}
	if gotPath != "/3/device/abc" || gotType != "alert" || gotBody["hint"] != base64.StdEncoding.EncodeToString([]byte("h")) {
		t.Fatalf("apns request %s %s %v", gotPath, gotType, gotBody)
	}
	// JWT is a valid ES256 signature by our key.
	parts := strings.Split(strings.TrimPrefix(gotAuth, "bearer "), ".")
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(&ek.PublicKey, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("apns jwt signature invalid")
	}
	if gone, _ := a.Send(&Device{PushToken: "dead"}, PushMsg{}); !gone {
		t.Fatal("410 not treated as gone")
	}

	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	rder, _ := x509.MarshalPKCS8PrivateKey(rk)
	var fcmData map[string]any
	fs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			r.ParseForm()
			parts := strings.Split(r.Form.Get("assertion"), ".")
			sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
			sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			if rsa.VerifyPKCS1v15(&rk.PublicKey, crypto.SHA256, sum[:], sig) != nil {
				w.WriteHeader(401)
				return
			}
			fmt.Fprint(w, `{"access_token":"AT","expires_in":3600}`)
			return
		}
		if r.Header.Get("authorization") != "Bearer AT" || r.URL.Path != "/v1/projects/proj/messages:send" {
			w.WriteHeader(403)
			return
		}
		json.NewDecoder(r.Body).Decode(&fcmData)
	}))
	defer fs.Close()
	sa, _ := json.Marshal(map[string]string{"project_id": "proj", "client_email": "x@proj.iam", "token_uri": fs.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: rder}))})
	os.WriteFile(filepath.Join(dir, "sa.json"), sa, 0o600)
	f, err := NewFCM(filepath.Join(dir, "sa.json"))
	if err != nil {
		t.Fatal(err)
	}
	f.BaseURL = fs.URL
	if _, err := f.Send(&Device{PushToken: "fcmtok"}, PushMsg{Conv: "c", Loud: true}); err != nil {
		t.Fatal(err)
	}
	msg := fcmData["message"].(map[string]any)
	if msg["token"] != "fcmtok" || msg["data"].(map[string]any)["loud"] != "1" {
		t.Fatalf("fcm body %v", fcmData)
	}
}
