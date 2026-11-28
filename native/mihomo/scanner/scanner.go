// Package scanner observes the TLS of explicit REALITY target candidates from
// this device, following the XTLS/RealiTLScanner approach (FR-SNI).
//
// A request is a finite batch of IP:port pairs, each with an optional SNI. The
// handshake accepts any certificate only to observe it; the chain, validity
// and name are then checked separately and reported as their own status. A
// result never claims REALITY works: it is observed TLS, not a proxy test.
package scanner

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	Mode           = "tls_scan"
	MaxTargets     = 16
	MaxConcurrency = 16
	MaxNames       = 8
	// Budget is the worst case a valid batch may need; the worker exits at 15 s.
	Budget = 12 * time.Second
)

type Target struct {
	IP   string `json:"ip"`
	Port int    `json:"port"`
	// SNI is empty for a probe without server name: it shows the default host.
	SNI string `json:"sni"`
}

type Request struct {
	Mode        string   `json:"mode"`
	Targets     []Target `json:"targets"`
	Concurrency int      `json:"concurrency"`
	ConnectMs   int      `json:"connectMs"`
	HandshakeMs int      `json:"handshakeMs"`
	// Resolve compares the SNI's A/AAAA records with the probed IP.
	Resolve   bool   `json:"resolve"`
	Interface string `json:"interface,omitempty"`
}

type Certificate struct {
	Names      []string `json:"names"`
	NamesTotal int      `json:"namesTotal"`
	CommonName string   `json:"commonName"`
	Issuer     string   `json:"issuer"`
	NotBefore  int64    `json:"notBefore"`
	NotAfter   int64    `json:"notAfter"`
	// Verify: valid, chain_only (no SNI to match), expired, name_mismatch, untrusted.
	Verify string `json:"verify"`
}

type Probe struct {
	Target
	// Reach: ok, refused, timeout, unreachable, skipped.
	Reach string `json:"reach"`
	// TLS: ok, timeout, reset, alert, failed; empty when TCP did not connect.
	TLS         string       `json:"tls"`
	TCPMs       int64        `json:"tcpMs"`
	TLSMs       int64        `json:"tlsMs"`
	Version     string       `json:"version"`
	ALPN        string       `json:"alpn"`
	Group       string       `json:"group"`
	Certificate *Certificate `json:"certificate,omitempty"`
	// DNS: match, mismatch, unresolved; empty when not checked.
	DNS string `json:"dns"`
}

type Result struct {
	Status   string  `json:"status"`
	Code     string  `json:"code"`
	Probes   []Probe `json:"probes"`
	Version  string  `json:"version"`
	Revision string  `json:"revision"`
}

// Config holds the network seams; Default uses the platform roots.
type Config struct {
	Roots        *x509.CertPool
	AllowPrivate bool
	Dial         func(ctx context.Context, network, address string) (net.Conn, error)
	Lookup       func(ctx context.Context, host string, ipv6 bool) ([]netip.Addr, error)
	Now          func() time.Time
}

var hostname = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
var wildcard = regexp.MustCompile(`^\*\.([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// Special-purpose ranges that are never a public REALITY target.
var special = func() []netip.Prefix {
	var out []netip.Prefix
	for _, p := range []string{"100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "2001:db8::/32", "64:ff9b::/96", "100::/64"} {
		out = append(out, netip.MustParsePrefix(p))
	}
	return out
}()

func invalid(code string) Result { return Result{Status: "not_tested", Code: code, Probes: []Probe{}} }

// ValidSNI accepts one concrete DNS name: no wildcard, IP literal or upper case.
func ValidSNI(name string) bool {
	if name == "" || len(name) > 253 || !hostname.MatchString(name) {
		return false
	}
	_, err := netip.ParseAddr(name)
	return err != nil
}

func public(ip netip.Addr) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	for _, p := range special {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

func check(request Request, config Config) (Result, bool) {
	n, c := len(request.Targets), request.Concurrency
	if request.Mode != Mode || n == 0 || n > MaxTargets || c < 1 || c > MaxConcurrency ||
		request.ConnectMs < 300 || request.ConnectMs > 3000 || request.HandshakeMs < 500 || request.HandshakeMs > 5000 {
		return invalid("invalid_request"), false
	}
	seen := map[Target]bool{}
	for _, t := range request.Targets {
		ip, err := netip.ParseAddr(t.IP)
		if err != nil || ip.Zone() != "" || ip.Is4In6() || ip.String() != t.IP || t.Port < 1 || t.Port > 65535 ||
			t.SNI != "" && !ValidSNI(t.SNI) || seen[t] {
			return invalid("invalid_request"), false
		}
		if !config.AllowPrivate && !public(ip) {
			return invalid("private_target"), false
		}
		seen[t] = true
	}
	rounds := (n + c - 1) / c
	if time.Duration(rounds*(request.ConnectMs+request.HandshakeMs))*time.Millisecond > Budget {
		return invalid("input_limit"), false
	}
	return Result{}, true
}

// Execute probes every target with bounded concurrency; order is preserved.
func Execute(ctx context.Context, request Request, config Config) Result {
	if result, ok := check(request, config); !ok {
		return result
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	probes := make([]Probe, len(request.Targets))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < request.Concurrency && w < len(request.Targets); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				probes[i] = probe(ctx, request, config, request.Targets[i])
			}
		}()
	}
	for i := range request.Targets {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	return Result{Status: "ok", Code: "scanned", Probes: probes}
}

func probe(ctx context.Context, request Request, config Config, target Target) (p Probe) {
	p = Probe{Target: target}
	if ctx.Err() != nil {
		p.Reach = "skipped"
		return
	}
	connect := time.Duration(request.ConnectMs) * time.Millisecond
	handshake := time.Duration(request.HandshakeMs) * time.Millisecond
	var dns chan string
	if request.Resolve && target.SNI != "" && config.Lookup != nil {
		dns = make(chan string, 1)
		go func() { dns <- resolve(ctx, config, target, connect+handshake) }()
		defer func() { p.DNS = <-dns }()
	}
	dialCtx, cancel := context.WithTimeout(ctx, connect)
	started := time.Now()
	conn, err := config.Dial(dialCtx, "tcp", net.JoinHostPort(target.IP, strconv.Itoa(target.Port)))
	cancel()
	if err != nil {
		p.Reach = dialFailure(err, dialCtx)
		return
	}
	defer conn.Close()
	p.Reach, p.TCPMs = "ok", time.Since(started).Milliseconds()
	shakeCtx, cancelShake := context.WithTimeout(ctx, handshake)
	defer cancelShake()
	_ = conn.SetDeadline(time.Now().Add(handshake))
	client := tls.Client(conn, &tls.Config{
		ServerName: target.SNI,
		// Discovery only: the certificate is verified below and reported separately.
		InsecureSkipVerify: true,
		NextProtos:         []string{"h2", "http/1.1"},
		MinVersion:         tls.VersionTLS12,
	})
	started = time.Now()
	if err := client.HandshakeContext(shakeCtx); err != nil {
		p.TLS = handshakeFailure(err, shakeCtx)
		return
	}
	p.TLS, p.TLSMs = "ok", time.Since(started).Milliseconds()
	state := client.ConnectionState()
	p.Version = version(state.Version)
	if state.NegotiatedProtocol == "h2" || state.NegotiatedProtocol == "http/1.1" {
		p.ALPN = state.NegotiatedProtocol
	}
	p.Group = group(state.CurveID)
	if len(state.PeerCertificates) > 0 {
		p.Certificate = certificate(state.PeerCertificates, target.SNI, config)
	}
	return
}

func resolve(ctx context.Context, config Config, target Target, limit time.Duration) string {
	if limit > 3*time.Second {
		limit = 3 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	ip := netip.MustParseAddr(target.IP)
	addrs, err := config.Lookup(ctx, target.SNI, ip.Is6())
	if err != nil || len(addrs) == 0 {
		return "unresolved"
	}
	for _, a := range addrs {
		if a.Unmap() == ip {
			return "match"
		}
	}
	return "mismatch"
}

func dialFailure(err error, ctx context.Context) string {
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "refused"):
		return "refused"
	case ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) || strings.Contains(text, "timeout"):
		return "timeout"
	default:
		return "unreachable"
	}
}

func handshakeFailure(err error, ctx context.Context) string {
	var op *net.OpError
	if errors.As(err, &op) && op.Op == "remote error" {
		return "alert"
	}
	var timeout interface{ Timeout() bool }
	text := strings.ToLower(err.Error())
	switch {
	case ctx.Err() != nil || errors.As(err, &timeout) && timeout.Timeout():
		return "timeout"
	case strings.Contains(text, "reset") || strings.Contains(text, "eof") || strings.Contains(text, "broken pipe"):
		return "reset"
	default:
		return "failed"
	}
}

func version(v uint16) string {
	switch v {
	case tls.VersionTLS13:
		return "1.3"
	case tls.VersionTLS12:
		return "1.2"
	}
	return "other"
}

func group(id tls.CurveID) string {
	switch id {
	case 0:
		return ""
	case tls.X25519MLKEM768, tls.X25519, tls.CurveP256, tls.CurveP384, tls.CurveP521, tls.SecP256r1MLKEM768, tls.SecP384r1MLKEM1024:
		return id.String()
	}
	return "other"
}

func certificate(chain []*x509.Certificate, sni string, config Config) *Certificate {
	leaf := chain[0]
	out := &Certificate{Names: []string{}, CommonName: text(leaf.Subject.CommonName), NotBefore: leaf.NotBefore.Unix(), NotAfter: leaf.NotAfter.Unix()}
	if len(leaf.Issuer.Organization) > 0 {
		out.Issuer = text(leaf.Issuer.Organization[0])
	} else {
		out.Issuer = text(leaf.Issuer.CommonName)
	}
	seen := map[string]bool{}
	for _, raw := range leaf.DNSNames {
		name := strings.ToLower(strings.TrimSuffix(raw, "."))
		if seen[name] || len(name) > 253 || !hostname.MatchString(name) && !wildcard.MatchString(name) {
			continue
		}
		seen[name] = true
		out.NamesTotal++
		if len(out.Names) < MaxNames {
			out.Names = append(out.Names, name)
		}
	}
	now := config.Now()
	if now.Before(leaf.NotBefore) || now.After(leaf.NotAfter) {
		out.Verify = "expired"
		return out
	}
	intermediates := x509.NewCertPool()
	for _, c := range chain[1:] {
		intermediates.AddCert(c)
	}
	_, err := leaf.Verify(x509.VerifyOptions{Roots: config.Roots, Intermediates: intermediates, CurrentTime: now, DNSName: sni})
	var name x509.HostnameError
	var invalid x509.CertificateInvalidError
	switch {
	case err == nil && sni == "":
		out.Verify = "chain_only"
	case err == nil:
		out.Verify = "valid"
	case errors.As(err, &name):
		out.Verify = "name_mismatch"
	case errors.As(err, &invalid) && invalid.Reason == x509.Expired:
		out.Verify = "expired"
	default:
		out.Verify = "untrusted"
	}
	return out
}

// text keeps a short printable hint; certificate fields are untrusted input.
func text(value string) string {
	var b strings.Builder
	for _, r := range value {
		if r == utf8.RuneError || !unicode.IsPrint(r) {
			continue
		}
		if b.Len()+utf8.RuneLen(r) > 64 {
			break
		}
		b.WriteRune(r)
	}
	return b.String()
}
