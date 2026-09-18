package server

import (
	"net"
	"net/http"
	"strings"

	"github.com/mikulicf/moonlight-vplus/control/internal/auth"
	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.DB.Query(`SELECT id,username,admin,disabled FROM users ORDER BY username`)
	if dbError(w, err) {
		return
	}
	defer rows.Close()
	out := []store.User{}
	for rows.Next() {
		var u store.User
		if dbError(w, rows.Scan(&u.ID, &u.Username, &u.Admin, &u.Disabled)) {
			return
		}
		out = append(out, u)
	}
	if dbError(w, rows.Err()) {
		return
	}
	respond(w, 200, out)
}
func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Admin    bool   `json:"admin"`
	}
	if !decode(w, r, &in) {
		return
	}
	hash, err := auth.HashPassword(in.Password)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	user, err := s.Store.CreateUser(in.Username, hash, in.Admin)
	if err != nil {
		fail(w, 409, "Unable to create user. Check the username and whether it already exists.")
		return
	}
	s.Store.Audit(current(r).User.ID, "user_created", user.ID)
	respond(w, 201, user)
}
func (s *Server) updateUser(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Password *string `json:"password"`
		Admin    *bool   `json:"admin"`
		Disabled *bool   `json:"disabled"`
	}
	if !decode(w, r, &in) {
		return
	}
	var hash string
	var err error
	if in.Password != nil {
		hash, err = auth.HashPassword(*in.Password)
		if err != nil {
			fail(w, 400, err.Error())
			return
		}
	}
	tx, err := s.Store.DB.Begin()
	if dbError(w, err) {
		return
	}
	defer tx.Rollback()
	var u store.User
	err = tx.QueryRow(`SELECT id,username,admin,disabled FROM users WHERE id=?`, r.PathValue("id")).Scan(&u.ID, &u.Username, &u.Admin, &u.Disabled)
	if !found(w, err) {
		return
	}
	if in.Admin != nil {
		u.Admin = *in.Admin
	}
	if in.Disabled != nil {
		u.Disabled = *in.Disabled
	}
	if !u.Admin || u.Disabled {
		var others int
		err = tx.QueryRow(`SELECT COUNT(*) FROM users WHERE admin=1 AND disabled=0 AND id<>?`, u.ID).Scan(&others)
		if dbError(w, err) {
			return
		}
		if others == 0 {
			fail(w, 409, "Keep at least one active administrator.")
			return
		}
	}
	if hash != "" {
		_, err = tx.Exec(`UPDATE users SET password_hash=? WHERE id=?`, hash, u.ID)
		if dbError(w, err) {
			return
		}
	}
	_, err = tx.Exec(`UPDATE users SET admin=?,disabled=? WHERE id=?`, u.Admin, u.Disabled, u.ID)
	if dbError(w, err) {
		return
	}
	// Password or privilege changes invalidate sessions and all their host leases.
	_, err = tx.Exec(`DELETE FROM sessions WHERE user_id=?`, u.ID)
	if dbError(w, err) {
		return
	}
	if dbError(w, tx.Commit()) {
		return
	}
	s.Store.Audit(current(r).User.ID, "user_updated", u.ID)
	respond(w, 200, u)
}
func (s *Server) listMachines(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.DB.Query(`SELECT ` + store.MachineColumns + ` FROM machines ORDER BY name,id`)
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
func validAddress(v string) bool {
	if len(v) == 0 || len(v) > 253 || strings.ContainsAny(v, "/@?#\\\t\r\n ") {
		return false
	}
	if net.ParseIP(v) != nil {
		return true
	}
	for _, label := range strings.Split(v, ".") {
		if len(label) == 0 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}
func validMachine(m store.Machine) bool {
	return len(strings.TrimSpace(m.Name)) > 0 && len(m.Name) <= 128 && validAddress(m.Address) && m.HTTPPort > 0 && m.HTTPPort <= 65535 && m.HTTPSPort > 0 && m.HTTPSPort <= 65535
}
func (s *Server) createMachine(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name      string `json:"name"`
		Address   string `json:"address"`
		HTTPPort  int    `json:"http_port"`
		HTTPSPort int    `json:"https_port"`
	}
	if !decode(w, r, &in) {
		return
	}
	m := store.Machine{ID: store.ID(), Name: strings.TrimSpace(in.Name), Address: strings.TrimSpace(in.Address), HTTPPort: in.HTTPPort, HTTPSPort: in.HTTPSPort}
	if !validMachine(m) {
		fail(w, 400, "Provide a name, hostname or IP address without a scheme, and valid host HTTP/HTTPS ports.")
		return
	}
	token := store.Token()
	_, err := s.Store.DB.Exec(`INSERT INTO machines(id,name,address,http_port,https_port,token_hash) VALUES(?,?,?,?,?,?)`, m.ID, m.Name, m.Address, m.HTTPPort, m.HTTPSPort, store.Hash(token))
	if dbError(w, err) {
		return
	}
	s.Store.Audit(current(r).User.ID, "machine_created", m.ID)
	respond(w, 201, map[string]any{"machine": m, "host_token": token})
}
func (s *Server) updateMachine(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name      *string `json:"name"`
		Address   *string `json:"address"`
		HTTPPort  *int    `json:"http_port"`
		HTTPSPort *int    `json:"https_port"`
		Disabled  *bool   `json:"disabled"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, err := s.Store.DB.Begin()
	if dbError(w, err) {
		return
	}
	defer tx.Rollback()
	m, err := store.ScanMachine(tx.QueryRow(`SELECT `+store.MachineColumns+` FROM machines WHERE id=?`, r.PathValue("id")))
	if !found(w, err) {
		return
	}
	if in.Name != nil {
		m.Name = strings.TrimSpace(*in.Name)
	}
	if in.Address != nil {
		m.Address = strings.TrimSpace(*in.Address)
	}
	if in.HTTPPort != nil {
		m.HTTPPort = *in.HTTPPort
	}
	if in.HTTPSPort != nil {
		m.HTTPSPort = *in.HTTPSPort
	}
	if in.Disabled != nil {
		m.Disabled = *in.Disabled
	}
	if !validMachine(m) {
		fail(w, 400, "Invalid machine details.")
		return
	}
	_, err = tx.Exec(`UPDATE machines SET name=?,address=?,http_port=?,https_port=?,disabled=? WHERE id=?`, m.Name, m.Address, m.HTTPPort, m.HTTPSPort, m.Disabled, m.ID)
	if dbError(w, err) {
		return
	}
	_, err = tx.Exec(`DELETE FROM leases WHERE machine_id=?`, m.ID)
	if dbError(w, err) {
		return
	}
	if dbError(w, tx.Commit()) {
		return
	}
	s.Store.Audit(current(r).User.ID, "machine_updated", m.ID)
	respond(w, 200, m)
}
func (s *Server) rotateHostToken(w http.ResponseWriter, r *http.Request) {
	token := store.Token()
	tx, err := s.Store.DB.Begin()
	if dbError(w, err) {
		return
	}
	defer tx.Rollback()
	result, err := tx.Exec(`UPDATE machines SET token_hash=?,last_seen=0,managed_protocol=0 WHERE id=?`, store.Hash(token), r.PathValue("id"))
	if dbError(w, err) {
		return
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		fail(w, 404, "Not found.")
		return
	}
	_, err = tx.Exec(`DELETE FROM leases WHERE machine_id=?`, r.PathValue("id"))
	if dbError(w, err) {
		return
	}
	if dbError(w, tx.Commit()) {
		return
	}
	s.Store.Audit(current(r).User.ID, "host_token_rotated", r.PathValue("id"))
	respond(w, 200, map[string]string{"host_token": token})
}

type grantRecord struct {
	UserID    string `json:"user_id"`
	MachineID string `json:"machine_id"`
}

func (s *Server) listGrants(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.DB.Query(`SELECT user_id,machine_id FROM grants ORDER BY user_id,machine_id`)
	if dbError(w, err) {
		return
	}
	defer rows.Close()
	out := []grantRecord{}
	for rows.Next() {
		var g grantRecord
		if dbError(w, rows.Scan(&g.UserID, &g.MachineID)) {
			return
		}
		out = append(out, g)
	}
	if dbError(w, rows.Err()) {
		return
	}
	respond(w, 200, out)
}
func (s *Server) grant(w http.ResponseWriter, r *http.Request) {
	var exists int
	err := s.Store.DB.QueryRow(`SELECT 1 FROM users u,machines m WHERE u.id=? AND m.id=?`, r.PathValue("user"), r.PathValue("machine")).Scan(&exists)
	if !found(w, err) {
		return
	}
	_, err = s.Store.DB.Exec(`INSERT INTO grants(user_id,machine_id) VALUES(?,?) ON CONFLICT DO NOTHING`, r.PathValue("user"), r.PathValue("machine"))
	if dbError(w, err) {
		return
	}
	s.Store.Audit(current(r).User.ID, "access_granted", r.PathValue("user")+":"+r.PathValue("machine"))
	respond(w, 200, map[string]bool{"ok": true})
}
func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	tx, err := s.Store.DB.Begin()
	if dbError(w, err) {
		return
	}
	defer tx.Rollback()
	_, err = tx.Exec(`DELETE FROM grants WHERE user_id=? AND machine_id=?`, r.PathValue("user"), r.PathValue("machine"))
	if dbError(w, err) {
		return
	}
	_, err = tx.Exec(`DELETE FROM leases WHERE machine_id=? AND session_hash IN(SELECT token_hash FROM sessions WHERE user_id=?)`, r.PathValue("machine"), r.PathValue("user"))
	if dbError(w, err) {
		return
	}
	if dbError(w, tx.Commit()) {
		return
	}
	s.Store.Audit(current(r).User.ID, "access_revoked", r.PathValue("user")+":"+r.PathValue("machine"))
	respond(w, 200, map[string]bool{"ok": true})
}
func (s *Server) audit(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.DB.Query(`SELECT at,actor,event,target FROM audit ORDER BY id DESC LIMIT 200`)
	if dbError(w, err) {
		return
	}
	defer rows.Close()
	type record struct {
		At     int64  `json:"at"`
		Actor  string `json:"actor"`
		Event  string `json:"event"`
		Target string `json:"target"`
	}
	out := []record{}
	for rows.Next() {
		var v record
		if dbError(w, rows.Scan(&v.At, &v.Actor, &v.Event, &v.Target)) {
			return
		}
		out = append(out, v)
	}
	if dbError(w, rows.Err()) {
		return
	}
	respond(w, 200, out)
}

// Bootstrap creates an administrator using a password supplied locally, never a default.
func Bootstrap(s *store.Store, username, password string) (store.User, error) {
	hash, err := auth.HashPassword(password)
	if err != nil {
		return store.User{}, err
	}
	return s.CreateUser(username, hash, true)
}

// ResetPassword is a local recovery operation; it also revokes all existing sessions.
func ResetPassword(s *store.Store, username, password string) error {
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var id string
	if err = tx.QueryRow(`SELECT id FROM users WHERE username=?`, store.NormalizeUsername(username)).Scan(&id); err != nil {
		return err
	}
	if _, err = tx.Exec(`UPDATE users SET password_hash=? WHERE id=?`, hash, id); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM sessions WHERE user_id=?`, id); err != nil {
		return err
	}
	if err = tx.Commit(); err == nil {
		s.Audit("local", "password_reset", id)
	}
	return err
}
