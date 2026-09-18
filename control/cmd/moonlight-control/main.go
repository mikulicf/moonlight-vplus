package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/mikulicf/moonlight-vplus/control/internal/server"
	"github.com/mikulicf/moonlight-vplus/control/internal/store"
	"golang.org/x/term"
)

func passwordFromTerminal() (string, error) {
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, "Password (15+ characters): ")
		b, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		return string(b), err
	}
	b, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && len(b) == 0 {
		return "", err
	}
	return strings.TrimSuffix(strings.TrimSuffix(b, "\n"), "\r"), nil
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	if len(os.Args) < 2 {
		return errors.New("usage: moonlight-control serve|create-admin|reset-password [options]")
	}
	f := flag.NewFlagSet(os.Args[1], flag.ContinueOnError)
	dbPath := f.String("db", "data/control.db", "private database path")
	username := f.String("username", "", "account username (local account commands only)")
	listen := f.String("listen", "127.0.0.1:8080", "HTTP listen address")
	publicURL := f.String("public-url", os.Getenv("PUBLIC_URL"), "deployment HTTPS origin; no built-in default")
	certPath := f.String("tls-cert", "", "TLS certificate chain (if serving HTTPS directly)")
	keyPath := f.String("tls-key", "", "TLS private key (if serving HTTPS directly)")
	behindProxy := f.Bool("behind-proxy", false, "permit HTTP on a private container network behind a TLS proxy")
	proxies := f.String("trusted-proxies", "", "comma-separated proxy CIDRs allowed to supply X-Real-IP")
	if err := f.Parse(os.Args[2:]); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if os.Args[1] != "serve" && os.Args[1] != "create-admin" && os.Args[1] != "reset-password" {
		return errors.New("unknown command")
	}
	s, err := store.Open(*dbPath)
	if err != nil {
		return err
	}
	defer s.Close()
	if os.Args[1] != "serve" {
		if *username == "" {
			return errors.New("--username is required")
		}
		password, err := passwordFromTerminal()
		if err != nil {
			return err
		}
		if os.Args[1] == "create-admin" {
			u, err := server.Bootstrap(s, *username, password)
			if err != nil {
				return err
			}
			fmt.Printf("Administrator created: %s\n", u.Username)
			return nil
		}
		if err := server.ResetPassword(s, *username, password); err != nil {
			return err
		}
		fmt.Println("Password reset; existing sessions revoked.")
		return nil
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		return errors.New("listen address must include a port")
	}
	loopback := net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback()
	if (*certPath == "") != (*keyPath == "") {
		return errors.New("both TLS certificate and key must be provided")
	}
	if !loopback && *certPath == "" && !*behindProxy {
		return errors.New("non-loopback plaintext requires --behind-proxy on an isolated private network")
	}
	if (!loopback || *behindProxy) && *publicURL == "" {
		return errors.New("--public-url or PUBLIC_URL is required for deployment")
	}
	config := server.Config{PublicURL: *publicURL}
	for _, cidr := range strings.Split(*proxies, ",") {
		if strings.TrimSpace(cidr) == "" {
			continue
		}
		_, network, err := net.ParseCIDR(strings.TrimSpace(cidr))
		if err != nil {
			return fmt.Errorf("invalid trusted proxy: %w", err)
		}
		config.TrustedProxies = append(config.TrustedProxies, network)
	}
	app, err := server.New(s, config)
	if err != nil {
		return err
	}
	srv := &http.Server{Addr: *listen, Handler: app.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case now := <-ticker.C:
				s.Prune(now)
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("Management service listening on %s", *listen)
	if *certPath != "" {
		err = srv.ListenAndServeTLS(*certPath, *keyPath)
	} else {
		err = srv.ListenAndServe()
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
