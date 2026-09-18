package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	heartbeatInterval = time.Second
	maxResponseBytes  = 512 * 1024
)

type Logger interface {
	Printf(format string, args ...any)
}

type Agent struct {
	config        Config
	backendClient *http.Client
	localClient   *http.Client
	logger        Logger
}

type serverInfo struct {
	StatusCode            string `xml:"status_code,attr"`
	UniqueID              string `xml:"uniqueid"`
	ManagedAccessProtocol int    `xml:"ManagedAccessProtocol"`
}

type heartbeatRequest struct {
	HostUUID          string `json:"host_uuid"`
	ServerCertificate string `json:"server_certificate"`
	ManagedProtocol   int    `json:"managed_protocol"`
}

func New(config Config, logger Logger) (*Agent, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	if _, err := config.serverCertificate(); err != nil {
		return nil, err
	}
	client, err := config.backendClient()
	if err != nil {
		return nil, err
	}
	if logger == nil {
		logger = log.Default()
	}
	return &Agent{
		config:        config,
		backendClient: client,
		localClient:   localClient(),
		logger:        logger,
	}, nil
}

func (a *Agent) Run(ctx context.Context) error {
	defer func() {
		a.backendClient.CloseIdleConnections()
		a.localClient.CloseIdleConnections()
		if err := deletePolicy(a.config.PolicyFile); err != nil {
			a.logger.Printf("delete managed policy during shutdown: %v", err)
		}
	}()

	lastFailure := ""
	poll := func() {
		err := a.Poll(ctx)
		if err == nil {
			if lastFailure != "" {
				a.logger.Printf("managed heartbeat recovered")
				lastFailure = ""
			}
			return
		}
		message := err.Error()
		if message != lastFailure {
			a.logger.Printf("managed heartbeat failed: %v", err)
			lastFailure = message
		}
	}

	poll()
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			poll()
		}
	}
}

func (a *Agent) Poll(ctx context.Context) error {
	info, err := a.fetchServerInfo(ctx)
	if err != nil {
		return err
	}
	if info.ManagedAccessProtocol != 1 {
		if err := deletePolicy(a.config.PolicyFile); err != nil {
			return fmt.Errorf("managed access protocol is not active; delete policy: %w", err)
		}
		return errors.New("local host does not report ManagedAccessProtocol 1")
	}

	certificate, err := a.config.serverCertificate()
	if err != nil {
		_ = deletePolicy(a.config.PolicyFile)
		return err
	}
	payload, err := json.Marshal(heartbeatRequest{
		HostUUID:          info.UniqueID,
		ServerCertificate: certificate,
		ManagedProtocol:   1,
	})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		a.config.BackendURL+"/v1/host/heartbeat", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create heartbeat request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+a.config.HostToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := a.backendClient.Do(req)
	if err != nil {
		return fmt.Errorf("send heartbeat: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		if err := deletePolicy(a.config.PolicyFile); err != nil {
			return fmt.Errorf("heartbeat authorization rejected; delete policy: %w", err)
		}
		return fmt.Errorf("heartbeat authorization rejected with status %d", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK {
		_, _ = readLimited(resp.Body, maxResponseBytes)
		return fmt.Errorf("heartbeat returned status %d", resp.StatusCode)
	}

	policy, err := decodePolicy(resp.Body)
	if err != nil {
		_ = deletePolicy(a.config.PolicyFile)
		return fmt.Errorf("decode heartbeat policy: %w", err)
	}
	if err := policy.validate(); err != nil {
		_ = deletePolicy(a.config.PolicyFile)
		return fmt.Errorf("validate heartbeat policy: %w", err)
	}
	if err := writePolicyAtomic(a.config.PolicyFile, policy); err != nil {
		return fmt.Errorf("write managed policy: %w", err)
	}
	return nil
}

func (a *Agent) fetchServerInfo(ctx context.Context) (serverInfo, error) {
	endpoint := "http://127.0.0.1:" + strconv.Itoa(a.config.HTTPPort) + "/serverinfo"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return serverInfo{}, fmt.Errorf("create local serverinfo request: %w", err)
	}
	resp, err := a.localClient.Do(req)
	if err != nil {
		return serverInfo{}, fmt.Errorf("fetch local serverinfo: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = readLimited(resp.Body, maxResponseBytes)
		return serverInfo{}, fmt.Errorf("local serverinfo returned status %d", resp.StatusCode)
	}

	body, err := readLimited(resp.Body, maxResponseBytes)
	if err != nil {
		return serverInfo{}, fmt.Errorf("read local serverinfo: %w", err)
	}
	var info serverInfo
	if err := xml.Unmarshal(body, &info); err != nil {
		return serverInfo{}, fmt.Errorf("decode local serverinfo: %w", err)
	}
	if info.StatusCode != "" && info.StatusCode != "200" {
		return serverInfo{}, fmt.Errorf("local serverinfo reported status %s", info.StatusCode)
	}
	info.UniqueID = strings.TrimSpace(info.UniqueID)
	if info.UniqueID == "" || len(info.UniqueID) > 128 {
		return serverInfo{}, errors.New("local serverinfo has an invalid uniqueid")
	}
	return info, nil
}

func decodePolicy(r io.Reader) (Policy, error) {
	data, err := readLimited(r, maxResponseBytes)
	if err != nil {
		return Policy{}, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var policy Policy
	if err := dec.Decode(&policy); err != nil {
		return Policy{}, err
	}
	if err := dec.Decode(new(any)); !errors.Is(err, io.EOF) {
		return Policy{}, errors.New("expected one JSON policy object")
	}
	return policy, nil
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("response exceeds size limit")
	}
	return b, nil
}
