// Package store owns the management database. No streaming traffic passes through it.
package store

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct{ DB *sql.DB }

func Open(path string) (*Store, error) {
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{DB: db}
	_, err = db.Exec(`
 PRAGMA foreign_keys=ON;
 PRAGMA busy_timeout=5000;
 PRAGMA journal_mode=WAL;
 CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL,
  admin INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0
 );
 CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires INTEGER NOT NULL, created INTEGER NOT NULL
 );
 CREATE TABLE IF NOT EXISTS machines (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT NOT NULL, http_port INTEGER NOT NULL,
  https_port INTEGER NOT NULL, token_hash TEXT UNIQUE NOT NULL, disabled INTEGER NOT NULL DEFAULT 0,
  host_uuid TEXT NOT NULL DEFAULT '', server_certificate TEXT NOT NULL DEFAULT '',
  last_seen INTEGER NOT NULL DEFAULT 0, managed_protocol INTEGER NOT NULL DEFAULT 0
 );
 CREATE TABLE IF NOT EXISTS grants (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  machine_id TEXT NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
  PRIMARY KEY(user_id,machine_id)
 );
 CREATE TABLE IF NOT EXISTS leases (
  id TEXT PRIMARY KEY, session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  machine_id TEXT NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
  fingerprint TEXT NOT NULL, certificate TEXT NOT NULL, expires INTEGER NOT NULL,
  UNIQUE(session_hash,machine_id,fingerprint)
 );
 CREATE INDEX IF NOT EXISTS leases_machine ON leases(machine_id,expires);
 CREATE TABLE IF NOT EXISTS audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
  actor TEXT NOT NULL, event TEXT NOT NULL, target TEXT NOT NULL
 );
 PRAGMA user_version=1;
 `)
	if err != nil {
		db.Close()
		return nil, err
	}
	if path != ":memory:" {
		if err = os.Chmod(path, 0600); err != nil {
			db.Close()
			return nil, err
		}
	}
	return s, nil
}

func (s *Store) Close() error { return s.DB.Close() }
func Token() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func ID() string                        { return Token()[:32] }
func Hash(s string) string              { v := sha256.Sum256([]byte(s)); return hex.EncodeToString(v[:]) }
func NormalizeUsername(s string) string { return strings.ToLower(strings.TrimSpace(s)) }
func ValidUsername(s string) bool {
	if len(s) < 1 || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-' || c == '@') {
			return false
		}
	}
	return true
}

type User struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Admin    bool   `json:"admin"`
	Disabled bool   `json:"disabled"`
}
type Machine struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Address           string `json:"address"`
	HTTPPort          int    `json:"http_port"`
	HTTPSPort         int    `json:"https_port"`
	Disabled          bool   `json:"disabled"`
	HostUUID          string `json:"host_uuid"`
	ServerCertificate string `json:"server_certificate"`
	LastSeen          int64  `json:"last_seen"`
	ManagedProtocol   int    `json:"managed_protocol"`
}

const MachineColumns = "id,name,address,http_port,https_port,disabled,host_uuid,server_certificate,last_seen,managed_protocol"

func ScanMachine(row interface{ Scan(...any) error }) (m Machine, err error) {
	err = row.Scan(&m.ID, &m.Name, &m.Address, &m.HTTPPort, &m.HTTPSPort, &m.Disabled, &m.HostUUID, &m.ServerCertificate, &m.LastSeen, &m.ManagedProtocol)
	return
}
func (s *Store) Audit(actor, event, target string) {
	_, _ = s.DB.Exec(`INSERT INTO audit(at,actor,event,target) VALUES(?,?,?,?)`, time.Now().Unix(), actor, event, target)
}
func (s *Store) CreateUser(username, passwordHash string, admin bool) (User, error) {
	username = NormalizeUsername(username)
	if !ValidUsername(username) {
		return User{}, errors.New("username must contain 1–64 letters, numbers, dots, underscores, @ or hyphens")
	}
	u := User{ID: ID(), Username: username, Admin: admin}
	_, err := s.DB.Exec(`INSERT INTO users(id,username,password_hash,admin) VALUES(?,?,?,?)`, u.ID, u.Username, passwordHash, admin)
	if err != nil {
		return User{}, fmt.Errorf("cannot create user (username may already exist): %w", err)
	}
	return u, nil
}

// Prune removes expired credentials and old audit entries without retaining secrets.
func (s *Store) Prune(now time.Time) {
	_, _ = s.DB.Exec(`DELETE FROM leases WHERE expires<=?`, now.Unix())
	_, _ = s.DB.Exec(`DELETE FROM sessions WHERE expires<=?`, now.Unix())
	_, _ = s.DB.Exec(`DELETE FROM audit WHERE at<?`, now.Add(-90*24*time.Hour).Unix())
}
