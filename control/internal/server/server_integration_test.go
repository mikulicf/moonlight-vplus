package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/auth"
	"github.com/mikulicf/moonlight-vplus/control/internal/store"
)

const (
	adminPassword = "admin integration password"
	userPassword  = "user integration password"
	newPassword   = "replacement user password"
	testOrigin    = "https://control.test"
)

type testEnvironment struct {
	store   *store.Store
	server  *Server
	handler http.Handler
}

type loginResponse struct {
	Token string     `json:"token"`
	User  store.User `json:"user"`
}

type machineResponse struct {
	Machine   store.Machine `json:"machine"`
	HostToken string        `json:"host_token"`
}

type leaseResponse struct {
	LeaseID   string `json:"lease_id"`
	ExpiresAt int64  `json:"expires_at"`
}

func newTestEnvironment(t *testing.T) *testEnvironment {
	t.Helper()
	database, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open in-memory store: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	service, err := New(database, Config{PublicURL: testOrigin})
	if err != nil {
		t.Fatalf("create server: %v", err)
	}
	return &testEnvironment{store: database, server: service, handler: service.Handler()}
}

func request(t *testing.T, env *testEnvironment, method, path, token, body, origin string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	recorder := httptest.NewRecorder()
	env.handler.ServeHTTP(recorder, req)
	return recorder
}

func requireStatus(t *testing.T, response *httptest.ResponseRecorder, want int) {
	t.Helper()
	if response.Code != want {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, want, response.Body.String())
	}
}

func decodeResponse[T any](t *testing.T, response *httptest.ResponseRecorder) T {
	t.Helper()
	var result T
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode response %q: %v", response.Body.String(), err)
	}
	return result
}

func login(t *testing.T, env *testEnvironment, username, password string, want int) loginResponse {
	t.Helper()
	body, err := json.Marshal(map[string]string{"username": username, "password": password})
	if err != nil {
		t.Fatal(err)
	}
	response := request(t, env, http.MethodPost, "/v1/login", "", string(body), testOrigin)
	requireStatus(t, response, want)
	if want != http.StatusOK {
		return loginResponse{}
	}
	return decodeResponse[loginResponse](t, response)
}

func testCertificate(t *testing.T, commonName string) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate certificate key: %v", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		t.Fatalf("generate certificate serial: %v", err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(10 * time.Minute),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw}))
}

func heartbeat(t *testing.T, env *testEnvironment, token, uuid, certificate string, want int) Policy {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"host_uuid":          uuid,
		"server_certificate": certificate,
		"managed_protocol":   1,
	})
	if err != nil {
		t.Fatal(err)
	}
	response := request(t, env, http.MethodPost, "/v1/host/heartbeat", token, string(body), testOrigin)
	requireStatus(t, response, want)
	if want != http.StatusOK {
		return Policy{}
	}
	return decodeResponse[Policy](t, response)
}

func grant(t *testing.T, env *testEnvironment, adminToken, userID, machineID string, method string) {
	t.Helper()
	response := request(t, env, method, "/v1/admin/grants/"+userID+"/"+machineID, adminToken, "", testOrigin)
	requireStatus(t, response, http.StatusOK)
}

func connect(t *testing.T, env *testEnvironment, userToken, machineID, certificate string, want int) leaseResponse {
	t.Helper()
	body, err := json.Marshal(map[string]string{"client_certificate": certificate})
	if err != nil {
		t.Fatal(err)
	}
	response := request(t, env, http.MethodPost, "/v1/machines/"+machineID+"/connections", userToken, string(body), testOrigin)
	requireStatus(t, response, want)
	if want != http.StatusOK {
		return leaseResponse{}
	}
	return decodeResponse[leaseResponse](t, response)
}

func TestServerAuthenticationAuthorizationAndLeaseLifecycle(t *testing.T) {
	env := newTestEnvironment(t)

	response := request(t, env, http.MethodGet, "/v1/admin/users", "", "", testOrigin)
	requireStatus(t, response, http.StatusUnauthorized)
	initialFailure := request(t, env, http.MethodPost, "/v1/login", "", `{"username":"nobody","password":"no account password"}`, testOrigin)
	requireStatus(t, initialFailure, http.StatusUnauthorized)

	admin, err := Bootstrap(env.store, "admin", adminPassword)
	if err != nil {
		t.Fatalf("bootstrap admin: %v", err)
	}
	adminLogin := login(t, env, admin.Username, adminPassword, http.StatusOK)
	if !adminLogin.User.Admin {
		t.Fatal("bootstrapped administrator logged in without admin status")
	}

	createUser := request(t, env, http.MethodPost, "/v1/admin/users", adminLogin.Token,
		`{"username":"viewer","password":"user integration password","admin":false}`, testOrigin)
	requireStatus(t, createUser, http.StatusCreated)
	user := decodeResponse[store.User](t, createUser)

	var storedPassword string
	if err := env.store.DB.QueryRow(`SELECT password_hash FROM users WHERE id=?`, user.ID).Scan(&storedPassword); err != nil {
		t.Fatalf("read stored password hash: %v", err)
	}
	if storedPassword == userPassword || strings.Contains(storedPassword, userPassword) || !auth.VerifyPassword(storedPassword, userPassword) {
		t.Fatal("database did not contain only a usable one-way password hash")
	}

	userLogin := login(t, env, "viewer", userPassword, http.StatusOK)
	knownFailure := request(t, env, http.MethodPost, "/v1/login", "", `{"username":"viewer","password":"wrong password value"}`, testOrigin)
	unknownFailure := request(t, env, http.MethodPost, "/v1/login", "", `{"username":"missing","password":"wrong password value"}`, testOrigin)
	requireStatus(t, knownFailure, http.StatusUnauthorized)
	requireStatus(t, unknownFailure, http.StatusUnauthorized)
	if knownFailure.Body.String() != unknownFailure.Body.String() {
		t.Fatalf("known and unknown user failures differ: %q != %q", knownFailure.Body.String(), unknownFailure.Body.String())
	}

	var storedSessions int
	if err := env.store.DB.QueryRow(`SELECT COUNT(*) FROM sessions WHERE token_hash=?`, userLogin.Token).Scan(&storedSessions); err != nil {
		t.Fatal(err)
	}
	if storedSessions != 0 {
		t.Fatal("raw bearer token was stored in sessions")
	}
	if err := env.store.DB.QueryRow(`SELECT COUNT(*) FROM sessions WHERE token_hash=?`, store.Hash(userLogin.Token)).Scan(&storedSessions); err != nil || storedSessions != 1 {
		t.Fatalf("hashed session token count = %d, err = %v", storedSessions, err)
	}

	requireStatus(t, request(t, env, http.MethodGet, "/v1/admin/users", userLogin.Token, "", testOrigin), http.StatusForbidden)
	usersResponse := request(t, env, http.MethodGet, "/v1/admin/users", adminLogin.Token, "", testOrigin)
	requireStatus(t, usersResponse, http.StatusOK)
	if users := decodeResponse[[]store.User](t, usersResponse); len(users) != 2 {
		t.Fatalf("admin user list length = %d, want 2", len(users))
	}

	createMachine := func(name, address string) machineResponse {
		body := fmt.Sprintf(`{"name":%q,"address":%q,"http_port":47989,"https_port":47984}`, name, address)
		response := request(t, env, http.MethodPost, "/v1/admin/machines", adminLogin.Token, body, testOrigin)
		requireStatus(t, response, http.StatusCreated)
		return decodeResponse[machineResponse](t, response)
	}
	machineA := createMachine("Host A", "host-a.internal")
	machineB := createMachine("Host B", "10.0.0.2")

	var rawHostTokens int
	if err := env.store.DB.QueryRow(`SELECT COUNT(*) FROM machines WHERE token_hash IN (?,?)`, machineA.HostToken, machineB.HostToken).Scan(&rawHostTokens); err != nil {
		t.Fatal(err)
	}
	if rawHostTokens != 0 {
		t.Fatal("raw host credential was stored")
	}

	hostCertificateA := testCertificate(t, "host-a")
	hostCertificateB := testCertificate(t, "host-b")
	invalidHeartbeat := func(body string) {
		t.Helper()
		response := request(t, env, http.MethodPost, "/v1/host/heartbeat", machineA.HostToken, body, testOrigin)
		requireStatus(t, response, http.StatusBadRequest)
	}
	invalidHeartbeat(fmt.Sprintf(`{"host_uuid":"uuid-a","server_certificate":%q,"managed_protocol":2}`, hostCertificateA))
	invalidHeartbeat(fmt.Sprintf(`{"host_uuid":"","server_certificate":%q,"managed_protocol":1}`, hostCertificateA))
	invalidHeartbeat(`{"host_uuid":"uuid-a","server_certificate":"not a certificate","managed_protocol":1}`)
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); policy.MachineID != machineA.Machine.ID {
		t.Fatalf("host A token returned policy for %q", policy.MachineID)
	}
	if policy := heartbeat(t, env, machineB.HostToken, "uuid-b", hostCertificateB, http.StatusOK); policy.MachineID != machineB.Machine.ID {
		t.Fatalf("host B token returned policy for %q", policy.MachineID)
	}

	rotate := request(t, env, http.MethodPost, "/v1/admin/machines/"+machineA.Machine.ID+"/rotate-token", adminLogin.Token, "", testOrigin)
	requireStatus(t, rotate, http.StatusOK)
	rotatedToken := decodeResponse[struct {
		HostToken string `json:"host_token"`
	}](t, rotate).HostToken
	heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusUnauthorized)
	heartbeat(t, env, rotatedToken, "uuid-a", hostCertificateA, http.StatusOK)
	if policy := heartbeat(t, env, machineB.HostToken, "uuid-b", hostCertificateB, http.StatusOK); policy.MachineID != machineB.Machine.ID {
		t.Fatal("rotating host A changed host B authentication")
	}
	machineA.HostToken = rotatedToken

	grant(t, env, adminLogin.Token, user.ID, machineA.Machine.ID, http.MethodPut)
	machines := request(t, env, http.MethodGet, "/v1/machines", userLogin.Token, "", testOrigin)
	requireStatus(t, machines, http.StatusOK)
	if visible := decodeResponse[[]store.Machine](t, machines); len(visible) != 1 || visible[0].ID != machineA.Machine.ID {
		t.Fatalf("visible machines after one grant = %#v", visible)
	}
	grant(t, env, adminLogin.Token, user.ID, machineB.Machine.ID, http.MethodPut)
	machines = request(t, env, http.MethodGet, "/v1/machines", userLogin.Token, "", testOrigin)
	requireStatus(t, machines, http.StatusOK)
	if visible := decodeResponse[[]store.Machine](t, machines); len(visible) != 2 {
		t.Fatalf("visible machine count after two grants = %d", len(visible))
	}
	grant(t, env, adminLogin.Token, user.ID, machineB.Machine.ID, http.MethodDelete)
	connect(t, env, userLogin.Token, machineB.Machine.ID, testCertificate(t, "client-b"), http.StatusNotFound)

	clientCertificate := testCertificate(t, "client-a")
	lease := connect(t, env, userLogin.Token, machineA.Machine.ID, clientCertificate, http.StatusOK)
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 1 || policy.Leases[0].ID != lease.LeaseID {
		t.Fatalf("policy leases after connect = %#v", policy.Leases)
	}

	if _, err := env.store.DB.Exec(`DELETE FROM grants WHERE user_id=? AND machine_id=?`, user.ID, machineA.Machine.ID); err != nil {
		t.Fatal(err)
	}
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 0 {
		t.Fatal("policy included a lease without a current grant")
	}
	if _, err := env.store.DB.Exec(`INSERT INTO grants(user_id,machine_id) VALUES(?,?)`, user.ID, machineA.Machine.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := env.store.DB.Exec(`UPDATE users SET disabled=1 WHERE id=?`, user.ID); err != nil {
		t.Fatal(err)
	}
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 0 {
		t.Fatal("policy included a lease for a disabled user")
	}
	if _, err := env.store.DB.Exec(`UPDATE users SET disabled=0 WHERE id=?`, user.ID); err != nil {
		t.Fatal(err)
	}

	renew := request(t, env, http.MethodPost, "/v1/connections/"+lease.LeaseID+"/renew", userLogin.Token, "", testOrigin)
	requireStatus(t, renew, http.StatusOK)
	release := request(t, env, http.MethodDelete, "/v1/connections/"+lease.LeaseID, userLogin.Token, "", testOrigin)
	requireStatus(t, release, http.StatusOK)
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 0 {
		t.Fatal("released lease remained in host policy")
	}

	lease = connect(t, env, userLogin.Token, machineA.Machine.ID, clientCertificate, http.StatusOK)
	grant(t, env, adminLogin.Token, user.ID, machineA.Machine.ID, http.MethodDelete)
	requireStatus(t, request(t, env, http.MethodPost, "/v1/connections/"+lease.LeaseID+"/renew", userLogin.Token, "", testOrigin), http.StatusForbidden)
	grant(t, env, adminLogin.Token, user.ID, machineA.Machine.ID, http.MethodPut)
	lease = connect(t, env, userLogin.Token, machineA.Machine.ID, clientCertificate, http.StatusOK)
	requireStatus(t, request(t, env, http.MethodPost, "/v1/logout", userLogin.Token, "", testOrigin), http.StatusOK)
	requireStatus(t, request(t, env, http.MethodPost, "/v1/connections/"+lease.LeaseID+"/renew", userLogin.Token, "", testOrigin), http.StatusUnauthorized)
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 0 {
		t.Fatal("logout did not remove the session's host lease")
	}

	userLogin = login(t, env, "viewer", userPassword, http.StatusOK)
	disable := request(t, env, http.MethodPatch, "/v1/admin/users/"+user.ID, adminLogin.Token, `{"disabled":true}`, testOrigin)
	requireStatus(t, disable, http.StatusOK)
	requireStatus(t, request(t, env, http.MethodGet, "/v1/machines", userLogin.Token, "", testOrigin), http.StatusUnauthorized)
	login(t, env, "viewer", userPassword, http.StatusUnauthorized)
	requireStatus(t, request(t, env, http.MethodPatch, "/v1/admin/users/"+user.ID, adminLogin.Token, `{"disabled":false}`, testOrigin), http.StatusOK)

	userLogin = login(t, env, "viewer", userPassword, http.StatusOK)
	resetBody, err := json.Marshal(map[string]string{"password": newPassword})
	if err != nil {
		t.Fatal(err)
	}
	requireStatus(t, request(t, env, http.MethodPatch, "/v1/admin/users/"+user.ID, adminLogin.Token, string(resetBody), testOrigin), http.StatusOK)
	requireStatus(t, request(t, env, http.MethodGet, "/v1/machines", userLogin.Token, "", testOrigin), http.StatusUnauthorized)
	login(t, env, "viewer", userPassword, http.StatusUnauthorized)
	userLogin = login(t, env, "viewer", newPassword, http.StatusOK)

	lease = connect(t, env, userLogin.Token, machineA.Machine.ID, clientCertificate, http.StatusOK)
	if _, err := env.store.DB.Exec(`UPDATE leases SET expires=? WHERE id=?`, time.Now().Add(-time.Minute).Unix(), lease.LeaseID); err != nil {
		t.Fatal(err)
	}
	if policy := heartbeat(t, env, machineA.HostToken, "uuid-a", hostCertificateA, http.StatusOK); len(policy.Leases) != 0 {
		t.Fatal("expired lease remained in host policy")
	}
	env.store.Prune(time.Now())
	var expiredLeaseCount int
	if err := env.store.DB.QueryRow(`SELECT COUNT(*) FROM leases WHERE id=?`, lease.LeaseID).Scan(&expiredLeaseCount); err != nil || expiredLeaseCount != 0 {
		t.Fatalf("expired lease count after prune = %d, err = %v", expiredLeaseCount, err)
	}
}

func TestServerRequestSecurityBoundaries(t *testing.T) {
	env := newTestEnvironment(t)

	crossSite := request(t, env, http.MethodGet, "/healthz", "", "", "https://evil.test")
	requireStatus(t, crossSite, http.StatusForbidden)
	sameOrigin := request(t, env, http.MethodGet, "/healthz", "", "", testOrigin)
	requireStatus(t, sameOrigin, http.StatusOK)
	if sameOrigin.Header().Get("Strict-Transport-Security") == "" {
		t.Fatal("HTTPS deployment response omitted HSTS")
	}
	if sameOrigin.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("response omitted no-store")
	}

	malformed := request(t, env, http.MethodPost, "/v1/login", "", `{"username":`, testOrigin)
	requireStatus(t, malformed, http.StatusBadRequest)
	unknown := request(t, env, http.MethodPost, "/v1/login", "", `{"username":"u","password":"p","admin":true}`, testOrigin)
	requireStatus(t, unknown, http.StatusBadRequest)
	oversized := request(t, env, http.MethodPost, "/v1/login", "", `{"username":"u","password":"`+strings.Repeat("x", 33*1024)+`"}`, testOrigin)
	requireStatus(t, oversized, http.StatusBadRequest)

	wrongType := httptest.NewRequest(http.MethodPost, "/v1/login", strings.NewReader(`{"username":"u","password":"p"}`))
	wrongType.Header.Set("Content-Type", "text/plain")
	wrongType.Header.Set("Origin", testOrigin)
	wrongTypeResponse := httptest.NewRecorder()
	env.handler.ServeHTTP(wrongTypeResponse, wrongType)
	requireStatus(t, wrongTypeResponse, http.StatusUnsupportedMediaType)

	env.server.mu.Lock()
	env.server.attempts["ip:192.0.2.1"] = attempt{count: 20, until: time.Now().Add(time.Minute)}
	env.server.mu.Unlock()
	rateLimitedRequest := httptest.NewRequest(http.MethodPost, "/v1/login", strings.NewReader(`{"username":"u","password":"p"}`))
	rateLimitedRequest.RemoteAddr = "192.0.2.1:1234"
	rateLimitedRequest.Header.Set("Content-Type", "application/json")
	rateLimitedRequest.Header.Set("Origin", testOrigin)
	rateLimited := httptest.NewRecorder()
	env.handler.ServeHTTP(rateLimited, rateLimitedRequest)
	requireStatus(t, rateLimited, http.StatusTooManyRequests)
	if rateLimited.Header().Get("Retry-After") != "60" {
		t.Fatalf("Retry-After = %q, want 60", rateLimited.Header().Get("Retry-After"))
	}
}
