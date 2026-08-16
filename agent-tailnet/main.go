// agent-tailnet — embedded Tailscale node for Chariot Desktop.
//
// One persistent tsnet node per Mac app installation. The Swift app supervises
// this process and speaks a versioned NDJSON protocol over stdin/stdout; no
// human-readable log output is ever parsed. The node listens on the tailnet
// only (TCP 443) and proxies raw connections to the loopback transport
// service run by the Swift app. It never binds the Mac's LAN or public
// interfaces, and it contains no auth keys or Tailscale credentials of any
// kind: first-run authentication is interactive via a login URL reported to
// the app.
//
// Usage:
//
//	agent-tailnet --state-dir <dir> --hostname agentbox-ab12 \
//	              --upstream 127.0.0.1:8787 [--listen-port 443]
//
// Events (stdout, one JSON object per line, all carrying "v":1):
//
//	{"v":1,"event":"needs_login","auth_url":"https://login.tailscale.com/..."}
//	{"v":1,"event":"connecting"}
//	{"v":1,"event":"ready","dns_name":"...","https":true,"tls_spki_sha256":"...","key_expiry":"..."}
//	{"v":1,"event":"key_expired"}
//	{"v":1,"event":"peer","addr":"...","login":"...","node":"..."}
//	{"v":1,"event":"error","message":"..."}
//	{"v":1,"event":"stopped"}
//
// Commands (stdin, one JSON object per line):
//
//	{"v":1,"cmd":"status"}    re-emit the current state event
//	{"v":1,"cmd":"logout"}    log the node out (Swift side drives reauth)
//	{"v":1,"cmd":"shutdown"}  graceful stop
package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

const protocolVersion = 1

type event struct {
	V             int      `json:"v"`
	Event         string   `json:"event"`
	AuthURL       string   `json:"auth_url,omitempty"`
	DNSName       string   `json:"dns_name,omitempty"`
	Tailnet       string   `json:"tailnet,omitempty"`
	HTTPS         bool     `json:"https,omitempty"`
	TLSSPKISHA256 string   `json:"tls_spki_sha256,omitempty"`
	KeyExpiry     string   `json:"key_expiry,omitempty"`
	Addrs         []string `json:"addrs,omitempty"`
	Addr          string   `json:"addr,omitempty"`
	Login         string   `json:"login,omitempty"`
	Node          string   `json:"node,omitempty"`
	Message       string   `json:"message,omitempty"`
}

type command struct {
	V   int    `json:"v"`
	Cmd string `json:"cmd"`
}

var (
	emitMu    sync.Mutex
	stdout    = bufio.NewWriter(os.Stdout)
	lastReady event
	haveReady bool
)

func emit(e event) {
	e.V = protocolVersion
	emitMu.Lock()
	defer emitMu.Unlock()
	if e.Event == "ready" {
		lastReady = e
		haveReady = true
	}
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	stdout.Write(b)
	stdout.WriteByte('\n')
	stdout.Flush()
}

func emitError(format string, args ...any) {
	emit(event{Event: "error", Message: fmt.Sprintf(format, args...)})
}

func main() {
	stateDir := flag.String("state-dir", "", "tsnet state directory (created 0700; deleting it resets the node identity)")
	hostname := flag.String("hostname", "", "stable tailnet hostname, e.g. agentbox-ab12")
	upstream := flag.String("upstream", "", "loopback address of the Swift transport service, e.g. 127.0.0.1:8787")
	listenPort := flag.Int("listen-port", 443, "tailnet TCP port to listen on")
	flag.Parse()

	if *stateDir == "" || *hostname == "" || *upstream == "" {
		fmt.Fprintln(os.Stderr, "usage: agent-tailnet --state-dir DIR --hostname NAME --upstream HOST:PORT [--listen-port 443]")
		os.Exit(2)
	}
	if host, _, err := net.SplitHostPort(*upstream); err != nil || !net.ParseIP(host).IsLoopback() {
		fmt.Fprintln(os.Stderr, "agent-tailnet: --upstream must be a loopback host:port")
		os.Exit(2)
	}

	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		emitError("state dir: %v", err)
		os.Exit(1)
	}
	// The state directory holds the node's private key; keep it owner-only
	// even if it pre-existed with a looser mode.
	if err := os.Chmod(*stateDir, 0o700); err != nil {
		emitError("state dir chmod: %v", err)
		os.Exit(1)
	}

	s := &tsnet.Server{
		Dir:       *stateDir,
		Hostname:  *hostname,
		Ephemeral: false,
		// All diagnostics flow through the NDJSON protocol; tsnet's logs are
		// discarded rather than parsed.
		Logf:     func(string, ...any) {},
		UserLogf: func(string, ...any) {},
	}
	defer s.Close()

	if err := s.Start(); err != nil {
		emitError("tsnet start: %v", err)
		os.Exit(1)
	}
	lc, err := s.LocalClient()
	if err != nil {
		emitError("local client: %v", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go readCommands(ctx, cancel, lc)
	emit(event{Event: "connecting"})

	// Watch the IPN bus for state transitions and the interactive login URL.
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		emitError("ipn watch: %v", err)
		os.Exit(1)
	}
	defer watcher.Close()

	var (
		listenerOnce sync.Once
		wasRunning   bool
	)
	for {
		n, err := watcher.Next()
		if err != nil {
			if ctx.Err() != nil {
				emit(event{Event: "stopped"})
				return
			}
			emitError("ipn watch: %v", err)
			emit(event{Event: "stopped"})
			return
		}
		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			emit(event{Event: "needs_login", AuthURL: *n.BrowseToURL})
		}
		if n.State == nil {
			continue
		}
		switch *n.State {
		case ipn.NeedsLogin:
			// A node that was running and fell back to NeedsLogin has an
			// expired or revoked key.
			if wasRunning {
				emit(event{Event: "key_expired"})
				wasRunning = false
			}
			// Ask control for an interactive login URL; it arrives as a
			// BrowseToURL notification above. No auth key is ever used.
			if err := lc.StartLoginInteractive(ctx); err != nil {
				emitError("login: %v", err)
			}
		case ipn.Starting:
			emit(event{Event: "connecting"})
		case ipn.Running:
			wasRunning = true
			ready, err := readyEvent(ctx, lc)
			if err != nil {
				emitError("status: %v", err)
				continue
			}
			listenerOnce.Do(func() {
				go serve(ctx, s, lc, *listenPort, *upstream, ready)
				go watchKeyExpiry(ctx, lc)
			})
			emit(ready)
		case ipn.Stopped:
			emit(event{Event: "stopped"})
		}
	}
}

// readyEvent assembles the `ready` event from authenticated Tailscale state.
// The MagicDNS name comes from the backend, never from user input.
func readyEvent(ctx context.Context, lc *local.Client) (event, error) {
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return event{}, err
	}
	e := event{Event: "ready"}
	if st.Self != nil {
		e.DNSName = strings.TrimSuffix(st.Self.DNSName, ".")
		if st.Self.KeyExpiry != nil {
			e.KeyExpiry = st.Self.KeyExpiry.UTC().Format(time.RFC3339)
		}
		for _, ip := range st.Self.TailscaleIPs {
			e.Addrs = append(e.Addrs, ip.String())
		}
	}
	e.Tailnet = strings.TrimSuffix(st.MagicDNSSuffix, ".")
	e.HTTPS = len(st.CertDomains) > 0
	return e, nil
}

// serve owns the tailnet listener. With tailnet HTTPS enabled it uses a
// Tailscale-issued certificate for the MagicDNS name; otherwise it falls back
// to a persistent per-installation self-signed certificate whose SPKI hash the
// app pins through the QR payload.
func serve(ctx context.Context, s *tsnet.Server, lc *local.Client, port int, upstream string, ready event) {
	addr := fmt.Sprintf(":%d", port)
	var (
		ln  net.Listener
		err error
	)
	if ready.HTTPS {
		ln, err = s.ListenTLS("tcp", addr)
	} else {
		var cert tls.Certificate
		var spki string
		cert, spki, err = installationCert(s.Dir, ready.DNSName)
		if err == nil {
			var raw net.Listener
			raw, err = s.Listen("tcp", addr)
			if err == nil {
				ln = tls.NewListener(raw, &tls.Config{
					Certificates: []tls.Certificate{cert},
					MinVersion:   tls.VersionTLS12,
					NextProtos:   []string{"http/1.1"},
				})
				ready.TLSSPKISHA256 = spki
				emit(ready) // re-emit with the pin so the app can build QR payloads
			}
		}
	}
	if err != nil {
		emitError("listen %s: %v", addr, err)
		return
	}
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			emitError("accept: %v", err)
			return
		}
		go proxy(ctx, lc, conn, upstream)
	}
}

// proxy forwards one authenticated tailnet connection to the loopback
// transport service. Peer identity is reported for logging / defense in depth;
// application-level credentials remain the authorization boundary.
func proxy(ctx context.Context, lc *local.Client, conn net.Conn, upstream string) {
	defer conn.Close()
	peer := event{Event: "peer", Addr: conn.RemoteAddr().String()}
	if who, err := lc.WhoIs(ctx, conn.RemoteAddr().String()); err == nil && who != nil {
		if who.UserProfile != nil {
			peer.Login = who.UserProfile.LoginName
		}
		if who.Node != nil {
			peer.Node = strings.TrimSuffix(who.Node.Name, ".")
		}
	}
	emit(peer)

	// Complete the TLS handshake explicitly so failures are reported instead
	// of surfacing as a silent proxy teardown.
	if tlsConn, ok := conn.(*tls.Conn); ok {
		hsCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		err := tlsConn.HandshakeContext(hsCtx)
		cancel()
		if err != nil {
			emitError("tls handshake with %s: %v", conn.RemoteAddr(), err)
			return
		}
	}

	up, err := net.DialTimeout("tcp", upstream, 10*time.Second)
	if err != nil {
		emitError("upstream dial: %v", err)
		return
	}
	defer up.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(up, conn); up.(*net.TCPConn).CloseWrite(); done <- struct{}{} }()
	go func() { io.Copy(conn, up); done <- struct{}{} }()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// watchKeyExpiry emits key_expired when the node key passes its expiry, so the
// app can prompt reauthentication even if control hasn't dropped us yet.
func watchKeyExpiry(ctx context.Context, lc *local.Client) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			st, err := lc.StatusWithoutPeers(ctx)
			if err != nil || st.Self == nil || st.Self.KeyExpiry == nil {
				continue
			}
			if time.Now().After(*st.Self.KeyExpiry) {
				emit(event{Event: "key_expired"})
			}
		}
	}
}

func readCommands(ctx context.Context, cancel context.CancelFunc, lc *local.Client) {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var cmd command
		if err := json.Unmarshal([]byte(line), &cmd); err != nil || cmd.V != protocolVersion {
			emitError("bad command: %s", line)
			continue
		}
		switch cmd.Cmd {
		case "status":
			emitMu.Lock()
			ready, ok := lastReady, haveReady
			emitMu.Unlock()
			if ok {
				emit(ready)
			} else {
				emit(event{Event: "connecting"})
			}
		case "logout":
			if err := lc.Logout(ctx); err != nil {
				emitError("logout: %v", err)
			}
		case "shutdown":
			emit(event{Event: "stopped"})
			cancel()
			return
		default:
			emitError("unknown command: %s", cmd.Cmd)
		}
	}
	// stdin closed: the supervising app is gone; shut down.
	cancel()
}

// installationCert loads or creates the per-installation self-signed TLS
// certificate used when tailnet HTTPS is not enabled. Returns the certificate
// and the base64 SHA-256 of its SubjectPublicKeyInfo for QR pinning.
//
// The certificate's validity must stay well under iOS's hard 825-day limit on
// TLS server certificates — exceeding it makes iOS abort the handshake even
// when the app pins the key, while macOS happens to allow it. Certificates are
// therefore issued for ~13 months and re-issued from the SAME private key
// before expiry, so the pinned public-key hash — and every existing pairing —
// survives renewal.
func installationCert(dir, dnsName string) (tls.Certificate, string, error) {
	certPath := filepath.Join(dir, "chariot-tls-cert.pem")
	keyPath := filepath.Join(dir, "chariot-tls-key.pem")

	// The key persists for the installation's lifetime (it is what phones pin).
	var key *ecdsa.PrivateKey
	if keyPEM, err := os.ReadFile(keyPath); err == nil {
		if block, _ := pem.Decode(keyPEM); block != nil {
			key, _ = x509.ParseECPrivateKey(block.Bytes)
		}
	}
	if key == nil {
		var err error
		key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return tls.Certificate{}, "", err
		}
		keyDER, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			return tls.Certificate{}, "", err
		}
		keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
		if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
			return tls.Certificate{}, "", err
		}
	}

	// Reuse the stored certificate while it matches the key, names this DNS
	// name, respects the iOS validity cap, and is not close to expiring.
	if cert, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		if leaf, err := x509.ParseCertificate(cert.Certificate[0]); err == nil {
			validity := leaf.NotAfter.Sub(leaf.NotBefore)
			usable := leaf.NotAfter.After(time.Now().Add(30*24*time.Hour)) &&
				validity <= 825*24*time.Hour &&
				len(leaf.DNSNames) == 1 && leaf.DNSNames[0] == dnsName
			if pub, ok := leaf.PublicKey.(*ecdsa.PublicKey); usable && ok && pub.Equal(&key.PublicKey) {
				return cert, spkiHash(leaf), nil
			}
		}
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	template := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: dnsName},
		DNSNames:              []string{dnsName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(0, 13, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		return tls.Certificate{}, "", err
	}
	keyPEMBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEMBytes)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	return cert, spkiHash(leaf), nil
}

func spkiHash(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(sum[:])
}
