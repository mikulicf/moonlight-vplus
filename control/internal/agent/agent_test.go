package agent

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testHostUUID = "host-uuid-for-agent-test"

func TestValidateBackendOrigin(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		value   string
		want    string
		wantErr bool
	}{
		{name: "valid", value: "https://control.example", want: "https://control.example"},
		{name: "trailing slash", value: "https://control.example/", want: "https://control.example"},
		{name: "empty", value: "", wantErr: true},
		{name: "plaintext", value: "http://control.example", wantErr: true},
		{name: "path", value: "https://control.example/api", wantErr: true},
		{name: "credentials", value: "https://user@control.example", wantErr: true},
		{name: "query", value: "https://control.example/?x=1", wantErr: true},
		{name: "fragment", value: "https://control.example/#x", wantErr: true},
		{name: "surrounding whitespace", value: " https://control.example", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := validateBackendOrigin(tt.value)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("validateBackendOrigin(%q) succeeded", tt.value)
				}
				return
			}
			if err != nil {
				t.Fatalf("validateBackendOrigin(%q): %v", tt.value, err)
			}
			if got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestLoadConfigRejectsUnknownFields(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "agent.json")
	data := `{
        "backend_url":"https://control.example",
        "host_token":"` + strings.Repeat("ab", 32) + `",
        "policy_file":"policy.json",
        "server_certificate_file":"server.pem",
        "http_port":47989,
        "unexpected":true
    }`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("LoadConfig error = %v, want unknown field error", err)
	}
}

func TestBackendClientRejectsUntrustedCertificate(t *testing.T) {
	t.Parallel()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	client, err := (Config{}).backendClient()
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseIdleConnections()
	resp, err := client.Get(server.URL)
	if resp != nil {
		resp.Body.Close()
	}
	if err == nil {
		t.Fatal("backend client accepted an untrusted TLS certificate")
	}
}

func TestBackendClientDoesNotFollowRedirects(t *testing.T) {
	t.Parallel()
	var redirectedRequests atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		redirectedRequests.Add(1)
	}))
	defer target.Close()
	backend := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Redirect(w, &http.Request{}, target.URL, http.StatusFound)
	}))
	defer backend.Close()

	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.pem")
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: backend.Certificate().Raw})
	if err := os.WriteFile(caPath, ca, 0600); err != nil {
		t.Fatal(err)
	}
	client, err := (Config{CAFile: caPath}).backendClient()
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseIdleConnections()
	resp, err := client.Get(backend.URL)
	if err != nil {
		t.Fatalf("redirect response: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want 302", resp.StatusCode)
	}
	if redirectedRequests.Load() != 0 {
		t.Fatal("backend client followed a redirect")
	}
}

func TestPollWritesPolicyOverTrustedTLS(t *testing.T) {
	var requests atomic.Int32
	now := time.Now().Unix()
	policy := Policy{
		Protocol:   1,
		MachineID:  "machine-one",
		ServerTime: now,
		ValidUntil: now + 90,
		Leases:     []Lease{},
	}
	agentUnderTest, policyPath := newTestAgent(t, 1, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		assertHeartbeatRequest(t, r)
		writeJSON(t, w, http.StatusOK, policy)
	})

	if err := os.MkdirAll(filepath.Dir(policyPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(policyPath, []byte("old policy"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := agentUnderTest.Poll(context.Background()); err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if requests.Load() != 1 {
		t.Fatalf("backend requests = %d, want 1", requests.Load())
	}

	data, err := os.ReadFile(policyPath)
	if err != nil {
		t.Fatal(err)
	}
	var got Policy
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("written policy is invalid JSON: %v", err)
	}
	if got.MachineID != policy.MachineID || got.ValidUntil != policy.ValidUntil || got.Leases == nil {
		t.Fatalf("written policy = %#v, want %#v", got, policy)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(policyPath)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Fatalf("policy permissions = %o, want 600", info.Mode().Perm())
		}
	}
	temps, err := filepath.Glob(filepath.Join(filepath.Dir(policyPath), ".managed-policy-*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(temps) != 0 {
		t.Fatalf("temporary policy files remain: %v", temps)
	}
}

func TestPollDeletesPolicyOnAuthorizationFailure(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			agentUnderTest, policyPath := newTestAgent(t, 1, func(w http.ResponseWriter, _ *http.Request) {
				writeJSON(t, w, status, map[string]string{"error": "rejected"})
			})
			writeOldPolicy(t, policyPath)
			if err := agentUnderTest.Poll(context.Background()); err == nil {
				t.Fatal("Poll succeeded, want authorization failure")
			}
			if _, err := os.Stat(policyPath); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("policy still exists after status %d: %v", status, err)
			}
		})
	}
}

func TestPollLeavesPolicyOnTransientBackendFailure(t *testing.T) {
	agentUnderTest, policyPath := newTestAgent(t, 1, func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(t, w, http.StatusServiceUnavailable, map[string]string{"error": "try later"})
	})
	writeOldPolicy(t, policyPath)
	if err := agentUnderTest.Poll(context.Background()); err == nil {
		t.Fatal("Poll succeeded, want transient failure")
	}
	data, err := os.ReadFile(policyPath)
	if err != nil {
		t.Fatalf("existing policy was removed: %v", err)
	}
	if string(data) != "old policy" {
		t.Fatalf("existing policy changed to %q", data)
	}
}

func TestPollRefusesHostWithoutManagedProtocol(t *testing.T) {
	var requests atomic.Int32
	agentUnderTest, policyPath := newTestAgent(t, 0, func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	})
	writeOldPolicy(t, policyPath)
	if err := agentUnderTest.Poll(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "ManagedAccessProtocol 1") {
		t.Fatalf("Poll error = %v", err)
	}
	if requests.Load() != 0 {
		t.Fatalf("backend requests = %d, want 0", requests.Load())
	}
	if _, err := os.Stat(policyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("policy still exists: %v", err)
	}
}

func TestPollDeletesPolicyOnInvalidSuccessfulResponse(t *testing.T) {
	agentUnderTest, policyPath := newTestAgent(t, 1, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"protocol":2}`)
	})
	writeOldPolicy(t, policyPath)
	if err := agentUnderTest.Poll(context.Background()); err == nil {
		t.Fatal("Poll succeeded, want invalid policy error")
	}
	if _, err := os.Stat(policyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("policy still exists: %v", err)
	}
}

func TestRunDeletesPolicyOnShutdown(t *testing.T) {
	now := time.Now().Unix()
	agentUnderTest, policyPath := newTestAgent(t, 1, func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(t, w, http.StatusOK, Policy{
			Protocol: 1, MachineID: "machine-one", ServerTime: now,
			ValidUntil: now + 90, Leases: []Lease{},
		})
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- agentUnderTest.Run(ctx) }()

	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(policyPath); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("policy was not written")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(policyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("policy still exists after shutdown: %v", err)
	}
}

func newTestAgent(t *testing.T, protocol int, backendHandler http.HandlerFunc) (*Agent, string) {
	t.Helper()
	local := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/serverinfo" {
			t.Errorf("local request = %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		_, _ = fmt.Fprintf(w,
			`<root status_code="200"><uniqueid>%s</uniqueid><ManagedAccessProtocol>%d</ManagedAccessProtocol></root>`,
			testHostUUID, protocol)
	}))
	t.Cleanup(local.Close)
	parsedLocal, err := url.Parse(local.URL)
	if err != nil {
		t.Fatal(err)
	}
	localHost, localPortRaw, err := net.SplitHostPort(parsedLocal.Host)
	if err != nil {
		t.Fatal(err)
	}
	if localHost != "127.0.0.1" {
		t.Fatalf("test local server is not IPv4 loopback: %s", localHost)
	}
	localPort, err := strconv.Atoi(localPortRaw)
	if err != nil {
		t.Fatal(err)
	}

	backend := httptest.NewTLSServer(backendHandler)
	t.Cleanup(backend.Close)
	certificatePEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: backend.Certificate().Raw,
	})
	dir := t.TempDir()
	caPath := filepath.Join(dir, "backend-ca.pem")
	certificatePath := filepath.Join(dir, "server.pem")
	if err := os.WriteFile(caPath, certificatePEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(certificatePath, certificatePEM, 0644); err != nil {
		t.Fatal(err)
	}
	policyPath := filepath.Join(dir, "private", "policy.json")
	config := Config{
		BackendURL:            backend.URL,
		HostToken:             strings.Repeat("ab", 32),
		PolicyFile:            policyPath,
		ServerCertificateFile: certificatePath,
		HTTPPort:              localPort,
		CAFile:                caPath,
	}
	agentUnderTest, err := New(config, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(agentUnderTest.backendClient.CloseIdleConnections)
	t.Cleanup(agentUnderTest.localClient.CloseIdleConnections)
	return agentUnderTest, policyPath
}

func assertHeartbeatRequest(t *testing.T, r *http.Request) {
	t.Helper()
	if r.Method != http.MethodPost || r.URL.Path != "/v1/host/heartbeat" {
		t.Errorf("heartbeat request = %s %s", r.Method, r.URL.Path)
	}
	if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("ab", 32) {
		t.Error("heartbeat Authorization header is missing or incorrect")
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var request heartbeatRequest
	if err := dec.Decode(&request); err != nil {
		t.Fatalf("decode heartbeat request: %v", err)
	}
	if request.HostUUID != testHostUUID || request.ManagedProtocol != 1 || request.ServerCertificate == "" {
		t.Errorf("heartbeat request = %#v", request)
	}
}

func writeJSON(t *testing.T, w http.ResponseWriter, status int, value any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		t.Errorf("encode response: %v", err)
	}
}

func writeOldPolicy(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("old policy"), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestLeaseCertificateFingerprintValidation(t *testing.T) {
	t.Parallel()
	server := httptest.NewTLSServer(http.NotFoundHandler())
	defer server.Close()
	cert := server.Certificate()
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw})
	fingerprint := x509Fingerprint(cert)
	lease := Lease{
		ID: "lease", Fingerprint: fingerprint, Certificate: string(certificatePEM),
		UserID: "user", Username: "alice", Expires: 110,
	}
	if err := lease.validate(100, 120); err != nil {
		t.Fatalf("valid lease rejected: %v", err)
	}
	lease.Fingerprint = strings.Repeat("00", 32)
	if err := lease.validate(100, 120); err == nil {
		t.Fatal("mismatched fingerprint accepted")
	}
}

func x509Fingerprint(cert *x509.Certificate) string {
	sum := sha256Sum(cert.Raw)
	return fmt.Sprintf("%x", sum)
}

func sha256Sum(data []byte) [32]byte {
	// Kept in a helper so test fixtures clearly use the certificate's DER bytes.
	return sha256.Sum256(data)
}
