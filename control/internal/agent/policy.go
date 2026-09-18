package agent

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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

func (p Policy) validate() error {
	if p.Protocol != 1 {
		return errors.New("policy protocol must be 1")
	}
	if p.MachineID == "" || len(p.MachineID) > 128 {
		return errors.New("policy machine_id is invalid")
	}
	if p.ServerTime <= 0 || p.ValidUntil <= p.ServerTime || p.ValidUntil > p.ServerTime+90 {
		return errors.New("policy validity window is invalid")
	}
	if p.Leases == nil {
		return errors.New("policy leases must be an array")
	}
	for i, lease := range p.Leases {
		if err := lease.validate(p.ServerTime, p.ValidUntil); err != nil {
			return fmt.Errorf("policy lease %d: %w", i, err)
		}
	}
	return nil
}

func (l Lease) validate(serverTime, validUntil int64) error {
	if l.ID == "" || l.UserID == "" || l.Username == "" {
		return errors.New("required identity field is empty")
	}
	if len(l.Fingerprint) != sha256.Size*2 {
		return errors.New("fingerprint must be a SHA-256 hexadecimal value")
	}
	fingerprint, err := hex.DecodeString(l.Fingerprint)
	if err != nil {
		return errors.New("fingerprint must be a SHA-256 hexadecimal value")
	}
	block, rest := pem.Decode([]byte(l.Certificate))
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return errors.New("certificate must contain exactly one PEM certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return errors.New("certificate is invalid")
	}
	actual := sha256.Sum256(cert.Raw)
	if !equalBytes(fingerprint, actual[:]) {
		return errors.New("certificate fingerprint does not match")
	}
	if l.Expires <= serverTime || l.Expires > validUntil {
		return errors.New("expiry is outside the policy validity window")
	}
	return nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var difference byte
	for i := range a {
		difference |= a[i] ^ b[i]
	}
	return difference == 0
}

func writePolicyAtomic(path string, policy Policy) error {
	data, err := json.Marshal(policy)
	if err != nil {
		return err
	}
	data = append(data, '\n')

	dir := filepath.Dir(filepath.Clean(path))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create policy directory: %w", err)
	}

	tmp, err := os.CreateTemp(dir, ".managed-policy-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary policy: %w", err)
	}
	tmpName := tmp.Name()
	keep := false
	defer func() {
		_ = tmp.Close()
		if !keep {
			_ = os.Remove(tmpName)
		}
	}()

	if err := tmp.Chmod(0600); err != nil {
		return fmt.Errorf("secure temporary policy: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		return fmt.Errorf("write temporary policy: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync temporary policy: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temporary policy: %w", err)
	}
	if err := replaceFile(tmpName, filepath.Clean(path)); err != nil {
		return fmt.Errorf("replace policy: %w", err)
	}
	keep = true
	if err := syncDirectory(dir); err != nil {
		return fmt.Errorf("sync policy directory: %w", err)
	}
	return nil
}

func deletePolicy(path string) error {
	err := os.Remove(filepath.Clean(path))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
