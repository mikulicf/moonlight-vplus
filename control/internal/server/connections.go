package server

import (
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"errors"
	"net/http"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

const maxActiveLeasesPerMachine = 64

func validLeaseCertificate(raw, expectedFingerprint string) (notAfter int64, ok bool) {
	canonical, fingerprint, err := certificate(raw)
	if err != nil || fingerprint != expectedFingerprint {
		return 0, false
	}
	block, _ := pem.Decode([]byte(canonical))
	if block == nil {
		return 0, false
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return 0, false
	}
	return cert.NotAfter.Unix(), true
}

func (s *Server) machines(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.DB.Query(`SELECT `+store.MachineColumns+` FROM machines WHERE disabled=0 AND id IN(SELECT machine_id FROM grants WHERE user_id=?) ORDER BY name,id`, current(r).User.ID)
	if dbError(w, err) {
		return
	}
	defer rows.Close()
	out := []store.Machine{}
	for rows.Next() {
		m, err := store.ScanMachine(rows)
		if dbError(w, err) {
			return
		}
		out = append(out, m)
	}
	if dbError(w, rows.Err()) {
		return
	}
	respond(w, 200, out)
}
func (s *Server) authorizedMachine(r *http.Request, id string) (store.Machine, error) {
	return store.ScanMachine(s.Store.DB.QueryRow(`SELECT `+store.MachineColumns+` FROM machines WHERE id=? AND disabled=0 AND id IN(SELECT machine_id FROM grants WHERE user_id=?)`, id, current(r).User.ID))
}
func (s *Server) connectMachine(w http.ResponseWriter, r *http.Request) {
	m, err := s.authorizedMachine(r, r.PathValue("id"))
	if !found(w, err) {
		return
	}
	now := time.Now().Unix()
	if m.ManagedProtocol != 1 || m.LastSeen < now-30 || m.ServerCertificate == "" || m.HostUUID == "" {
		fail(w, 409, "The host is offline or managed access is not ready.")
		return
	}
	var in struct {
		Certificate string `json:"client_certificate"`
	}
	if !decode(w, r, &in) {
		return
	}
	cert, fingerprint, err := certificate(in.Certificate)
	if err != nil {
		fail(w, 400, "A valid client certificate is required.")
		return
	}
	p := current(r)
	id := store.ID()
	expires := now + LeaseSeconds
	certificateExpiry, ok := validLeaseCertificate(cert, fingerprint)
	if !ok || certificateExpiry <= now {
		fail(w, 400, "A valid client certificate is required.")
		return
	}
	if expires > certificateExpiry {
		expires = certificateExpiry
	}
	// Authorization, the per-machine cap, and lease creation are one SQLite
	// statement. An existing lease may be refreshed even when the cap is full.
	result, err := s.Store.DB.Exec(`INSERT INTO leases(id,session_hash,machine_id,fingerprint,certificate,expires)
	 SELECT ?,?,?,?,?,?
	 WHERE EXISTS(SELECT 1 FROM grants g JOIN users u ON u.id=g.user_id JOIN machines m ON m.id=g.machine_id JOIN sessions s ON s.user_id=u.id WHERE g.user_id=? AND g.machine_id=? AND s.token_hash=? AND s.expires>? AND u.disabled=0 AND m.disabled=0)
	 AND (EXISTS(SELECT 1 FROM leases WHERE session_hash=? AND machine_id=? AND fingerprint=? AND expires>?)
	      OR (SELECT COUNT(*) FROM leases WHERE machine_id=? AND expires>?) < ?)
	 ON CONFLICT(session_hash,machine_id,fingerprint) DO UPDATE SET certificate=excluded.certificate,expires=excluded.expires`,
		id, p.Session, m.ID, fingerprint, cert, expires,
		p.User.ID, m.ID, p.Session, now,
		p.Session, m.ID, fingerprint, now, m.ID, now, maxActiveLeasesPerMachine)
	if dbError(w, err) {
		return
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		var authorized bool
		err = s.Store.DB.QueryRow(`SELECT EXISTS(SELECT 1 FROM grants g JOIN users u ON u.id=g.user_id JOIN machines m ON m.id=g.machine_id JOIN sessions s ON s.user_id=u.id WHERE g.user_id=? AND g.machine_id=? AND s.token_hash=? AND s.expires>? AND u.disabled=0 AND m.disabled=0)`, p.User.ID, m.ID, p.Session, now).Scan(&authorized)
		if dbError(w, err) {
			return
		}
		if !authorized {
			fail(w, 403, "Access is no longer available.")
		} else {
			fail(w, 429, "This host has reached its active connection limit.")
		}
		return
	}
	err = s.Store.DB.QueryRow(`SELECT id FROM leases WHERE session_hash=? AND machine_id=? AND fingerprint=?`, p.Session, m.ID, fingerprint).Scan(&id)
	if dbError(w, err) {
		return
	}
	s.Store.Audit(p.User.ID, "connection_granted", m.ID)
	respond(w, 200, map[string]any{"lease_id": id, "expires_at": expires, "machine": m, "ready_after_ms": 1500})
}
func (s *Server) renew(w http.ResponseWriter, r *http.Request) {
	p := current(r)
	now := time.Now().Unix()
	var storedCertificate, storedFingerprint string
	err := s.Store.DB.QueryRow(`SELECT certificate,fingerprint FROM leases WHERE id=? AND session_hash=?`, r.PathValue("id"), p.Session).Scan(&storedCertificate, &storedFingerprint)
	if errors.Is(err, sql.ErrNoRows) {
		fail(w, 403, "Machine access has expired or was removed.")
		return
	}
	if dbError(w, err) {
		return
	}
	certificateExpiry, ok := validLeaseCertificate(storedCertificate, storedFingerprint)
	if !ok || certificateExpiry <= now {
		fail(w, 403, "Machine access has expired or was removed.")
		return
	}
	expires := now + LeaseSeconds
	if expires > certificateExpiry {
		expires = certificateExpiry
	}
	result, err := s.Store.DB.Exec(`UPDATE leases SET expires=? WHERE id=? AND session_hash=? AND certificate=? AND fingerprint=? AND expires>? AND EXISTS(SELECT 1 FROM grants g JOIN users u ON u.id=g.user_id JOIN machines m ON m.id=g.machine_id JOIN sessions s ON s.user_id=u.id WHERE g.user_id=? AND g.machine_id=leases.machine_id AND s.token_hash=? AND s.expires>? AND u.disabled=0 AND m.disabled=0)`, expires, r.PathValue("id"), p.Session, storedCertificate, storedFingerprint, now, p.User.ID, p.Session, now)
	if dbError(w, err) {
		return
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		fail(w, 403, "Machine access has expired or was removed.")
		return
	}
	respond(w, 200, map[string]any{"expires_at": expires})
}
func (s *Server) release(w http.ResponseWriter, r *http.Request) {
	_, err := s.Store.DB.Exec(`DELETE FROM leases WHERE id=? AND session_hash=?`, r.PathValue("id"), current(r).Session)
	if dbError(w, err) {
		return
	}
	respond(w, 200, map[string]bool{"ok": true})
}

type Lease struct {
	ID          string `json:"id"`
	Fingerprint string `json:"fingerprint"`
	Certificate string `json:"certificate"`
	UserID      string `json:"user_id"`
	Username    string `json:"username"`
	Expires     int64  `json:"expires_at"`
}
type Policy struct {
	Protocol   int     `json:"protocol"`
	MachineID  string  `json:"machine_id"`
	ServerTime int64   `json:"server_time"`
	ValidUntil int64   `json:"valid_until"`
	Leases     []Lease `json:"leases"`
}

func (s *Server) heartbeat(w http.ResponseWriter, r *http.Request) {
	token := bearer(r)
	if token == "" {
		fail(w, 401, "Host authentication required.")
		return
	}
	var id string
	err := s.Store.DB.QueryRow(`SELECT id FROM machines WHERE token_hash=? AND disabled=0`, store.Hash(token)).Scan(&id)
	if err == sql.ErrNoRows {
		fail(w, 401, "Host credential is invalid or disabled.")
		return
	}
	if dbError(w, err) {
		return
	}
	var in struct {
		HostUUID          string `json:"host_uuid"`
		ServerCertificate string `json:"server_certificate"`
		ManagedProtocol   int    `json:"managed_protocol"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.HostUUID) < 1 || len(in.HostUUID) > 128 || in.ManagedProtocol != 1 {
		fail(w, 400, "Managed host protocol 1 is required.")
		return
	}
	cert, _, err := certificate(in.ServerCertificate)
	if err != nil {
		fail(w, 400, "A valid host certificate is required.")
		return
	}
	now := time.Now().Unix()
	_, err = s.Store.DB.Exec(`UPDATE machines SET host_uuid=?,server_certificate=?,managed_protocol=?,last_seen=? WHERE id=?`, in.HostUUID, cert, in.ManagedProtocol, now, id)
	if dbError(w, err) {
		return
	}
	rows, err := s.Store.DB.Query(`SELECT l.id,l.fingerprint,l.certificate,u.id,u.username,l.expires FROM leases l JOIN sessions s ON s.token_hash=l.session_hash JOIN users u ON u.id=s.user_id JOIN grants g ON g.user_id=u.id AND g.machine_id=l.machine_id WHERE l.machine_id=? AND l.expires>? AND s.expires>? AND u.disabled=0 ORDER BY l.id`, id, now, now)
	if dbError(w, err) {
		return
	}
	defer rows.Close()
	policy := Policy{Protocol: 1, MachineID: id, ServerTime: now, ValidUntil: now + LeaseSeconds, Leases: []Lease{}}
	for rows.Next() {
		var l Lease
		if dbError(w, rows.Scan(&l.ID, &l.Fingerprint, &l.Certificate, &l.UserID, &l.Username, &l.Expires)) {
			return
		}
		certificateExpiry, ok := validLeaseCertificate(l.Certificate, l.Fingerprint)
		if !ok || certificateExpiry <= now {
			continue
		}
		if l.Expires > certificateExpiry {
			l.Expires = certificateExpiry
		}
		if l.Expires > now {
			policy.Leases = append(policy.Leases, l)
		}
	}
	if dbError(w, rows.Err()) {
		return
	}
	respond(w, 200, policy)
}
