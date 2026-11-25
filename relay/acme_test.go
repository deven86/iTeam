package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeACME is a tiny Let's Encrypt stand-in that really checks JWS signatures,
// nonces, the http-01 key authorization and the CSR.
type fakeACME struct {
	t       *testing.T
	srv     *httptest.Server
	mu      sync.Mutex
	nonces  map[string]bool
	acctKey *ecdsa.PublicKey
	token   string
	valid   bool
	csr     *x509.CertificateRequest
	ca      *ecdsa.PrivateKey
	client  *ACME
	issued  []byte
}

func (f *fakeACME) nonce(w http.ResponseWriter) {
	f.mu.Lock()
	n := randID(8)
	f.nonces[n] = true
	f.mu.Unlock()
	w.Header().Set("Replay-Nonce", n)
}

func (f *fakeACME) verify(r *http.Request) ([]byte, error) {
	var jws struct{ Protected, Payload, Signature string }
	b, _ := io.ReadAll(r.Body)
	if err := json.Unmarshal(b, &jws); err != nil {
		return nil, err
	}
	pb, _ := base64.RawURLEncoding.DecodeString(jws.Protected)
	var p struct {
		Alg, Nonce, URL, Kid string
		JWK                  map[string]string
	}
	json.Unmarshal(pb, &p)
	f.mu.Lock()
	okNonce := f.nonces[p.Nonce]
	delete(f.nonces, p.Nonce)
	f.mu.Unlock()
	if !okNonce {
		return nil, fmt.Errorf("badNonce")
	}
	if p.URL != f.srv.URL+r.URL.Path {
		return nil, fmt.Errorf("url mismatch %s", p.URL)
	}
	key := f.acctKey
	if p.JWK != nil {
		x, _ := base64.RawURLEncoding.DecodeString(p.JWK["x"])
		y, _ := base64.RawURLEncoding.DecodeString(p.JWK["y"])
		key = &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(x), Y: new(big.Int).SetBytes(y)}
		if f.acctKey == nil {
			f.acctKey = key
		}
	} else if p.Kid != f.srv.URL+"/acct/1" {
		return nil, fmt.Errorf("bad kid")
	}
	sig, _ := base64.RawURLEncoding.DecodeString(jws.Signature)
	sum := sha256.Sum256([]byte(jws.Protected + "." + jws.Payload))
	if len(sig) != 64 || !ecdsa.Verify(key, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return nil, fmt.Errorf("bad signature")
	}
	return base64.RawURLEncoding.DecodeString(jws.Payload)
}

func (f *fakeACME) handler(w http.ResponseWriter, r *http.Request) {
	u := f.srv.URL
	if r.URL.Path == "/dir" {
		json.NewEncoder(w).Encode(map[string]string{"newNonce": u + "/nonce", "newAccount": u + "/acct", "newOrder": u + "/order"})
		return
	}
	f.nonce(w)
	if r.URL.Path == "/nonce" {
		return
	}
	payload, err := f.verify(r)
	if err != nil {
		w.WriteHeader(400)
		fmt.Fprintf(w, `{"type":"urn:ietf:params:acme:error:%s"}`, err)
		return
	}
	switch r.URL.Path {
	case "/acct":
		w.Header().Set("Location", u+"/acct/1")
		w.WriteHeader(201)
		w.Write([]byte(`{"status":"valid"}`))
	case "/order":
		w.Header().Set("Location", u+"/order/1")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(map[string]any{"status": "pending", "authorizations": []string{u + "/authz/1"}, "finalize": u + "/finalize"})
	case "/authz/1":
		st := "pending"
		if f.valid {
			st = "valid"
		}
		json.NewEncoder(w).Encode(map[string]any{"status": st, "challenges": []map[string]string{
			{"type": "dns-01", "url": u + "/chall/dns", "token": "nope"},
			{"type": "http-01", "url": u + "/chall/1", "token": f.token}}})
	case "/chall/1":
		// Like Let's Encrypt: fetch http://domain/.well-known/acme-challenge/<token>.
		rec := httptest.NewRecorder()
		f.client.HTTPHandler().ServeHTTP(rec, httptest.NewRequest("GET", "/.well-known/acme-challenge/"+f.token, nil))
		jwk := fmt.Sprintf(`{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}`,
			b64u(f.acctKey.X.FillBytes(make([]byte, 32))), b64u(f.acctKey.Y.FillBytes(make([]byte, 32))))
		h := sha256.Sum256([]byte(jwk))
		if rec.Body.String() == f.token+"."+b64u(h[:]) {
			f.valid = true
		}
		w.Write([]byte(`{"status":"processing"}`))
	case "/finalize":
		var in struct{ CSR string }
		json.Unmarshal(payload, &in)
		der, _ := base64.RawURLEncoding.DecodeString(in.CSR)
		csr, err := x509.ParseCertificateRequest(der)
		if err != nil || csr.CheckSignature() != nil || !f.valid {
			w.WriteHeader(403)
			return
		}
		f.csr = csr
		tpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: csr.DNSNames[0]},
			DNSNames: csr.DNSNames, NotBefore: time.Now(), NotAfter: time.Now().Add(90 * 24 * time.Hour)}
		cder, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, csr.PublicKey, f.ca)
		f.issued = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cder})
		w.Write([]byte(`{"status":"processing"}`))
	case "/order/1":
		if f.issued != nil {
			json.NewEncoder(w).Encode(map[string]string{"status": "valid", "certificate": u + "/cert/1"})
		} else {
			w.Write([]byte(`{"status":"processing"}`))
		}
	case "/cert/1":
		w.Write(f.issued)
	default:
		w.WriteHeader(404)
	}
}

func TestACME(t *testing.T) {
	ca, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	f := &fakeACME{t: t, nonces: map[string]bool{}, token: "tok_" + randID(8), ca: ca}
	f.srv = httptest.NewServer(http.HandlerFunc(f.handler))
	defer f.srv.Close()
	dir := t.TempDir()
	a := &ACME{Domain: "relay.example.in", Email: "a@b.c", Dir: dir, DirectoryURL: f.srv.URL + "/dir"}
	f.client = a
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := a.Start(ctx); err != nil {
		t.Fatal(err)
	}
	c, err := a.GetCertificate(nil)
	if err != nil || len(c.Certificate) == 0 {
		t.Fatal("no certificate")
	}
	if a.needsRenewal() {
		t.Fatal("fresh certificate wants renewal")
	}
	if f.csr.DNSNames[0] != "relay.example.in" {
		t.Fatal("csr domain")
	}
	// Restart reuses the saved certificate without contacting the CA.
	f.srv.Close()
	b := &ACME{Domain: "relay.example.in", Dir: dir, DirectoryURL: "http://127.0.0.1:1/dir"}
	if err := b.Start(ctx); err != nil {
		t.Fatalf("restart: %v", err)
	}
	// Port 80 redirects normal traffic to HTTPS.
	rec := httptest.NewRecorder()
	a.HTTPHandler().ServeHTTP(rec, httptest.NewRequest("GET", "/status", nil))
	if rec.Code != 301 || !strings.HasPrefix(rec.Header().Get("Location"), "https://relay.example.in/") {
		t.Fatal("no https redirect")
	}
}
