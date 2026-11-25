package main

// iTeam Relay — store-and-forward for end-to-end encrypted iTeam messages.
// One program, Go standard library only. Settings come from environment variables
// (see deploy/relay.env.example).

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"fmt"
	"html"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

var version = "dev"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func list(k string) []string {
	var out []string
	for _, p := range strings.Split(os.Getenv(k), ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(version)
		return
	}
	log.SetFlags(log.LstdFlags | log.LUTC)
	dataDir := env("RELAY_DATA", "/var/lib/iteam-relay")
	st, err := OpenStore(dataDir)
	if err != nil {
		log.Fatalf("open data: %v", err)
	}
	s := &Server{
		st:          st,
		apple:       NewApple(list("APPLE_AUDIENCES")),
		google:      NewGoogle(list("GOOGLE_AUDIENCES")),
		dev:         os.Getenv("RELAY_DEV") == "1",
		started:     time.Now(),
		statusToken: os.Getenv("STATUS_TOKEN"),
		links:       map[string]linkCode{},
		limiter:     newLimiter(20, 120),
		ck: &CloudKitReader{Token: os.Getenv("CK_API_TOKEN"),
			Base: env("CK_BASE", "https://api.apple-cloudkit.com/database/1/iCloud.com.jondhale.iteam/production/public")},
		claims: claims{m: map[string]*claimChallenge{}},
	}
	mp := &MultiPusher{}
	if f := os.Getenv("APNS_KEY_FILE"); f != "" {
		if mp.APNs, err = NewAPNs(f, os.Getenv("APNS_KEY_ID"), os.Getenv("APNS_TEAM_ID"), env("APNS_TOPIC", "com.jondhale.iteam")); err != nil {
			log.Fatalf("apns: %v", err)
		}
	}
	if f := os.Getenv("FCM_SERVICE_ACCOUNT"); f != "" {
		if mp.FCM, err = NewFCM(f); err != nil {
			log.Fatalf("fcm: %v", err)
		}
	}
	s.pushes = startPushWorkers(mp, 8, func(id string) {
		st.mu.Lock()
		if d := st.devices[id]; d != nil {
			nd := *d
			nd.PushToken = ""
			st.write("device", nd)
		}
		st.mu.Unlock()
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go s.housekeeping(ctx, []byte(os.Getenv("BACKUP_KEY")))

	handler := s.Routes()
	domain := os.Getenv("RELAY_DOMAIN")
	var servers []*http.Server
	if domain == "" {
		addr := env("RELAY_ADDR", ":8080")
		srv := &http.Server{Addr: addr, Handler: handler, ReadHeaderTimeout: 10 * time.Second}
		servers = append(servers, srv)
		log.Printf("iTeam relay %s on http://%s (no domain set: plain HTTP, for testing only)", version, addr)
		go func() {
			if err := srv.ListenAndServe(); err != http.ErrServerClosed {
				log.Fatal(err)
			}
		}()
	} else {
		acme := &ACME{Domain: domain, Email: os.Getenv("ACME_EMAIL"), Dir: filepath.Join(dataDir, "tls"),
			DirectoryURL: env("ACME_DIRECTORY", "https://acme-v02.api.letsencrypt.org/directory")}
		plain := &http.Server{Addr: ":80", Handler: acme.HTTPHandler(), ReadHeaderTimeout: 10 * time.Second}
		go func() {
			if err := plain.ListenAndServe(); err != http.ErrServerClosed {
				log.Fatal(err)
			}
		}()
		if err := acme.Start(ctx); err != nil {
			log.Fatalf("https certificate: %v", err)
		}
		secure := &http.Server{Addr: ":443", Handler: handler, ReadHeaderTimeout: 10 * time.Second,
			TLSConfig: &tls.Config{GetCertificate: acme.GetCertificate, MinVersion: tls.VersionTLS12}}
		servers = append(servers, plain, secure)
		log.Printf("iTeam relay %s on https://%s", version, domain)
		go func() {
			if err := secure.ListenAndServeTLS("", ""); err != http.ErrServerClosed {
				log.Fatal(err)
			}
		}()
	}
	<-ctx.Done()
	log.Printf("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, srv := range servers {
		srv.Shutdown(sctx)
	}
	if err := st.Close(); err != nil {
		log.Printf("final snapshot: %v", err)
	}
}

// housekeeping: deletes expired envelopes/files, compacts the journal, writes daily backups.
func (s *Server) housekeeping(ctx context.Context, backupKey []byte) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	lastBackup := time.Time{}
	for {
		s.sweep(time.Now())
		s.st.mu.Lock()
		big := s.st.jsize > 32<<20
		s.st.mu.Unlock()
		if big {
			if err := s.st.Compact(); err != nil {
				log.Printf("compact: %v", err)
			}
		}
		if time.Since(lastBackup) > 24*time.Hour {
			if err := s.backup(backupKey); err != nil {
				log.Printf("backup: %v", err)
			} else {
				lastBackup = time.Now()
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) sweep(now time.Time) {
	s.st.mu.Lock()
	defer s.st.mu.Unlock()
	for user := range s.st.inbox {
		s.cleanUserLocked(user, now)
	}
	for id, b := range s.st.blobs {
		if now.Sub(b.Created) > blobTTL {
			os.Remove(s.st.blobPath(id))
			s.st.write("unblob", id)
		}
	}
	// Leftover partial uploads from a crash.
	parts, _ := filepath.Glob(filepath.Join(s.st.dir, "blobs", "*.part*"))
	for _, p := range parts {
		if fi, err := os.Stat(p); err == nil && now.Sub(fi.ModTime()) > time.Hour {
			os.Remove(p)
		}
	}
}

// backup writes the account list + waiting envelopes (not files) as one gzip file,
// encrypted with AES-256-GCM when BACKUP_KEY is set. Keeps the last 14.
func (s *Server) backup(key []byte) error {
	if err := s.st.Compact(); err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(s.st.dir, "snapshot.json"))
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write(raw)
	zw.Close()
	out, ext := buf.Bytes(), ".json.gz"
	if len(key) > 0 {
		k := sha256.Sum256(key)
		blk, _ := aes.NewCipher(k[:])
		g, _ := cipher.NewGCM(blk)
		nonce := make([]byte, g.NonceSize())
		rand.Read(nonce)
		out, ext = append(nonce, g.Seal(nil, nonce, out, nil)...), ".json.gz.enc"
	}
	dir := filepath.Join(s.st.dir, "backups")
	name := filepath.Join(dir, "relay-"+time.Now().UTC().Format("20060102-1504")+ext)
	if err := os.WriteFile(name+".tmp", out, 0o600); err != nil {
		return err
	}
	if err := os.Rename(name+".tmp", name); err != nil {
		return err
	}
	files, _ := filepath.Glob(filepath.Join(dir, "relay-*"))
	sort.Strings(files)
	for len(files) > 14 {
		os.Remove(files[0])
		files = files[1:]
	}
	return nil
}

// status: public "ok" for anyone; counts only with ?token=STATUS_TOKEN. Opens nicely on a phone.
func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	full := s.statusToken != "" && r.URL.Query().Get("token") == s.statusToken
	s.st.mu.Lock()
	users, devices, waiting, blobs := len(s.st.users), len(s.st.devices), 0, len(s.st.blobs)
	var blobBytes int64
	for _, l := range s.st.inbox {
		waiting += len(l)
	}
	for _, b := range s.st.blobs {
		blobBytes += b.Size
	}
	s.st.mu.Unlock()
	var fs syscall.Statfs_t
	freeGB := -1.0
	if syscall.Statfs(s.st.dir, &fs) == nil {
		freeGB = float64(fs.Bavail) * float64(fs.Bsize) / 1e9
	}
	backups, _ := filepath.Glob(filepath.Join(s.st.dir, "backups", "relay-*"))
	lastBackup := "none yet"
	if len(backups) > 0 {
		sort.Strings(backups)
		lastBackup = strings.TrimPrefix(filepath.Base(backups[len(backups)-1]), "relay-")
	}
	up := time.Since(s.started).Round(time.Minute)
	if strings.Contains(r.Header.Get("accept"), "application/json") {
		v := map[string]any{"ok": true, "version": version, "uptime": up.String()}
		if full {
			v["users"], v["devices"], v["waitingMessages"], v["files"], v["filesMB"], v["diskFreeGB"], v["lastBackup"] =
				users, devices, waiting, blobs, blobBytes>>20, freeGB, lastBackup
		}
		writeJSON(w, 200, v)
		return
	}
	row := func(k, v string) string {
		return "<tr><td>" + html.EscapeString(k) + "</td><td><b>" + html.EscapeString(v) + "</b></td></tr>"
	}
	rows := row("Status", "✅ Working") + row("Version", version) + row("Running for", up.String())
	if full {
		warn := ""
		if freeGB >= 0 && freeGB < 5 {
			warn = " ⚠️ low"
		}
		rows += row("Accounts", fmt.Sprint(users)) + row("Devices", fmt.Sprint(devices)) +
			row("Messages waiting", fmt.Sprint(waiting)) + row("Files", fmt.Sprintf("%d (%d MB)", blobs, blobBytes>>20)) +
			row("Disk free", fmt.Sprintf("%.1f GB%s", freeGB, warn)) + row("Last backup", lastBackup)
	}
	w.Header().Set("content-type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>iTeam relay</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:24px;background:#f4f6fb;color:#123}
table{background:#fff;border-radius:14px;padding:12px;width:100%%;max-width:420px;box-shadow:0 2px 10px #0001}
td{padding:8px}</style><h2>iTeam relay</h2><table>%s</table><p style="color:#678">Messages are end-to-end encrypted. This server cannot read them.</p>`, rows)
}

// ---------- rate limiting ----------

type bucket struct {
	tokens float64
	last   time.Time
}

type limiter struct {
	mu    sync.Mutex
	rate  float64
	burst float64
	m     map[string]*bucket
}

func newLimiter(rate, burst float64) *limiter {
	return &limiter{rate: rate, burst: burst, m: map[string]*bucket{}}
}

func (l *limiter) allow(key string, cost float64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b := l.m[key]
	if b == nil {
		if len(l.m) > 100000 {
			for k, v := range l.m {
				if now.Sub(v.last) > time.Minute {
					delete(l.m, k)
				}
			}
		}
		b = &bucket{tokens: l.burst, last: now}
		l.m[key] = b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < cost {
		return false
	}
	b.tokens -= cost
	return true
}
