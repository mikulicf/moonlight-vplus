package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

type leaseTestState struct {
	env             *testEnvironment
	userID          string
	userToken       string
	sessionHash     string
	machineID       string
	hostToken       string
	hostCertificate string
}

func certificateWithWindow(t *testing.T, commonName string, notBefore, notAfter time.Time) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate certificate key: %v", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatalf("generate certificate serial: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	fingerprint := sha256.Sum256(raw)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})), hex.EncodeToString(fingerprint[:])
}

func newLeaseTestState(t *testing.T) leaseTestState {
	t.Helper()
	env := newTestEnvironment(t)
	now := time.Now()
	userID := store.ID()
	userToken := store.Token()
	sessionHash := store.Hash(userToken)
	machineID := store.ID()
	hostToken := store.Token()
	hostCertificate := testCertificate(t, "lease-test-host")
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO users(id,username,password_hash,admin,disabled) VALUES(?,?,?,0,0)`, []any{userID, "lease-user", "unused-in-test"}},
		{`INSERT INTO sessions(token_hash,user_id,expires,created) VALUES(?,?,?,?)`, []any{sessionHash, userID, now.Add(time.Hour).Unix(), now.Unix()}},
		{`INSERT INTO machines(id,name,address,http_port,https_port,token_hash,host_uuid,server_certificate,last_seen,managed_protocol) VALUES(?,?,?,?,?,?,?,?,?,1)`, []any{machineID, "Lease Host", "host.internal", 47989, 47984, store.Hash(hostToken), "lease-host-uuid", hostCertificate, now.Unix()}},
		{`INSERT INTO grants(user_id,machine_id) VALUES(?,?)`, []any{userID, machineID}},
	}
	for _, statement := range statements {
		if _, err := env.store.DB.Exec(statement.query, statement.args...); err != nil {
			t.Fatalf("seed lease test: %v", err)
		}
	}
	return leaseTestState{
		env:             env,
		userID:          userID,
		userToken:       userToken,
		sessionHash:     sessionHash,
		machineID:       machineID,
		hostToken:       hostToken,
		hostCertificate: hostCertificate,
	}
}

func insertLease(t *testing.T, state leaseTestState, id, fingerprint, certificate string, expires int64) {
	t.Helper()
	_, err := state.env.store.DB.Exec(`INSERT INTO leases(id,session_hash,machine_id,fingerprint,certificate,expires) VALUES(?,?,?,?,?,?)`, id, state.sessionHash, state.machineID, fingerprint, certificate, expires)
	if err != nil {
		t.Fatalf("insert lease: %v", err)
	}
}

func rawConnect(handler http.Handler, token, machineID, certificate string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"client_certificate": certificate})
	req := httptest.NewRequest(http.MethodPost, "/v1/machines/"+machineID+"/connections", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", testOrigin)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func TestLeaseCapIsAtomicAndExistingLeaseCanRefresh(t *testing.T) {
	state := newLeaseTestState(t)
	now := time.Now()
	existingCertificate, existingFingerprint := certificateWithWindow(t, "existing-client", now.Add(-time.Minute), now.Add(time.Hour))
	existingID := store.ID()
	insertLease(t, state, existingID, existingFingerprint, existingCertificate, now.Add(time.Minute).Unix())
	for i := 1; i < maxActiveLeasesPerMachine; i++ {
		insertLease(t, state, store.ID(), fmt.Sprintf("%064x", i), "legacy-invalid-certificate", now.Add(time.Minute).Unix())
	}

	reconnected := connect(t, state.env, state.userToken, state.machineID, existingCertificate, http.StatusOK)
	if reconnected.LeaseID != existingID {
		t.Fatalf("reconnect lease ID = %q, want existing %q", reconnected.LeaseID, existingID)
	}
	requireStatus(t, request(t, state.env, http.MethodPost, "/v1/connections/"+existingID+"/renew", state.userToken, "", testOrigin), http.StatusOK)
	newCertificate, _ := certificateWithWindow(t, "over-cap-client", now.Add(-time.Minute), now.Add(time.Hour))
	connect(t, state.env, state.userToken, state.machineID, newCertificate, http.StatusTooManyRequests)
	expiredLeaseCertificate, expiredLeaseFingerprint := certificateWithWindow(t, "expired-lease-client", now.Add(-time.Minute), now.Add(time.Hour))
	expiredLeaseID := store.ID()
	insertLease(t, state, expiredLeaseID, expiredLeaseFingerprint, expiredLeaseCertificate, now.Add(-time.Second).Unix())
	connect(t, state.env, state.userToken, state.machineID, expiredLeaseCertificate, http.StatusTooManyRequests)
	requireStatus(t, request(t, state.env, http.MethodPost, "/v1/connections/"+expiredLeaseID+"/renew", state.userToken, "", testOrigin), http.StatusForbidden)

	if _, err := state.env.store.DB.Exec(`DELETE FROM leases`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < maxActiveLeasesPerMachine-1; i++ {
		insertLease(t, state, store.ID(), fmt.Sprintf("%064x", i+1000), "legacy-invalid-certificate", now.Add(time.Minute).Unix())
	}

	const contenders = 8
	bodies := make([]string, contenders)
	for i := range bodies {
		certificate, _ := certificateWithWindow(t, fmt.Sprintf("concurrent-client-%d", i), now.Add(-time.Minute), now.Add(time.Hour))
		bodies[i] = certificate
	}
	start := make(chan struct{})
	responses := make(chan int, contenders)
	var group sync.WaitGroup
	for i := range bodies {
		group.Add(1)
		go func(certificate string) {
			defer group.Done()
			<-start
			responses <- rawConnect(state.env.handler, state.userToken, state.machineID, certificate).Code
		}(bodies[i])
	}
	close(start)
	group.Wait()
	close(responses)

	successes, limited := 0, 0
	for status := range responses {
		switch status {
		case http.StatusOK:
			successes++
		case http.StatusTooManyRequests:
			limited++
		default:
			t.Fatalf("concurrent connect returned status %d", status)
		}
	}
	if successes != 1 || limited != contenders-1 {
		t.Fatalf("concurrent results: %d success, %d limited; want 1 and %d", successes, limited, contenders-1)
	}
	var active int
	if err := state.env.store.DB.QueryRow(`SELECT COUNT(*) FROM leases WHERE machine_id=? AND expires>?`, state.machineID, time.Now().Unix()).Scan(&active); err != nil {
		t.Fatal(err)
	}
	if active != maxActiveLeasesPerMachine {
		t.Fatalf("active lease count = %d, want %d", active, maxActiveLeasesPerMachine)
	}
}

func TestLeaseCertificateExpiryBoundsAndPolicyFiltering(t *testing.T) {
	state := newLeaseTestState(t)
	now := time.Now()
	nearExpiry := now.Add(45 * time.Second).Truncate(time.Second)
	nearCertificate, _ := certificateWithWindow(t, "short-client", now.Add(-time.Minute), nearExpiry)
	shortLease := connect(t, state.env, state.userToken, state.machineID, nearCertificate, http.StatusOK)
	if shortLease.ExpiresAt > nearExpiry.Unix() || shortLease.ExpiresAt <= now.Unix() {
		t.Fatalf("short-certificate lease expiry = %d, certificate NotAfter = %d", shortLease.ExpiresAt, nearExpiry.Unix())
	}

	expiredCertificate, expiredFingerprint := certificateWithWindow(t, "expired-client", now.Add(-2*time.Hour), now.Add(-time.Hour))
	expiredID := store.ID()
	insertLease(t, state, expiredID, expiredFingerprint, expiredCertificate, now.Add(time.Minute).Unix())
	invalidID := store.ID()
	insertLease(t, state, invalidID, strings.Repeat("a", 64), "not a certificate", now.Add(time.Minute).Unix())

	requireStatus(t, request(t, state.env, http.MethodPost, "/v1/connections/"+expiredID+"/renew", state.userToken, "", testOrigin), http.StatusForbidden)
	requireStatus(t, request(t, state.env, http.MethodPost, "/v1/connections/"+invalidID+"/renew", state.userToken, "", testOrigin), http.StatusForbidden)

	policy := heartbeat(t, state.env, state.hostToken, "lease-host-uuid", state.hostCertificate, http.StatusOK)
	if len(policy.Leases) != 1 || policy.Leases[0].ID != shortLease.LeaseID {
		t.Fatalf("policy included expired or invalid certificate leases: %#v", policy.Leases)
	}
	if policy.Leases[0].Expires > nearExpiry.Unix() {
		t.Fatalf("policy lease expiry = %d, certificate NotAfter = %d", policy.Leases[0].Expires, nearExpiry.Unix())
	}
}
