package main

// Store: everything the relay keeps, in memory, made durable with an append-only
// journal (journal.log) plus a periodic snapshot (snapshot.json). Small by design:
// accounts, public keys, push tokens and encrypted envelopes waiting for delivery.
// Encrypted files (blobs) live as plain files under blobs/.

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

type User struct {
	ID      string     `json:"id"`
	Name    string     `json:"name"`
	PubKey  string     `json:"pubkey"`
	Pic     []byte     `json:"pic,omitempty"`
	Plus    bool       `json:"plus,omitempty"`
	QR      string     `json:"qr,omitempty"`
	Seen    *time.Time `json:"seen,omitempty"`
	Created time.Time  `json:"created"`
}

type Device struct {
	ID         string    `json:"id"`
	UserID     string    `json:"user"`
	Platform   string    `json:"platform"` // ios | android
	PushToken  string    `json:"push,omitempty"`
	Sandbox    bool      `json:"sandbox,omitempty"`
	Cursor     int64     `json:"cursor"`
	LastActive time.Time `json:"active"`
}

type Session struct {
	Hash     string    `json:"hash"` // sha256 of the bearer token; the token itself is never stored
	UserID   string    `json:"user"`
	DeviceID string    `json:"device"`
	Created  time.Time `json:"created"`
}

type Envelope struct {
	Seq     int64     `json:"seq"`
	ID      string    `json:"id"`
	Rcpt    string    `json:"rcpt"`
	Sndr    string    `json:"sndr"`
	Conv    string    `json:"conv"`
	Kind    int       `json:"kind"`
	Loud    bool      `json:"loud"`
	Body    []byte    `json:"body"`
	Hint    []byte    `json:"hint,omitempty"`
	Created time.Time `json:"created"`
}

type BlobMeta struct {
	ID      string    `json:"id"`
	Owner   string    `json:"owner"`
	Size    int64     `json:"size"`
	Created time.Time `json:"created"`
}

type snapshot struct {
	Seq      int64                `json:"seq"`
	Users    map[string]*User     `json:"users"`
	Idents   map[string]string    `json:"idents"` // "apple:<sub>" / "google:<sub>" -> userID
	Devices  map[string]*Device   `json:"devices"`
	Sessions map[string]*Session  `json:"sessions"`
	Envs     []*Envelope          `json:"envs"`
	Blobs    map[string]*BlobMeta `json:"blobs"`
}

type op struct {
	Op string          `json:"op"`
	D  json.RawMessage `json:"d"`
}

type Store struct {
	mu       sync.Mutex
	dir      string
	seq      int64
	users    map[string]*User
	idents   map[string]string
	devices  map[string]*Device
	sessions map[string]*Session
	inbox    map[string][]*Envelope // rcpt -> envelopes ordered by seq
	envIDs   map[string]bool
	blobs    map[string]*BlobMeta
	journal  *os.File
	jsize    int64
	waiters  map[string][]chan struct{} // userID -> long-poll waiters
}

var errNotFound = errors.New("not found")

func OpenStore(dir string) (*Store, error) {
	for _, d := range []string{dir, filepath.Join(dir, "blobs"), filepath.Join(dir, "backups")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	s := &Store{dir: dir}
	s.reset()
	if b, err := os.ReadFile(filepath.Join(dir, "snapshot.json")); err == nil {
		var snap snapshot
		if err := json.Unmarshal(b, &snap); err != nil {
			return nil, fmt.Errorf("snapshot: %w", err)
		}
		s.load(&snap)
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := s.replay(); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "journal.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	st, _ := f.Stat()
	s.journal, s.jsize = f, st.Size()
	return s, nil
}

func (s *Store) reset() {
	s.users = map[string]*User{}
	s.idents = map[string]string{}
	s.devices = map[string]*Device{}
	s.sessions = map[string]*Session{}
	s.inbox = map[string][]*Envelope{}
	s.envIDs = map[string]bool{}
	s.blobs = map[string]*BlobMeta{}
	s.waiters = map[string][]chan struct{}{}
}

func (s *Store) load(snap *snapshot) {
	s.seq = snap.Seq
	if snap.Users != nil {
		s.users = snap.Users
	}
	if snap.Idents != nil {
		s.idents = snap.Idents
	}
	if snap.Devices != nil {
		s.devices = snap.Devices
	}
	if snap.Sessions != nil {
		s.sessions = snap.Sessions
	}
	if snap.Blobs != nil {
		s.blobs = snap.Blobs
	}
	for _, e := range snap.Envs {
		s.inbox[e.Rcpt] = append(s.inbox[e.Rcpt], e)
		s.envIDs[e.ID] = true
	}
}

// replay applies journal lines written after the last snapshot. A torn last line
// (power cut mid-write) is ignored; everything before it is kept.
func (s *Store) replay() error {
	f, err := os.Open(filepath.Join(s.dir, "journal.log"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			var o op
			if json.Unmarshal(line, &o) == nil {
				s.apply(o)
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// write journals an operation and applies it. Caller holds s.mu.
func (s *Store) write(name string, v any) error {
	d, err := json.Marshal(v)
	if err != nil {
		return err
	}
	line, _ := json.Marshal(op{Op: name, D: d})
	line = append(line, '\n')
	if _, err := s.journal.Write(line); err != nil {
		return err
	}
	if err := s.journal.Sync(); err != nil {
		return err
	}
	s.jsize += int64(len(line))
	s.apply(op{Op: name, D: d})
	return nil
}

type delEnvs struct {
	Rcpt   string    `json:"rcpt"`
	UpTo   int64     `json:"upto"`   // delete seq <= upto
	Before time.Time `json:"before"` // and/or created before
}

type ackOp struct {
	Device string    `json:"device"`
	Cursor int64     `json:"cursor"`
	At     time.Time `json:"at"`
}

type seenOp struct {
	User string     `json:"user"`
	Seen *time.Time `json:"seen"`
}

type identOp struct {
	Key  string `json:"key"`
	User string `json:"user"`
}

func (s *Store) apply(o op) {
	switch o.Op {
	case "user":
		var u User
		if json.Unmarshal(o.D, &u) == nil {
			s.users[u.ID] = &u
		}
	case "seen":
		var x seenOp
		if json.Unmarshal(o.D, &x) == nil {
			if u := s.users[x.User]; u != nil {
				u.Seen = x.Seen
			}
		}
	case "ident":
		var x identOp
		if json.Unmarshal(o.D, &x) == nil {
			s.idents[x.Key] = x.User
		}
	case "device":
		var d Device
		if json.Unmarshal(o.D, &d) == nil {
			s.devices[d.ID] = &d
		}
	case "ack":
		var x ackOp
		if json.Unmarshal(o.D, &x) == nil {
			if d := s.devices[x.Device]; d != nil {
				if x.Cursor > d.Cursor {
					d.Cursor = x.Cursor
				}
				d.LastActive = x.At
			}
		}
	case "session":
		var x Session
		if json.Unmarshal(o.D, &x) == nil {
			s.sessions[x.Hash] = &x
		}
	case "unsession":
		var h string
		if json.Unmarshal(o.D, &h) == nil {
			delete(s.sessions, h)
		}
	case "env":
		var e Envelope
		if json.Unmarshal(o.D, &e) == nil && !s.envIDs[e.ID] {
			if e.Seq > s.seq {
				s.seq = e.Seq
			}
			s.inbox[e.Rcpt] = append(s.inbox[e.Rcpt], &e)
			s.envIDs[e.ID] = true
		}
	case "delenvs":
		var x delEnvs
		if json.Unmarshal(o.D, &x) == nil {
			s.dropEnvs(x)
		}
	case "blob":
		var b BlobMeta
		if json.Unmarshal(o.D, &b) == nil {
			s.blobs[b.ID] = &b
		}
	case "unblob":
		var id string
		if json.Unmarshal(o.D, &id) == nil {
			delete(s.blobs, id)
		}
	case "deluser":
		var id string
		if json.Unmarshal(o.D, &id) == nil {
			s.dropUser(id)
		}
	}
}

func (s *Store) dropEnvs(x delEnvs) {
	list := s.inbox[x.Rcpt]
	keep := list[:0]
	for _, e := range list {
		gone := (x.UpTo > 0 && e.Seq <= x.UpTo) || (!x.Before.IsZero() && e.Created.Before(x.Before))
		if gone {
			delete(s.envIDs, e.ID)
		} else {
			keep = append(keep, e)
		}
	}
	if len(keep) == 0 {
		delete(s.inbox, x.Rcpt)
	} else {
		s.inbox[x.Rcpt] = keep
	}
}

func (s *Store) dropUser(id string) {
	delete(s.users, id)
	for k, v := range s.idents {
		if v == id {
			delete(s.idents, k)
		}
	}
	for k, d := range s.devices {
		if d.UserID == id {
			delete(s.devices, k)
		}
	}
	for k, x := range s.sessions {
		if x.UserID == id {
			delete(s.sessions, k)
		}
	}
	for _, e := range s.inbox[id] {
		delete(s.envIDs, e.ID)
	}
	delete(s.inbox, id)
	for k, b := range s.blobs {
		if b.Owner == id {
			delete(s.blobs, k)
			os.Remove(s.blobPath(k))
		}
	}
}

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

func (s *Store) blobPath(id string) string { return filepath.Join(s.dir, "blobs", id) }

// snapshotLocked writes a full snapshot and empties the journal. Caller holds s.mu.
func (s *Store) snapshotLocked() error {
	snap := snapshot{Seq: s.seq, Users: s.users, Idents: s.idents, Devices: s.devices,
		Sessions: s.sessions, Blobs: s.blobs}
	for _, l := range s.inbox {
		snap.Envs = append(snap.Envs, l...)
	}
	sort.Slice(snap.Envs, func(i, j int) bool { return snap.Envs[i].Seq < snap.Envs[j].Seq })
	b, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	tmp := filepath.Join(s.dir, "snapshot.json.tmp")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	if err := os.Rename(tmp, filepath.Join(s.dir, "snapshot.json")); err != nil {
		return err
	}
	if err := s.journal.Truncate(0); err != nil {
		return err
	}
	s.jsize = 0
	return nil
}

func (s *Store) Compact() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked()
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	err := s.snapshotLocked()
	s.journal.Close()
	return err
}

// notify wakes long-poll waiters for a user. Caller holds s.mu.
func (s *Store) notify(userID string) {
	for _, c := range s.waiters[userID] {
		close(c)
	}
	delete(s.waiters, userID)
}

func (s *Store) wait(userID string) chan struct{} {
	c := make(chan struct{})
	s.waiters[userID] = append(s.waiters[userID], c)
	return c
}

func (s *Store) unwait(userID string, c chan struct{}) {
	l := s.waiters[userID]
	for i, x := range l {
		if x == c {
			s.waiters[userID] = append(l[:i], l[i+1:]...)
			break
		}
	}
	if len(s.waiters[userID]) == 0 {
		delete(s.waiters, userID)
	}
}
