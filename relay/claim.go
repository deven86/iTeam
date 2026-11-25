package main

// "Bridge" for existing iPhone users: an iPhone keeps its current iTeam ID (its CloudKit user ID)
// on the relay, so Android users can reach it at the same ID. To claim an ID the phone must prove
// it holds the private key whose public key is published on that ID's CloudKit profile:
//   1. POST /v1/claim/start {legacyID} -> server reads the profile from CloudKit and returns a
//      one-time X25519 public key.
//   2. The phone computes X25519(its identity key, server key) and sends
//      HMAC-SHA256(shared, "iteam-claim|<challengeID>|<legacyID>") with its Apple sign-in.
// Nobody without that private key can take over an existing ID.

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type CloudKitReader struct {
	Base   string // e.g. https://api.apple-cloudkit.com/database/1/iCloud.com.jondhale.iteam/production/public
	Token  string
	client *http.Client
}

type ckProfile struct {
	Name, PubKey string
	Pic          []byte
}

func (c *CloudKitReader) Profile(userID string) (*ckProfile, error) {
	if c == nil || c.Token == "" {
		return nil, errors.New("iPhone bridge is not set up on the server")
	}
	if c.client == nil {
		c.client = &http.Client{Timeout: 15 * time.Second}
	}
	body, _ := json.Marshal(map[string]any{
		"records":     []map[string]string{{"recordName": "P" + userID}},
		"desiredKeys": []string{"name", "pubkey", "pic"},
	})
	resp, err := c.client.Post(c.Base+"/records/lookup?ckAPIToken="+url.QueryEscape(c.Token), "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Records []struct {
			ServerErrorCode string `json:"serverErrorCode"`
			Fields          map[string]struct {
				Value json.RawMessage `json:"value"`
			} `json:"fields"`
		} `json:"records"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&out); err != nil || resp.StatusCode != 200 {
		return nil, fmt.Errorf("iCloud lookup failed (%d)", resp.StatusCode)
	}
	if len(out.Records) == 0 || out.Records[0].ServerErrorCode != "" {
		return nil, errNotFound
	}
	f := out.Records[0].Fields
	str := func(k string) string {
		var s string
		json.Unmarshal(f[k].Value, &s)
		return s
	}
	p := &ckProfile{Name: str("name"), PubKey: str("pubkey")}
	if pic := str("pic"); pic != "" {
		p.Pic, _ = base64.StdEncoding.DecodeString(pic)
	}
	if p.PubKey == "" {
		return nil, errNotFound
	}
	return p, nil
}

type claimChallenge struct {
	legacyID string
	priv     *ecdh.PrivateKey
	profile  *ckProfile
	expires  time.Time
}

type claims struct {
	mu sync.Mutex
	m  map[string]*claimChallenge
}

func (s *Server) claimStart(w http.ResponseWriter, r *http.Request) {
	var in struct {
		LegacyID string `json:"legacyID"`
	}
	if err := readJSON(r, 1024, &in); err != nil || !idRe.MatchString(in.LegacyID) || strings.HasPrefix(in.LegacyID, "u_") {
		fail(w, 400, "bad request")
		return
	}
	p, err := s.ck.Profile(in.LegacyID)
	if err != nil {
		if errors.Is(err, errNotFound) {
			fail(w, 404, "no iTeam profile for this ID")
		} else {
			fail(w, 502, err.Error())
		}
		return
	}
	priv, _ := ecdh.X25519().GenerateKey(rand.Reader)
	id := randID(16)
	s.claims.mu.Lock()
	for k, c := range s.claims.m {
		if time.Now().After(c.expires) {
			delete(s.claims.m, k)
		}
	}
	s.claims.m[id] = &claimChallenge{legacyID: in.LegacyID, priv: priv, profile: p, expires: time.Now().Add(5 * time.Minute)}
	s.claims.mu.Unlock()
	writeJSON(w, 200, map[string]string{"challengeID": id, "serverKey": base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes())})
}

type claimIn struct {
	ChallengeID string `json:"challengeID"`
	Proof       string `json:"proof"`
}

// verifyClaim checks the proof and returns the claimed ID and its iCloud profile.
func (s *Server) verifyClaim(in *claimIn) (string, *ckProfile, error) {
	s.claims.mu.Lock()
	c := s.claims.m[in.ChallengeID]
	delete(s.claims.m, in.ChallengeID)
	s.claims.mu.Unlock()
	if c == nil || time.Now().After(c.expires) {
		return "", nil, errors.New("claim expired, try again")
	}
	raw, err := base64.StdEncoding.DecodeString(c.profile.PubKey)
	if err != nil {
		return "", nil, errors.New("bad profile key")
	}
	pub, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return "", nil, errors.New("bad profile key")
	}
	shared, err := c.priv.ECDH(pub)
	if err != nil {
		return "", nil, errors.New("bad profile key")
	}
	mac := hmac.New(sha256.New, shared)
	mac.Write([]byte("iteam-claim|" + in.ChallengeID + "|" + c.legacyID))
	want := mac.Sum(nil)
	got, _ := base64.StdEncoding.DecodeString(in.Proof)
	if !hmac.Equal(want, got) {
		return "", nil, errors.New("this phone doesn't hold the key for that iTeam ID")
	}
	return c.legacyID, c.profile, nil
}
