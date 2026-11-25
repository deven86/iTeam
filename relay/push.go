package main

// Push notifications: Apple (APNs, token-based .p8 key) and Google (FCM HTTP v1,
// service-account key). Payloads carry only encrypted data (hint, conv, sender id);
// the phone decrypts the preview itself. Neither Apple nor Google can read it.

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type PushMsg struct {
	Conv string
	Sndr string
	Hint []byte
	Loud bool
}

type Pusher interface {
	// Send returns gone=true when the token is no longer valid and should be forgotten.
	Send(d *Device, m PushMsg) (gone bool, err error)
}

type MultiPusher struct {
	APNs *APNs
	FCM  *FCM
}

func (m *MultiPusher) Send(d *Device, msg PushMsg) (bool, error) {
	switch d.Platform {
	case "ios":
		if m.APNs != nil {
			return m.APNs.Send(d, msg)
		}
	case "android":
		if m.FCM != nil {
			return m.FCM.Send(d, msg)
		}
	}
	return false, nil
}

func b64u(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// ---------- APNs ----------

type APNs struct {
	KeyID, TeamID, Topic string
	Host, SandboxHost    string // overridable for tests
	key                  *ecdsa.PrivateKey
	client               *http.Client

	mu     sync.Mutex
	jwt    string
	issued time.Time
}

func NewAPNs(keyFile, keyID, teamID, topic string) (*APNs, error) {
	b, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, err
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("apns key: not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	ek, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns key: not EC")
	}
	return &APNs{KeyID: keyID, TeamID: teamID, Topic: topic, key: ek,
		Host: "https://api.push.apple.com", SandboxHost: "https://api.sandbox.push.apple.com",
		client: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (a *APNs) token() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && time.Since(a.issued) < 40*time.Minute {
		return a.jwt, nil
	}
	h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.KeyID})
	now := time.Now()
	c, _ := json.Marshal(map[string]any{"iss": a.TeamID, "iat": now.Unix()})
	in := b64u(h) + "." + b64u(c)
	sig, err := es256(a.key, []byte(in))
	if err != nil {
		return "", err
	}
	a.jwt, a.issued = in+"."+b64u(sig), now
	return a.jwt, nil
}

// es256 signs and returns the 64-byte r||s form JOSE expects.
func es256(k *ecdsa.PrivateKey, data []byte) ([]byte, error) {
	sum := sha256.Sum256(data)
	r, s, err := ecdsa.Sign(rand.Reader, k, sum[:])
	if err != nil {
		return nil, err
	}
	out := make([]byte, 64)
	r.FillBytes(out[:32])
	s.FillBytes(out[32:])
	return out, nil
}

func (a *APNs) Send(d *Device, m PushMsg) (bool, error) {
	if d.PushToken == "" {
		return false, nil
	}
	data := map[string]any{"conv": m.Conv, "sndr": m.Sndr}
	if len(m.Hint) > 0 {
		data["hint"] = base64.StdEncoding.EncodeToString(m.Hint)
	}
	pushType, prio := "background", "5"
	if m.Loud {
		// The notification service extension decrypts "hint" and replaces this text.
		data["aps"] = map[string]any{"alert": map[string]string{"title": "iTeam", "body": "New message"},
			"sound": "default", "mutable-content": 1, "thread-id": m.Conv}
		pushType, prio = "alert", "10"
	} else {
		data["aps"] = map[string]any{"content-available": 1}
	}
	body, _ := json.Marshal(data)
	host := a.Host
	if d.Sandbox {
		host = a.SandboxHost
	}
	req, _ := http.NewRequest("POST", host+"/3/device/"+d.PushToken, bytes.NewReader(body))
	tok, err := a.token()
	if err != nil {
		return false, err
	}
	req.Header.Set("authorization", "bearer "+tok)
	req.Header.Set("apns-topic", a.Topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", prio)
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(7*24*time.Hour).Unix()))
	resp, err := a.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return false, nil
	}
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode == 410 || strings.Contains(string(rb), "BadDeviceToken") || strings.Contains(string(rb), "Unregistered") {
		return true, nil
	}
	return false, fmt.Errorf("apns %d %s", resp.StatusCode, rb)
}

// ---------- FCM ----------

type FCM struct {
	ProjectID   string
	ClientEmail string
	TokenURI    string
	BaseURL     string // overridable for tests
	key         *rsa.PrivateKey
	client      *http.Client

	mu     sync.Mutex
	access string
	expiry time.Time
}

func NewFCM(serviceAccountFile string) (*FCM, error) {
	b, err := os.ReadFile(serviceAccountFile)
	if err != nil {
		return nil, err
	}
	var sa struct {
		ProjectID   string `json:"project_id"`
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if err := json.Unmarshal(b, &sa); err != nil {
		return nil, err
	}
	blk, _ := pem.Decode([]byte(sa.PrivateKey))
	if blk == nil {
		return nil, errors.New("fcm key: not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, err
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("fcm key: not RSA")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &FCM{ProjectID: sa.ProjectID, ClientEmail: sa.ClientEmail, TokenURI: sa.TokenURI, BaseURL: "https://fcm.googleapis.com", key: rk,
		client: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (f *FCM) accessToken() (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.access != "" && time.Until(f.expiry) > 5*time.Minute {
		return f.access, nil
	}
	h, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	now := time.Now()
	c, _ := json.Marshal(map[string]any{"iss": f.ClientEmail, "scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud": f.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	in := b64u(h) + "." + b64u(c)
	sum := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {in + "." + b64u(sig)}}
	resp, err := f.client.PostForm(f.TokenURI, form)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil || tr.AccessToken == "" {
		return "", fmt.Errorf("fcm token: status %d", resp.StatusCode)
	}
	f.access, f.expiry = tr.AccessToken, now.Add(time.Duration(tr.ExpiresIn)*time.Second)
	return f.access, nil
}

func (f *FCM) Send(d *Device, m PushMsg) (bool, error) {
	if d.PushToken == "" {
		return false, nil
	}
	data := map[string]string{"conv": m.Conv, "sndr": m.Sndr, "loud": "0"}
	if m.Loud {
		data["loud"] = "1"
	}
	if len(m.Hint) > 0 {
		data["hint"] = base64.StdEncoding.EncodeToString(m.Hint)
	}
	prio := "NORMAL"
	if m.Loud {
		prio = "HIGH"
	}
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"token": d.PushToken, "data": data,
		"android": map[string]any{"priority": prio, "ttl": "604800s"}}})
	tok, err := f.accessToken()
	if err != nil {
		return false, err
	}
	req, _ := http.NewRequest("POST", f.BaseURL+"/v1/projects/"+f.ProjectID+"/messages:send", bytes.NewReader(body))
	req.Header.Set("authorization", "Bearer "+tok)
	req.Header.Set("content-type", "application/json")
	resp, err := f.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return false, nil
	}
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode == 404 || strings.Contains(string(rb), "UNREGISTERED") {
		return true, nil
	}
	return false, fmt.Errorf("fcm %d %s", resp.StatusCode, rb)
}

// pushWorker sends pushes in the background so senders never wait on Apple/Google.
type pushJob struct {
	dev *Device
	msg PushMsg
}

func startPushWorkers(p Pusher, n int, onGone func(deviceID string)) chan<- pushJob {
	ch := make(chan pushJob, 10000)
	for i := 0; i < n; i++ {
		go func() {
			for j := range ch {
				gone, err := p.Send(j.dev, j.msg)
				if gone {
					onGone(j.dev.ID)
				} else if err != nil {
					log.Printf("push %s: %v", j.dev.Platform, err)
				}
			}
		}()
	}
	return ch
}
