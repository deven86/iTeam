package main

// Free HTTPS certificate from Let's Encrypt (ACME, RFC 8555, HTTP-01 challenge),
// written with the standard library only. Renews automatically 30 days before expiry.

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type ACME struct {
	Domain, Email, Dir, DirectoryURL string

	mu     sync.RWMutex
	cert   *tls.Certificate
	tokens sync.Map // http-01 token -> key authorization

	client *http.Client
	dir    struct{ NewNonce, NewAccount, NewOrder string }
	key    *ecdsa.PrivateKey
	kid    string
	nonce  string
}

func (a *ACME) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.cert == nil {
		return nil, errors.New("no certificate yet")
	}
	return a.cert, nil
}

// HTTPHandler serves ACME challenges on port 80 and redirects everything else to HTTPS.
func (a *ACME) HTTPHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if t, ok := strings.CutPrefix(r.URL.Path, "/.well-known/acme-challenge/"); ok {
			if v, ok := a.tokens.Load(t); ok {
				w.Write([]byte(v.(string)))
				return
			}
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "https://"+a.Domain+r.URL.RequestURI(), http.StatusMovedPermanently)
	})
}

func (a *ACME) Start(ctx context.Context) error {
	os.MkdirAll(a.Dir, 0o700)
	a.client = &http.Client{Timeout: 30 * time.Second}
	if c, err := tls.LoadX509KeyPair(filepath.Join(a.Dir, "cert.pem"), filepath.Join(a.Dir, "key.pem")); err == nil {
		a.mu.Lock()
		a.cert = &c
		a.mu.Unlock()
	}
	if a.needsRenewal() {
		if err := a.obtain(); err != nil {
			if a.cert == nil {
				return err
			}
			log.Printf("certificate renewal failed (old one still valid): %v", err)
		}
	}
	go func() {
		t := time.NewTicker(12 * time.Hour)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if a.needsRenewal() {
					if err := a.obtain(); err != nil {
						log.Printf("certificate renewal: %v", err)
					}
				}
			}
		}
	}()
	return nil
}

func (a *ACME) needsRenewal() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.cert == nil || len(a.cert.Certificate) == 0 {
		return true
	}
	leaf, err := x509.ParseCertificate(a.cert.Certificate[0])
	if err != nil {
		return true
	}
	return time.Until(leaf.NotAfter) < 30*24*time.Hour || !contains(leaf.DNSNames, a.Domain)
}

func (a *ACME) accountKey() error {
	p := filepath.Join(a.Dir, "account.key")
	if b, err := os.ReadFile(p); err == nil {
		if blk, _ := pem.Decode(b); blk != nil {
			if k, err := x509.ParseECPrivateKey(blk.Bytes); err == nil {
				a.key = k
				return nil
			}
		}
	}
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	der, _ := x509.MarshalECPrivateKey(k)
	a.key = k
	return os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600)
}

func (a *ACME) jwk() map[string]string {
	return map[string]string{"crv": "P-256", "kty": "EC",
		"x": b64u(a.key.PublicKey.X.FillBytes(make([]byte, 32))),
		"y": b64u(a.key.PublicKey.Y.FillBytes(make([]byte, 32)))}
}

func (a *ACME) thumbprint() string {
	j := a.jwk()
	// RFC 7638: members in lexicographic order, no whitespace.
	s := fmt.Sprintf(`{"crv":"%s","kty":"%s","x":"%s","y":"%s"}`, j["crv"], j["kty"], j["x"], j["y"])
	h := sha256.Sum256([]byte(s))
	return b64u(h[:])
}

func (a *ACME) getNonce() (string, error) {
	if a.nonce != "" {
		n := a.nonce
		a.nonce = ""
		return n, nil
	}
	resp, err := a.client.Head(a.dir.NewNonce)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	n := resp.Header.Get("Replay-Nonce")
	if n == "" {
		return "", errors.New("acme: no nonce")
	}
	return n, nil
}

// post sends a JWS-signed request. payload nil = POST-as-GET.
func (a *ACME) post(url string, payload any) (*http.Response, []byte, error) {
	for attempt := 0; attempt < 3; attempt++ {
		nonce, err := a.getNonce()
		if err != nil {
			return nil, nil, err
		}
		prot := map[string]any{"alg": "ES256", "nonce": nonce, "url": url}
		if a.kid != "" {
			prot["kid"] = a.kid
		} else {
			prot["jwk"] = a.jwk()
		}
		pb, _ := json.Marshal(prot)
		body := ""
		if payload != nil {
			b, _ := json.Marshal(payload)
			body = b64u(b)
		}
		in := b64u(pb) + "." + body
		sig, err := es256(a.key, []byte(in))
		if err != nil {
			return nil, nil, err
		}
		msg, _ := json.Marshal(map[string]string{"protected": b64u(pb), "payload": body, "signature": b64u(sig)})
		req, _ := http.NewRequest("POST", url, bytes.NewReader(msg))
		req.Header.Set("Content-Type", "application/jose+json")
		resp, err := a.client.Do(req)
		if err != nil {
			return nil, nil, err
		}
		rb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		a.nonce = resp.Header.Get("Replay-Nonce")
		if resp.StatusCode == 400 && strings.Contains(string(rb), "badNonce") {
			continue
		}
		if resp.StatusCode >= 400 {
			return resp, rb, fmt.Errorf("acme %s: %d %s", url, resp.StatusCode, rb)
		}
		return resp, rb, nil
	}
	return nil, nil, errors.New("acme: nonce retries exhausted")
}

func (a *ACME) obtain() error {
	if a.key == nil {
		if err := a.accountKey(); err != nil {
			return err
		}
	}
	resp, err := a.client.Get(a.DirectoryURL)
	if err != nil {
		return err
	}
	var d struct {
		NewNonce   string `json:"newNonce"`
		NewAccount string `json:"newAccount"`
		NewOrder   string `json:"newOrder"`
	}
	err = json.NewDecoder(resp.Body).Decode(&d)
	resp.Body.Close()
	if err != nil {
		return err
	}
	a.dir.NewNonce, a.dir.NewAccount, a.dir.NewOrder = d.NewNonce, d.NewAccount, d.NewOrder
	a.kid = ""
	acct := map[string]any{"termsOfServiceAgreed": true}
	if a.Email != "" {
		acct["contact"] = []string{"mailto:" + a.Email}
	}
	resp, _, err = a.post(a.dir.NewAccount, acct)
	if err != nil {
		return err
	}
	a.kid = resp.Header.Get("Location")

	resp, rb, err := a.post(a.dir.NewOrder, map[string]any{"identifiers": []map[string]string{{"type": "dns", "value": a.Domain}}})
	if err != nil {
		return err
	}
	orderURL := resp.Header.Get("Location")
	var order struct {
		Status         string   `json:"status"`
		Authorizations []string `json:"authorizations"`
		Finalize       string   `json:"finalize"`
		Certificate    string   `json:"certificate"`
	}
	if err := json.Unmarshal(rb, &order); err != nil {
		return err
	}
	for _, az := range order.Authorizations {
		if err := a.authorize(az); err != nil {
			return err
		}
	}
	certKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	csr, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{CommonName: a.Domain}, DNSNames: []string{a.Domain}}, certKey)
	if err != nil {
		return err
	}
	if _, _, err := a.post(order.Finalize, map[string]string{"csr": b64u(csr)}); err != nil {
		return err
	}
	for i := 0; i < 30; i++ {
		_, rb, err = a.post(orderURL, nil)
		if err != nil {
			return err
		}
		json.Unmarshal(rb, &order)
		if order.Status == "valid" && order.Certificate != "" {
			break
		}
		if order.Status == "invalid" {
			return errors.New("acme: order invalid")
		}
		time.Sleep(2 * time.Second)
	}
	if order.Certificate == "" {
		return errors.New("acme: certificate not issued in time")
	}
	_, chain, err := a.post(order.Certificate, nil)
	if err != nil {
		return err
	}
	der, _ := x509.MarshalECPrivateKey(certKey)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
	c, err := tls.X509KeyPair(chain, keyPEM)
	if err != nil {
		return err
	}
	os.WriteFile(filepath.Join(a.Dir, "key.pem"), keyPEM, 0o600)
	os.WriteFile(filepath.Join(a.Dir, "cert.pem"), chain, 0o600)
	a.mu.Lock()
	a.cert = &c
	a.mu.Unlock()
	log.Printf("https certificate ready for %s", a.Domain)
	return nil
}

func (a *ACME) authorize(url string) error {
	_, rb, err := a.post(url, nil)
	if err != nil {
		return err
	}
	var az struct {
		Status     string `json:"status"`
		Challenges []struct {
			Type, URL, Token, Status string
		} `json:"challenges"`
	}
	if err := json.Unmarshal(rb, &az); err != nil {
		return err
	}
	if az.Status == "valid" {
		return nil
	}
	for _, ch := range az.Challenges {
		if ch.Type != "http-01" {
			continue
		}
		a.tokens.Store(ch.Token, ch.Token+"."+a.thumbprint())
		defer a.tokens.Delete(ch.Token)
		if _, _, err := a.post(ch.URL, map[string]any{}); err != nil {
			return err
		}
		for i := 0; i < 30; i++ {
			time.Sleep(2 * time.Second)
			_, rb, err = a.post(url, nil)
			if err != nil {
				return err
			}
			json.Unmarshal(rb, &az)
			switch az.Status {
			case "valid":
				return nil
			case "invalid":
				return fmt.Errorf("acme: Let's Encrypt could not reach http://%s (is port 80 open and the domain pointing here?)", a.Domain)
			}
		}
		return errors.New("acme: challenge timed out")
	}
	return errors.New("acme: no http-01 challenge offered")
}

// selfSigned is used by tests.
func selfSigned(domain string) (*tls.Certificate, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: domain},
		DNSNames: []string{domain}, NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, k.Public(), k)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: crypto.Signer(k)}, nil
}
