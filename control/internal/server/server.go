package server

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/auth"
	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

const LeaseSeconds = 90
const SessionSeconds = 12 * 60 * 60

type Config struct {
	PublicURL      string
	TrustedProxies []*net.IPNet
}
type Server struct {
	Store      *store.Store
	config     Config
	mux        *http.ServeMux
	dummyHash  string
	loginSlots chan struct{}
	mu         sync.Mutex
	attempts   map[string]attempt
}
type attempt struct {
	count int
	until time.Time
}
type principal struct {
	User    store.User
	Session string
}
type principalKey struct{}

func New(s *store.Store, c Config) (*Server, error) {
	if c.PublicURL != "" {
		u, err := url.Parse(c.PublicURL)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
			return nil, errors.New("public URL must be an HTTPS origin without a path or credentials")
		}
		c.PublicURL = strings.TrimSuffix(c.PublicURL, "/")
	}
	dummy, err := auth.HashPassword(store.Token())
	if err != nil {
		return nil, err
	}
	v := &Server{Store: s, config: c, mux: http.NewServeMux(), dummyHash: dummy, loginSlots: make(chan struct{}, 4), attempts: map[string]attempt{}}
	v.routes()
	return v, nil
}
func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if s.config.PublicURL != "" {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		if origin := r.Header.Get("Origin"); origin != "" && origin != s.config.PublicURL {
			fail(w, 403, "Cross-origin requests are not allowed.")
			return
		}
		if r.Method == http.MethodOptions {
			fail(w, 405, "Method not allowed.")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 32*1024)
		s.mux.ServeHTTP(w, r)
	})
}
func (s *Server) routes() {
	s.mux.HandleFunc("POST /v1/login", s.login)
	s.mux.Handle("POST /v1/logout", s.require(false, http.HandlerFunc(s.logout)))
	s.mux.Handle("GET /v1/me", s.require(false, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { respond(w, 200, current(r).User) })))
	s.mux.Handle("GET /v1/machines", s.require(false, http.HandlerFunc(s.machines)))
	s.mux.Handle("POST /v1/machines/{id}/connections", s.require(false, http.HandlerFunc(s.connectMachine)))
	s.mux.Handle("POST /v1/connections/{id}/renew", s.require(false, http.HandlerFunc(s.renew)))
	s.mux.Handle("DELETE /v1/connections/{id}", s.require(false, http.HandlerFunc(s.release)))
	s.mux.HandleFunc("POST /v1/host/heartbeat", s.heartbeat)
	s.mux.Handle("GET /v1/admin/users", s.require(true, http.HandlerFunc(s.listUsers)))
	s.mux.Handle("POST /v1/admin/users", s.require(true, http.HandlerFunc(s.createUser)))
	s.mux.Handle("PATCH /v1/admin/users/{id}", s.require(true, http.HandlerFunc(s.updateUser)))
	s.mux.Handle("GET /v1/admin/machines", s.require(true, http.HandlerFunc(s.listMachines)))
	s.mux.Handle("POST /v1/admin/machines", s.require(true, http.HandlerFunc(s.createMachine)))
	s.mux.Handle("PATCH /v1/admin/machines/{id}", s.require(true, http.HandlerFunc(s.updateMachine)))
	s.mux.Handle("POST /v1/admin/machines/{id}/rotate-token", s.require(true, http.HandlerFunc(s.rotateHostToken)))
	s.mux.Handle("GET /v1/admin/grants", s.require(true, http.HandlerFunc(s.listGrants)))
	s.mux.Handle("PUT /v1/admin/grants/{user}/{machine}", s.require(true, http.HandlerFunc(s.grant)))
	s.mux.Handle("DELETE /v1/admin/grants/{user}/{machine}", s.require(true, http.HandlerFunc(s.revoke)))
	s.mux.Handle("GET /v1/admin/audit", s.require(true, http.HandlerFunc(s.audit)))
	s.mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { respond(w, 200, map[string]bool{"ok": true}) })
	s.staticRoutes()
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		fail(w, 415, "Use application/json.")
		return false
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		fail(w, 400, "Invalid JSON request.")
		return false
	}
	if err := d.Decode(new(any)); err != io.EOF {
		fail(w, 400, "Expected one JSON object.")
		return false
	}
	return true
}
func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ""
	}
	v := strings.TrimPrefix(h, "Bearer ")
	if len(v) != 64 {
		return ""
	}
	if _, err := hex.DecodeString(v); err != nil {
		return ""
	}
	return v
}
func current(r *http.Request) principal { return r.Context().Value(principalKey{}).(principal) }
func (s *Server) require(admin bool, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearer(r)
		if token == "" {
			fail(w, 401, "Sign in to continue.")
			return
		}
		p := principal{Session: store.Hash(token)}
		err := s.Store.DB.QueryRow(`SELECT u.id,u.username,u.admin,u.disabled FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token_hash=? AND s.expires>? AND u.disabled=0`, p.Session, time.Now().Unix()).Scan(&p.User.ID, &p.User.Username, &p.User.Admin, &p.User.Disabled)
		if err != nil {
			fail(w, 401, "Your session has expired. Sign in again.")
			return
		}
		if admin && !p.User.Admin {
			fail(w, 403, "Administrator access is required.")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, p)))
	})
}
func (s *Server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	for _, network := range s.config.TrustedProxies {
		if network.Contains(ip) {
			forwarded := strings.TrimSpace(r.Header.Get("X-Real-IP"))
			if p := net.ParseIP(forwarded); p != nil {
				return p.String()
			}
			break
		}
	}
	return host
}

// Bound both memory and password-hashing work. Unknown users cost the same hash.
func (s *Server) throttle(key string, limit int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if len(s.attempts) >= 10000 {
		for k, v := range s.attempts {
			if now.After(v.until) {
				delete(s.attempts, k)
			}
		}
		if len(s.attempts) >= 10000 {
			return false
		}
	}
	a := s.attempts[key]
	if now.After(a.until) {
		a = attempt{until: now.Add(time.Minute)}
	}
	a.count++
	s.attempts[key] = a
	return a.count <= limit
}
func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if !s.throttle("ip:"+s.clientIP(r), 20) || !s.throttle("global", 120) {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "Too many sign-in attempts. Try again in a minute.")
		return
	}
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Username = store.NormalizeUsername(in.Username)
	if !store.ValidUsername(in.Username) {
		fail(w, 401, "Invalid username or password.")
		return
	}
	if !s.throttle("user:"+in.Username, 10) {
		w.Header().Set("Retry-After", "60")
		fail(w, 429, "Too many sign-in attempts. Try again in a minute.")
		return
	}
	select {
	case s.loginSlots <- struct{}{}:
		defer func() { <-s.loginSlots }()
	default:
		fail(w, 429, "Sign-in service is busy. Try again shortly.")
		return
	}
	var u store.User
	var hash string
	err := s.Store.DB.QueryRow(`SELECT id,username,password_hash,admin,disabled FROM users WHERE username=?`, in.Username).Scan(&u.ID, &u.Username, &hash, &u.Admin, &u.Disabled)
	if err != nil {
		hash = s.dummyHash
	}
	valid := auth.VerifyPassword(hash, in.Password)
	if !valid || err != nil || u.Disabled {
		s.Store.Audit("anonymous", "login_failed", in.Username)
		fail(w, 401, "Invalid username or password.")
		return
	}
	token := store.Token()
	now := time.Now().Unix()
	expiry := now + SessionSeconds
	// Recheck disabled/password state in the write to close a concurrent-reset race.
	result, err := s.Store.DB.Exec(`INSERT INTO sessions(token_hash,user_id,expires,created) SELECT ?,id,?,? FROM users WHERE id=? AND password_hash=? AND disabled=0`, store.Hash(token), expiry, now, u.ID, hash)
	if err != nil {
		fail(w, 500, "Unable to sign in.")
		return
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		fail(w, 401, "Invalid username or password.")
		return
	}
	s.Store.Audit(u.ID, "login", u.ID)
	respond(w, 200, map[string]any{"token": token, "expires_at": expiry, "user": u, "protocol": 1})
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	p := current(r)
	_, err := s.Store.DB.Exec(`DELETE FROM sessions WHERE token_hash=?`, p.Session)
	if err != nil {
		fail(w, 500, "Unable to sign out.")
		return
	}
	s.Store.Audit(p.User.ID, "logout", p.User.ID)
	respond(w, 200, map[string]bool{"ok": true})
}

func certificate(raw string) (canonical, fingerprint string, err error) {
	if len(raw) > 4096 {
		return "", "", errors.New("certificate too large")
	}
	block, rest := pem.Decode([]byte(raw))
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return "", "", errors.New("expected one PEM certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", "", err
	}
	now := time.Now()
	if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
		return "", "", errors.New("certificate has expired or is not yet valid")
	}
	fingerprintBytes := sha256.Sum256(cert.Raw)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw})), hex.EncodeToString(fingerprintBytes[:]), nil
}

func dbError(w http.ResponseWriter, err error) bool {
	if err != nil {
		fail(w, 500, "The database operation failed.")
		return true
	}
	return false
}
func found(w http.ResponseWriter, err error) bool {
	if errors.Is(err, sql.ErrNoRows) {
		fail(w, 404, "Not found.")
		return false
	}
	return !dbError(w, err)
}
