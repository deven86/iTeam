package main

// Sign in with Apple (iPhone/iPad) and Sign in with Google (Android).
// The app sends the ID token it got from Apple/Google; we check its signature
// against the provider's public keys, its issuer, audience and expiry.
// Apple and Google never learn anything about iTeam beyond "this person signed in".

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Provider struct {
	Name      string // apple | google
	JWKSURL   string
	Issuers   []string
	Audiences []string

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	client  *http.Client
}

func NewApple(aud []string) *Provider {
	return &Provider{Name: "apple", JWKSURL: "https://appleid.apple.com/auth/keys",
		Issuers: []string{"https://appleid.apple.com"}, Audiences: aud}
}

func NewGoogle(aud []string) *Provider {
	return &Provider{Name: "google", JWKSURL: "https://www.googleapis.com/oauth2/v3/certs",
		Issuers: []string{"https://accounts.google.com", "accounts.google.com"}, Audiences: aud}
}

type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func (p *Provider) key(kid string) (*rsa.PublicKey, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if k, ok := p.keys[kid]; ok && time.Since(p.fetched) < 6*time.Hour {
		return k, nil
	}
	// Unknown kid: refetch, but at most once a minute.
	if time.Since(p.fetched) > time.Minute || p.keys == nil {
		if err := p.refresh(); err != nil {
			if k, ok := p.keys[kid]; ok {
				return k, nil
			}
			return nil, err
		}
	}
	if k, ok := p.keys[kid]; ok {
		return k, nil
	}
	return nil, errors.New("unknown signing key")
}

func (p *Provider) refresh() error {
	c := p.client
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Get(p.JWKSURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("jwks %d", resp.StatusCode)
	}
	var set struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	p.keys, p.fetched = keys, time.Now()
	return nil
}

type Identity struct {
	Sub   string
	Email string
}

// Verify checks an RS256 ID token and returns the stable user id ("sub").
func (p *Provider) Verify(token string) (*Identity, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("malformed token")
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("malformed header")
	}
	var h struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if json.Unmarshal(hb, &h) != nil || h.Alg != "RS256" {
		return nil, errors.New("unsupported token")
	}
	k, err := p.key(h.Kid)
	if err != nil {
		return nil, err
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, errors.New("malformed signature")
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(k, crypto.SHA256, sum[:], sig); err != nil {
		return nil, errors.New("bad signature")
	}
	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("malformed claims")
	}
	var c struct {
		Iss   string          `json:"iss"`
		Sub   string          `json:"sub"`
		Aud   json.RawMessage `json:"aud"`
		Exp   int64           `json:"exp"`
		Iat   int64           `json:"iat"`
		Email string          `json:"email"`
	}
	if err := json.Unmarshal(pb, &c); err != nil {
		return nil, errors.New("malformed claims")
	}
	if !contains(p.Issuers, c.Iss) {
		return nil, errors.New("wrong issuer")
	}
	var auds []string
	var one string
	if json.Unmarshal(c.Aud, &one) == nil {
		auds = []string{one}
	} else {
		json.Unmarshal(c.Aud, &auds)
	}
	ok := false
	for _, a := range auds {
		if contains(p.Audiences, a) {
			ok = true
		}
	}
	if !ok {
		return nil, errors.New("token is not for iTeam")
	}
	now := time.Now().Unix()
	if c.Exp < now-60 {
		return nil, errors.New("token expired")
	}
	if c.Iat > now+300 {
		return nil, errors.New("token from the future")
	}
	if c.Sub == "" {
		return nil, errors.New("no subject")
	}
	return &Identity{Sub: c.Sub, Email: c.Email}, nil
}

func contains(l []string, v string) bool {
	for _, x := range l {
		if x == v {
			return true
		}
	}
	return false
}
