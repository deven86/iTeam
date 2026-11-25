package main

// HTTP API used by the iPhone/iPad and Android apps. JSON in and out; []byte fields
// travel as standard base64. Every call except /v1/login needs "Authorization: Bearer <token>".

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxEnvelope   = 256 << 10 // encrypted event body
	maxHint       = 4 << 10
	maxPic        = 300 << 10
	maxBlob       = 100 << 20 // one encrypted file
	maxBatch      = 300
	envelopeTTL   = 30 * 24 * time.Hour
	blobTTL       = 45 * 24 * time.Hour
	deviceIdleTTL = 60 * 24 * time.Hour
)

var idRe = regexp.MustCompile(`^[A-Za-z0-9_.:\-]{4,120}$`)

type Server struct {
	st          *Store
	apple       *Provider
	google      *Provider
	dev         bool // allows provider "dev" logins for local testing only
	pushes      chan<- pushJob
	started     time.Time
	statusToken string

	linkMu sync.Mutex
	links  map[string]linkCode

	limiter *limiter
}

type linkCode struct {
	user    string
	expires time.Time
}

func randID(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func readJSON(r *http.Request, limit int64, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, limit)).Decode(v)
}

func clientIP(r *http.Request) string {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

func (s *Server) Routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	m.HandleFunc("GET /status", s.status)
	m.HandleFunc("POST /v1/login", s.login)
	m.HandleFunc("POST /v1/logout", s.auth(s.logout))
	m.HandleFunc("POST /v1/link", s.auth(s.link))
	m.HandleFunc("PUT /v1/me/profile", s.auth(s.putProfile))
	m.HandleFunc("PUT /v1/me/seen", s.auth(s.putSeen))
	m.HandleFunc("PUT /v1/me/device", s.auth(s.putDevice))
	m.HandleFunc("DELETE /v1/me", s.auth(s.deleteMe))
	m.HandleFunc("POST /v1/profiles", s.auth(s.profiles))
	m.HandleFunc("POST /v1/send", s.auth(s.send))
	m.HandleFunc("GET /v1/inbox", s.auth(s.inboxH))
	m.HandleFunc("POST /v1/ack", s.auth(s.ack))
	m.HandleFunc("PUT /v1/blobs/{id}", s.auth(s.putBlob))
	m.HandleFunc("GET /v1/blobs/{id}", s.auth(s.getBlob))
	return s.limit(m)
}

func (s *Server) limit(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cost := 1.0
		if r.URL.Path == "/v1/login" {
			cost = 10
		}
		if !s.limiter.allow(clientIP(r), cost) {
			fail(w, 429, "slow down")
			return
		}
		w.Header().Set("x-content-type-options", "nosniff")
		h.ServeHTTP(w, r)
	})
}

type ctxAuth struct {
	user   string
	device string
	hash   string
}

type authedFunc func(w http.ResponseWriter, r *http.Request, a ctxAuth)

func (s *Server) auth(f authedFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("authorization"), "Bearer ")
		if tok == "" || tok == r.Header.Get("authorization") {
			fail(w, 401, "sign in needed")
			return
		}
		h := hashToken(tok)
		s.st.mu.Lock()
		ses := s.st.sessions[h]
		var a ctxAuth
		if ses != nil {
			a = ctxAuth{user: ses.UserID, device: ses.DeviceID, hash: h}
			if d := s.st.devices[ses.DeviceID]; d != nil && time.Since(d.LastActive) > time.Hour {
				s.st.write("ack", ackOp{Device: d.ID, Cursor: d.Cursor, At: time.Now().UTC()})
			}
		}
		s.st.mu.Unlock()
		if ses == nil {
			fail(w, 401, "signed out")
			return
		}
		f(w, r, a)
	}
}

// ---------- login ----------

type deviceIn struct {
	ID        string `json:"id"`
	Platform  string `json:"platform"`
	PushToken string `json:"pushToken"`
	Sandbox   bool   `json:"sandbox"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Provider string   `json:"provider"`
		IDToken  string   `json:"idToken"`
		LinkCode string   `json:"linkCode"`
		Device   deviceIn `json:"device"`
	}
	if err := readJSON(r, 64<<10, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	var key string
	switch in.Provider {
	case "apple", "google":
		p := s.apple
		if in.Provider == "google" {
			p = s.google
		}
		if p == nil || len(p.Audiences) == 0 {
			fail(w, 400, in.Provider+" sign-in is not set up")
			return
		}
		id, err := p.Verify(in.IDToken)
		if err != nil {
			fail(w, 401, "sign-in failed: "+err.Error())
			return
		}
		key = in.Provider + ":" + id.Sub
	case "dev":
		if !s.dev || in.IDToken == "" {
			fail(w, 400, "unknown provider")
			return
		}
		key = "dev:" + in.IDToken
	default:
		fail(w, 400, "unknown provider")
		return
	}
	if in.Device.Platform != "ios" && in.Device.Platform != "android" {
		fail(w, 400, "device.platform must be ios or android")
		return
	}
	if !idRe.MatchString(in.Device.ID) {
		in.Device.ID = randID(12)
	}

	// Link code (from "Move my account") attaches this new login to an existing account.
	var linkUser string
	if in.LinkCode != "" {
		s.linkMu.Lock()
		lc, ok := s.links[in.LinkCode]
		if ok {
			delete(s.links, in.LinkCode)
		}
		s.linkMu.Unlock()
		if !ok || time.Now().After(lc.expires) {
			fail(w, 400, "move code expired — make a new one on your old phone")
			return
		}
		linkUser = lc.user
	}

	st := s.st
	st.mu.Lock()
	defer st.mu.Unlock()
	userID, known := st.idents[key]
	isNew := false
	if linkUser != "" {
		if known && userID != linkUser {
			fail(w, 409, "this login already belongs to another iTeam account")
			return
		}
		if st.users[linkUser] == nil {
			fail(w, 400, "account not found")
			return
		}
		userID = linkUser
		if !known {
			st.write("ident", identOp{Key: key, User: userID})
		}
	} else if !known {
		userID = "u_" + randID(15)
		isNew = true
		st.write("user", User{ID: userID, Created: time.Now().UTC()})
		st.write("ident", identOp{Key: key, User: userID})
	}
	// A device id belongs to one account. Someone else's id is replaced.
	if d := st.devices[in.Device.ID]; d != nil && d.UserID != userID {
		in.Device.ID = randID(12)
	}
	dev := Device{ID: in.Device.ID, UserID: userID, Platform: in.Device.Platform,
		PushToken: in.Device.PushToken, Sandbox: in.Device.Sandbox, LastActive: time.Now().UTC()}
	if old := st.devices[dev.ID]; old != nil {
		dev.Cursor = old.Cursor
	}
	st.write("device", dev)
	tok := randID(32)
	st.write("session", Session{Hash: hashToken(tok), UserID: userID, DeviceID: dev.ID, Created: time.Now().UTC()})
	writeJSON(w, 200, map[string]any{"token": tok, "userID": userID, "deviceID": dev.ID, "isNew": isNew})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	s.st.mu.Lock()
	s.st.write("unsession", a.hash)
	s.st.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) link(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	code := strings.ToUpper(randID(9))
	code = strings.NewReplacer("-", "X", "_", "Y").Replace(code)
	s.linkMu.Lock()
	for k, v := range s.links {
		if time.Now().After(v.expires) {
			delete(s.links, k)
		}
	}
	s.links[code] = linkCode{user: a.user, expires: time.Now().Add(10 * time.Minute)}
	s.linkMu.Unlock()
	writeJSON(w, 200, map[string]any{"code": code, "expiresIn": 600})
}

// ---------- profile & presence ----------

type profileOut struct {
	UserID string     `json:"userID"`
	Name   string     `json:"name"`
	PubKey string     `json:"pubkey"`
	Pic    []byte     `json:"pic,omitempty"`
	Plus   bool       `json:"plus"`
	QR     string     `json:"qr,omitempty"`
	Seen   *time.Time `json:"seen,omitempty"`
}

func (s *Server) putProfile(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		Name   *string `json:"name"`
		PubKey *string `json:"pubkey"`
		Pic    *[]byte `json:"pic"`
		Plus   *bool   `json:"plus"`
		QR     *string `json:"qr"`
	}
	if err := readJSON(r, maxPic*2, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	s.st.mu.Lock()
	defer s.st.mu.Unlock()
	u := *s.st.users[a.user]
	if in.Name != nil {
		u.Name = trim(*in.Name, 80)
	}
	if in.PubKey != nil {
		u.PubKey = trim(*in.PubKey, 200)
	}
	if in.Pic != nil {
		if len(*in.Pic) > maxPic {
			fail(w, 413, "photo too large")
			return
		}
		u.Pic = *in.Pic
	}
	if in.Plus != nil {
		u.Plus = *in.Plus
	}
	if in.QR != nil {
		u.QR = trim(*in.QR, 120)
	}
	s.st.write("user", u)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func trim(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// putSeen: the app shares "last seen" only when the user allows it; null hides it.
func (s *Server) putSeen(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		Seen *time.Time `json:"seen"`
	}
	if err := readJSON(r, 1024, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	if in.Seen != nil {
		t := time.Now().UTC() // server clock, not the phone's
		in.Seen = &t
	}
	s.st.mu.Lock()
	s.st.write("seen", seenOp{User: a.user, Seen: in.Seen})
	s.st.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) putDevice(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		PushToken string `json:"pushToken"`
		Sandbox   bool   `json:"sandbox"`
	}
	if err := readJSON(r, 4096, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	s.st.mu.Lock()
	defer s.st.mu.Unlock()
	d := s.st.devices[a.device]
	if d == nil {
		fail(w, 404, "device not found")
		return
	}
	nd := *d
	nd.PushToken, nd.Sandbox, nd.LastActive = trim(in.PushToken, 300), in.Sandbox, time.Now().UTC()
	s.st.write("device", nd)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *Server) profiles(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		IDs      []string `json:"ids"`
		SeenOnly bool     `json:"seenOnly"`
	}
	if err := readJSON(r, 64<<10, &in); err != nil || len(in.IDs) > 500 {
		fail(w, 400, "bad request")
		return
	}
	s.st.mu.Lock()
	defer s.st.mu.Unlock()
	out := []profileOut{}
	for _, id := range in.IDs {
		u := s.st.users[id]
		if u == nil || u.PubKey == "" {
			continue
		}
		p := profileOut{UserID: u.ID, Seen: u.Seen}
		if !in.SeenOnly {
			p.Name, p.PubKey, p.Pic, p.Plus, p.QR = u.Name, u.PubKey, u.Pic, u.Plus, u.QR
		}
		out = append(out, p)
	}
	writeJSON(w, 200, map[string]any{"profiles": out})
}

// ---------- mailbox ----------

type envIn struct {
	ID   string `json:"id"`
	Rcpt string `json:"rcpt"`
	Conv string `json:"conv"`
	Kind int    `json:"kind"`
	Loud bool   `json:"loud"`
	Body []byte `json:"body"`
	Hint []byte `json:"hint"`
}

func (s *Server) send(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		Envelopes []envIn `json:"envelopes"`
	}
	if err := readJSON(r, (maxEnvelope+maxHint)*2*maxBatch/4, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	if len(in.Envelopes) == 0 || len(in.Envelopes) > maxBatch {
		fail(w, 400, "send 1 to 300 envelopes")
		return
	}
	accepted := []string{}
	failed := map[string]string{}
	var jobs []pushJob
	s.st.mu.Lock()
	for _, e := range in.Envelopes {
		switch {
		case !idRe.MatchString(e.ID):
			failed[e.ID] = "bad id"
			continue
		case s.st.users[e.Rcpt] == nil:
			failed[e.ID] = "unknown recipient"
			continue
		case len(e.Body) == 0 || len(e.Body) > maxEnvelope || len(e.Hint) > maxHint:
			failed[e.ID] = "size"
			continue
		case s.st.envIDs[e.ID]:
			accepted = append(accepted, e.ID) // retry of something we already have
			continue
		}
		s.st.seq++
		env := Envelope{Seq: s.st.seq, ID: e.ID, Rcpt: e.Rcpt, Sndr: a.user, Conv: trim(e.Conv, 120),
			Kind: e.Kind, Loud: e.Loud, Body: e.Body, Hint: e.Hint, Created: time.Now().UTC()}
		if err := s.st.write("env", env); err != nil {
			failed[e.ID] = "storage"
			continue
		}
		accepted = append(accepted, e.ID)
		s.st.notify(e.Rcpt)
		for _, d := range s.st.devices {
			if d.UserID == e.Rcpt && d.PushToken != "" && d.ID != a.device {
				dc := *d
				jobs = append(jobs, pushJob{dev: &dc, msg: PushMsg{Conv: env.Conv, Sndr: a.user, Hint: e.Hint, Loud: e.Loud}})
			}
		}
	}
	s.st.mu.Unlock()
	for _, j := range jobs {
		select {
		case s.pushes <- j:
		default: // queue full: the message is still delivered on next open
		}
	}
	writeJSON(w, 200, map[string]any{"accepted": accepted, "failed": failed})
}

type envOut struct {
	Seq     int64     `json:"seq"`
	ID      string    `json:"id"`
	Sndr    string    `json:"sndr"`
	Conv    string    `json:"conv"`
	Kind    int       `json:"kind"`
	Loud    bool      `json:"loud"`
	Body    []byte    `json:"body"`
	Created time.Time `json:"created"`
}

// inboxH returns envelopes newer than ?after=<seq>. With ?wait=<seconds> (max 55) it
// holds the request open until something arrives — instant delivery without WebSockets.
func (s *Server) inboxH(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	if wait > 55 {
		wait = 55
	}
	deadline := time.Now().Add(time.Duration(wait) * time.Second)
	for {
		s.st.mu.Lock()
		if after == 0 {
			if d := s.st.devices[a.device]; d != nil {
				after = d.Cursor
			}
		}
		out := []envOut{}
		more := false
		for _, e := range s.st.inbox[a.user] {
			if e.Seq <= after {
				continue
			}
			if len(out) == limit {
				more = true
				break
			}
			out = append(out, envOut{e.Seq, e.ID, e.Sndr, e.Conv, e.Kind, e.Loud, e.Body, e.Created})
		}
		if len(out) > 0 || wait <= 0 || time.Now().After(deadline) {
			s.st.mu.Unlock()
			writeJSON(w, 200, map[string]any{"envelopes": out, "more": more})
			return
		}
		c := s.st.wait(a.user)
		s.st.mu.Unlock()
		select {
		case <-c:
		case <-time.After(time.Until(deadline)):
		case <-r.Context().Done():
			s.st.mu.Lock()
			s.st.unwait(a.user, c)
			s.st.mu.Unlock()
			return
		}
		s.st.mu.Lock()
		s.st.unwait(a.user, c)
		s.st.mu.Unlock()
	}
}

// ack: "this device has safely stored everything up to seq". Once every device of the
// user has acked an envelope, it is deleted from the server.
func (s *Server) ack(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	var in struct {
		UpTo int64 `json:"upTo"`
	}
	if err := readJSON(r, 1024, &in); err != nil {
		fail(w, 400, "bad request")
		return
	}
	s.st.mu.Lock()
	s.st.write("ack", ackOp{Device: a.device, Cursor: in.UpTo, At: time.Now().UTC()})
	s.cleanUserLocked(a.user, time.Now())
	s.st.mu.Unlock()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// cleanUserLocked deletes envelopes every active device has acked, and anything past the TTL.
func (s *Server) cleanUserLocked(user string, now time.Time) {
	min := int64(-1)
	for _, d := range s.st.devices {
		if d.UserID != user || now.Sub(d.LastActive) > deviceIdleTTL {
			continue
		}
		if min < 0 || d.Cursor < min {
			min = d.Cursor
		}
	}
	list := s.st.inbox[user]
	if len(list) == 0 {
		return
	}
	x := delEnvs{Rcpt: user, Before: now.Add(-envelopeTTL)}
	if min > 0 {
		x.UpTo = min
	}
	need := false
	for _, e := range list {
		if (x.UpTo > 0 && e.Seq <= x.UpTo) || e.Created.Before(x.Before) {
			need = true
			break
		}
	}
	if need {
		s.st.write("delenvs", x)
	}
}

// ---------- encrypted files ----------

func (s *Server) putBlob(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	id := r.PathValue("id")
	if !idRe.MatchString(id) {
		fail(w, 400, "bad id")
		return
	}
	s.st.mu.Lock()
	existing := s.st.blobs[id]
	s.st.mu.Unlock()
	if existing != nil {
		if existing.Owner != a.user {
			fail(w, 409, "id taken")
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "size": existing.Size})
		return
	}
	tmp := s.st.blobPath(id) + ".part" + randID(4)
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		fail(w, 500, "storage")
		return
	}
	n, err := io.Copy(f, io.LimitReader(r.Body, maxBlob+1))
	f.Sync()
	f.Close()
	if err != nil || n == 0 || n > maxBlob {
		os.Remove(tmp)
		if n > maxBlob {
			fail(w, 413, "file too large (100 MB max)")
		} else {
			fail(w, 400, "upload failed")
		}
		return
	}
	if err := os.Rename(tmp, s.st.blobPath(id)); err != nil {
		os.Remove(tmp)
		fail(w, 500, "storage")
		return
	}
	s.st.mu.Lock()
	s.st.write("blob", BlobMeta{ID: id, Owner: a.user, Size: n, Created: time.Now().UTC()})
	s.st.mu.Unlock()
	writeJSON(w, 200, map[string]any{"ok": true, "size": n})
}

// getBlob: files are encrypted with a per-file key only chat members have, and ids are
// random, so any signed-in user may fetch by id (same as CloudKit today).
func (s *Server) getBlob(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	id := r.PathValue("id")
	s.st.mu.Lock()
	b := s.st.blobs[id]
	s.st.mu.Unlock()
	if b == nil || !idRe.MatchString(id) {
		fail(w, 404, "file expired or not found")
		return
	}
	w.Header().Set("content-type", "application/octet-stream")
	http.ServeFile(w, r, s.st.blobPath(id))
}

// ---------- account ----------

func (s *Server) deleteMe(w http.ResponseWriter, r *http.Request, a ctxAuth) {
	s.st.mu.Lock()
	s.st.write("deluser", a.user)
	s.st.mu.Unlock()
	log.Printf("account deleted")
	writeJSON(w, 200, map[string]bool{"ok": true})
}
