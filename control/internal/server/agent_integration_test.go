package server_test

import (
	"bytes"
	"context"
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
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/agent"
	controlserver "github.com/mikulicf/moonlight-vplus/control/internal/server"
	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

const (
	integrationAdminPassword = "integration admin password"
	integrationUserPassword  = "integration user password"
)

type integrationLogin struct {
	Token string     `json:"token"`
	User  store.User `json:"user"`
}

type integrationMachineCreated struct {
	Machine   store.Machine `json:"machine"`
	HostToken string        `json:"host_token"`
}

type integrationLease struct {
	LeaseID   string        `json:"lease_id"`
	Machine   store.Machine `json:"machine"`
	ExpiresAt int64         `json:"expires_at"`
}

func integrationCertificate(t *testing.T, commonName string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate certificate key: %v", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatalf("generate serial: %v", err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	fingerprint := sha256.Sum256(raw)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})), hex.EncodeToString(fingerprint[:])
}

func integrationRequest(t *testing.T, client *http.Client, method, url, token string, body any, want int, output any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("encode %s %s: %v", method, url, err)
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatalf("create %s %s: %v", method, url, err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(req)
	if err != nil {
		t.Fatalf("send %s %s: %v", method, url, err)
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		t.Fatalf("read %s %s: %v", method, url, err)
	}
	if response.StatusCode != want {
		t.Fatalf("%s %s status = %d, want %d; body: %s", method, url, response.StatusCode, want, payload)
	}
	if output != nil {
		if err := json.Unmarshal(payload, output); err != nil {
			t.Fatalf("decode %s %s response %q: %v", method, url, payload, err)
		}
	}
}

func readIntegrationPolicy(t *testing.T, path string) agent.Policy {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read agent policy: %v", err)
	}
	var policy agent.Policy
	if err := json.Unmarshal(payload, &policy); err != nil {
		t.Fatalf("decode agent policy: %v", err)
	}
	return policy
}

func TestBackendAndAgentManagedAccessLifecycle(t *testing.T) {
	database, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	application, err := controlserver.New(database, controlserver.Config{PublicURL: "https://control.invalid"})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	backend := httptest.NewTLSServer(application.Handler())
	t.Cleanup(backend.Close)

	temporary := t.TempDir()
	backendCA := filepath.Join(temporary, "backend-ca.pem")
	backendDER := backend.Certificate().Raw
	if err := os.WriteFile(backendCA, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: backendDER}), 0600); err != nil {
		t.Fatalf("write backend CA: %v", err)
	}
	hostCertificate, _ := integrationCertificate(t, "managed-host")
	hostCertificateFile := filepath.Join(temporary, "host-certificate.pem")
	if err := os.WriteFile(hostCertificateFile, []byte(hostCertificate), 0600); err != nil {
		t.Fatalf("write host certificate: %v", err)
	}
	policyFile := filepath.Join(temporary, "policy", "managed-policy.json")

	const hostUUID = "integration-managed-host"
	apollo := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/serverinfo" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		_, _ = fmt.Fprintf(w, `<root status_code="200"><uniqueid>%s</uniqueid><ManagedAccessProtocol>1</ManagedAccessProtocol></root>`, hostUUID)
	}))
	t.Cleanup(apollo.Close)
	_, rawPort, err := net.SplitHostPort(apollo.Listener.Addr().String())
	if err != nil {
		t.Fatalf("parse fake Apollo address: %v", err)
	}
	httpPort, err := strconv.Atoi(rawPort)
	if err != nil {
		t.Fatalf("parse fake Apollo port: %v", err)
	}

	admin, err := controlserver.Bootstrap(database, "integration-admin", integrationAdminPassword)
	if err != nil {
		t.Fatalf("bootstrap admin: %v", err)
	}
	var adminLogin integrationLogin
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/login", "", map[string]string{
		"username": admin.Username,
		"password": integrationAdminPassword,
	}, http.StatusOK, &adminLogin)

	var user store.User
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/admin/users", adminLogin.Token, map[string]any{
		"username": "integration-viewer",
		"password": integrationUserPassword,
		"admin":    false,
	}, http.StatusCreated, &user)
	var userLogin integrationLogin
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/login", "", map[string]string{
		"username": user.Username,
		"password": integrationUserPassword,
	}, http.StatusOK, &userLogin)

	var created integrationMachineCreated
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/admin/machines", adminLogin.Token, map[string]any{
		"name":       "Integration Host",
		"address":    "host.invalid",
		"http_port":  47989,
		"https_port": 47984,
	}, http.StatusCreated, &created)
	integrationRequest(t, backend.Client(), http.MethodPut, backend.URL+"/v1/admin/grants/"+user.ID+"/"+created.Machine.ID, adminLogin.Token, nil, http.StatusOK, nil)

	configuration := agent.Config{
		BackendURL:            backend.URL,
		HostToken:             created.HostToken,
		PolicyFile:            policyFile,
		ServerCertificateFile: hostCertificateFile,
		HTTPPort:              httpPort,
		CAFile:                backendCA,
	}
	hostAgent, err := agent.New(configuration, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatalf("create real host agent: %v", err)
	}
	if err := hostAgent.Poll(context.Background()); err != nil {
		t.Fatalf("initial real agent poll: %v", err)
	}
	initialPolicy := readIntegrationPolicy(t, policyFile)
	if initialPolicy.Protocol != 1 || initialPolicy.MachineID != created.Machine.ID || len(initialPolicy.Leases) != 0 {
		t.Fatalf("initial policy = %#v", initialPolicy)
	}

	var visible []store.Machine
	integrationRequest(t, backend.Client(), http.MethodGet, backend.URL+"/v1/machines", userLogin.Token, nil, http.StatusOK, &visible)
	if len(visible) != 1 || visible[0].ID != created.Machine.ID || visible[0].ManagedProtocol != 1 || visible[0].HostUUID != hostUUID {
		t.Fatalf("ready machine list = %#v", visible)
	}

	clientCertificate, clientFingerprint := integrationCertificate(t, "managed-client")
	var lease integrationLease
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/machines/"+created.Machine.ID+"/connections", userLogin.Token, map[string]string{
		"client_certificate": clientCertificate,
	}, http.StatusOK, &lease)
	if lease.LeaseID == "" || lease.Machine.ID != created.Machine.ID || lease.ExpiresAt <= time.Now().Unix() {
		t.Fatalf("connection response = %#v", lease)
	}
	if err := hostAgent.Poll(context.Background()); err != nil {
		t.Fatalf("agent poll with lease: %v", err)
	}
	policy := readIntegrationPolicy(t, policyFile)
	if len(policy.Leases) != 1 || policy.Leases[0].ID != lease.LeaseID || policy.Leases[0].Fingerprint != clientFingerprint {
		t.Fatalf("policy after connect = %#v", policy)
	}

	var renewed struct {
		ExpiresAt int64 `json:"expires_at"`
	}
	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/connections/"+lease.LeaseID+"/renew", userLogin.Token, nil, http.StatusOK, &renewed)
	if renewed.ExpiresAt < lease.ExpiresAt {
		t.Fatalf("renewed expiry %d is before original %d", renewed.ExpiresAt, lease.ExpiresAt)
	}

	integrationRequest(t, backend.Client(), http.MethodDelete, backend.URL+"/v1/admin/grants/"+user.ID+"/"+created.Machine.ID, adminLogin.Token, nil, http.StatusOK, nil)
	if err := hostAgent.Poll(context.Background()); err != nil {
		t.Fatalf("agent poll after revoke: %v", err)
	}
	if policy := readIntegrationPolicy(t, policyFile); len(policy.Leases) != 0 {
		t.Fatalf("revoked lease remained in policy: %#v", policy.Leases)
	}

	integrationRequest(t, backend.Client(), http.MethodPatch, backend.URL+"/v1/admin/machines/"+created.Machine.ID, adminLogin.Token, map[string]bool{"disabled": true}, http.StatusOK, nil)
	if err := hostAgent.Poll(context.Background()); err == nil {
		t.Fatal("disabled host agent poll unexpectedly succeeded")
	}
	if _, err := os.Stat(policyFile); !os.IsNotExist(err) {
		t.Fatalf("disabled host did not fail closed; policy stat error = %v", err)
	}

	integrationRequest(t, backend.Client(), http.MethodPatch, backend.URL+"/v1/admin/machines/"+created.Machine.ID, adminLogin.Token, map[string]bool{"disabled": false}, http.StatusOK, nil)
	if err := hostAgent.Poll(context.Background()); err != nil {
		t.Fatalf("agent poll after re-enable: %v", err)
	}
	if _, err := os.Stat(policyFile); err != nil {
		t.Fatalf("agent did not recreate policy after re-enable: %v", err)
	}

	integrationRequest(t, backend.Client(), http.MethodPost, backend.URL+"/v1/admin/machines/"+created.Machine.ID+"/rotate-token", adminLogin.Token, nil, http.StatusOK, nil)
	if err := hostAgent.Poll(context.Background()); err == nil {
		t.Fatal("agent poll with rotated host token unexpectedly succeeded")
	}
	if _, err := os.Stat(policyFile); !os.IsNotExist(err) {
		t.Fatalf("rotated host token did not fail closed; policy stat error = %v", err)
	}
}
