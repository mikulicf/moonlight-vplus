package agent

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	maxConfigBytes      = 64 * 1024
	maxCertificateBytes = 64 * 1024
	requestTimeout      = 5 * time.Second
)

type Config struct {
	BackendURL            string `json:"backend_url"`
	HostToken             string `json:"host_token"`
	PolicyFile            string `json:"policy_file"`
	ServerCertificateFile string `json:"server_certificate_file"`
	HTTPPort              int    `json:"http_port"`
	CAFile                string `json:"ca_file,omitempty"`
}

func LoadConfig(path string) (Config, error) {
	data, err := readBoundedFile(path, maxConfigBytes)
	if err != nil {
		return Config{}, fmt.Errorf("open config: %w", err)
	}

	var cfg Config
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if err := dec.Decode(new(any)); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("decode config: expected one JSON object")
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c *Config) Validate() error {
	origin, err := validateBackendOrigin(c.BackendURL)
	if err != nil {
		return err
	}
	c.BackendURL = origin

	if len(c.HostToken) != 64 {
		return errors.New("host_token must contain exactly 64 hexadecimal characters")
	}
	if _, err := hex.DecodeString(c.HostToken); err != nil {
		return errors.New("host_token must contain exactly 64 hexadecimal characters")
	}
	if strings.TrimSpace(c.PolicyFile) == "" {
		return errors.New("policy_file is required")
	}
	if strings.TrimSpace(c.ServerCertificateFile) == "" {
		return errors.New("server_certificate_file is required")
	}
	if c.HTTPPort < 1 || c.HTTPPort > 65535 {
		return errors.New("http_port must be between 1 and 65535")
	}
	return nil
}

func validateBackendOrigin(raw string) (string, error) {
	if strings.TrimSpace(raw) != raw || raw == "" {
		return "", errors.New("backend_url must be an HTTPS origin")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil ||
		u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" ||
		(u.Path != "" && u.Path != "/") {
		return "", errors.New("backend_url must be an HTTPS origin without a path, credentials, query, or fragment")
	}
	if u.Hostname() == "" {
		return "", errors.New("backend_url must include a host")
	}
	return strings.TrimSuffix(u.String(), "/"), nil
}

func (c Config) serverCertificate() (string, error) {
	raw, err := readBoundedFile(c.ServerCertificateFile, maxCertificateBytes)
	if err != nil {
		return "", fmt.Errorf("read server certificate: %w", err)
	}
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return "", errors.New("server certificate file must contain exactly one PEM certificate")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return "", fmt.Errorf("parse server certificate: %w", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: block.Bytes})), nil
}

func (c Config) backendClient() (*http.Client, error) {
	roots, err := x509.SystemCertPool()
	if err != nil || roots == nil {
		roots = x509.NewCertPool()
	}
	if c.CAFile != "" {
		ca, err := readBoundedFile(c.CAFile, maxCertificateBytes)
		if err != nil {
			return nil, fmt.Errorf("read ca_file: %w", err)
		}
		if !roots.AppendCertsFromPEM(ca) {
			return nil, errors.New("ca_file does not contain a valid PEM certificate")
		}
	}

	transport := &http.Transport{
		Proxy:           nil,
		DialContext:     (&net.Dialer{Timeout: requestTimeout}).DialContext,
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots},
	}
	return &http.Client{
		Transport: transport,
		Timeout:   requestTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}, nil
}

func localClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:       nil,
			DialContext: (&net.Dialer{Timeout: requestTimeout}).DialContext,
		},
		Timeout: requestTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func readBoundedFile(path string, limit int64) ([]byte, error) {
	f, err := os.Open(filepath.Clean(path))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("file exceeds size limit")
	}
	return b, nil
}
