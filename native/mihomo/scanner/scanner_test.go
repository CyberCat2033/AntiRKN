package scanner

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

type authority struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pool *x509.CertPool
}

func newAuthority(t *testing.T) authority {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test Root", Organization: []string{"AntiRKN Test CA"}},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return authority{cert, key, pool}
}

func (a authority) leaf(t *testing.T, names ...string) tls.Certificate {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: names[0]}, DNSNames: names,
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(12 * time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, a.cert, &key.PublicKey, a.key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// serve accepts connections on loopback and hands each to handle.
func serve(t *testing.T, handle func(net.Conn)) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handle(conn)
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func tlsServer(t *testing.T, config *tls.Config) int {
	return serve(t, func(conn net.Conn) {
		server := tls.Server(conn, config)
		_ = server.SetDeadline(time.Now().Add(5 * time.Second))
		_ = server.Handshake()
		buf := make([]byte, 1)
		_, _ = server.Read(buf)
		server.Close()
	})
}

func testConfig(a authority, dns map[string]string) Config {
	var dialer net.Dialer
	return Config{Roots: a.pool, AllowPrivate: true, Dial: dialer.DialContext, Now: time.Now,
		Lookup: func(ctx context.Context, host string, ipv6 bool) ([]netip.Addr, error) {
			if ip, ok := dns[host]; ok {
				return []netip.Addr{netip.MustParseAddr(ip)}, nil
			}
			return nil, errors.New("nxdomain")
		}}
}

func request(targets ...Target) Request {
	return Request{Mode: Mode, Targets: targets, Concurrency: 4, ConnectMs: 1000, HandshakeMs: 1500, Resolve: true}
}

func one(t *testing.T, config Config, target Target) Probe {
	t.Helper()
	result := Execute(context.Background(), request(target), config)
	if result.Status != "ok" || result.Code != "scanned" || len(result.Probes) != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	return result.Probes[0]
}

func TestObservesModernTarget(t *testing.T) {
	a := newAuthority(t)
	port := tlsServer(t, &tls.Config{Certificates: []tls.Certificate{a.leaf(t, "site.example.test", "www.site.example.test")}, MinVersion: tls.VersionTLS13, NextProtos: []string{"h2", "http/1.1"}})
	p := one(t, testConfig(a, map[string]string{"site.example.test": "127.0.0.1"}), Target{IP: "127.0.0.1", Port: port, SNI: "site.example.test"})
	if p.Reach != "ok" || p.TLS != "ok" || p.Version != "1.3" || p.ALPN != "h2" || p.Group != "X25519MLKEM768" || p.DNS != "match" {
		t.Fatalf("probe: %+v", p)
	}
	c := p.Certificate
	if c == nil || c.Verify != "valid" || c.NamesTotal != 2 || c.Names[1] != "www.site.example.test" || c.Issuer != "AntiRKN Test CA" || c.CommonName != "site.example.test" || c.NotAfter <= c.NotBefore {
		t.Fatalf("certificate: %+v", c)
	}
}

func TestObservesLegacyTarget(t *testing.T) {
	a := newAuthority(t)
	port := tlsServer(t, &tls.Config{Certificates: []tls.Certificate{a.leaf(t, "old.example.test")}, MaxVersion: tls.VersionTLS12, CurvePreferences: []tls.CurveID{tls.X25519}, NextProtos: []string{"http/1.1"}})
	p := one(t, testConfig(a, map[string]string{"old.example.test": "192.0.2.10"}), Target{IP: "127.0.0.1", Port: port, SNI: "old.example.test"})
	if p.TLS != "ok" || p.Version != "1.2" || p.ALPN != "http/1.1" || p.Group != "X25519" || p.DNS != "mismatch" {
		t.Fatalf("probe: %+v", p)
	}
}

func TestCertificateStatuses(t *testing.T) {
	a := newAuthority(t)
	port := tlsServer(t, &tls.Config{Certificates: []tls.Certificate{a.leaf(t, "site.example.test")}})
	config := testConfig(a, nil)
	cases := []struct {
		name   string
		sni    string
		config func(Config) Config
		verify string
	}{
		{"matching name", "site.example.test", nil, "valid"},
		{"other name", "other.example.test", nil, "name_mismatch"},
		{"no SNI checks the chain only", "", nil, "chain_only"},
		{"unknown root", "site.example.test", func(c Config) Config { c.Roots = x509.NewCertPool(); return c }, "untrusted"},
		{"outside validity", "site.example.test", func(c Config) Config {
			c.Now = func() time.Time { return time.Now().Add(48 * time.Hour) }
			return c
		}, "expired"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := config
			if tc.config != nil {
				c = tc.config(c)
			}
			p := one(t, c, Target{IP: "127.0.0.1", Port: port, SNI: tc.sni})
			if p.Certificate == nil || p.Certificate.Verify != tc.verify {
				t.Fatalf("probe: %+v", p)
			}
			if tc.sni == "" && p.DNS != "" || tc.sni != "" && p.DNS != "unresolved" {
				t.Fatalf("dns: %q", p.DNS)
			}
		})
	}
}

func TestNamesAreBoundedAndWildcardsKept(t *testing.T) {
	a := newAuthority(t)
	names := []string{"*.wild.example.test", "WILD.example.test", "wild.example.test", "bad_name.example.test"}
	for i := 0; i < 10; i++ {
		names = append(names, fmt.Sprintf("n%d.example.test", i))
	}
	port := tlsServer(t, &tls.Config{Certificates: []tls.Certificate{a.leaf(t, names...)}})
	p := one(t, testConfig(a, nil), Target{IP: "127.0.0.1", Port: port, SNI: "a.wild.example.test"})
	c := p.Certificate
	if c == nil || c.Verify != "valid" || len(c.Names) != MaxNames || c.NamesTotal != 12 || c.Names[0] != "*.wild.example.test" || c.Names[1] != "wild.example.test" {
		t.Fatalf("certificate: %+v", c)
	}
}

func TestConnectionFailures(t *testing.T) {
	a := newAuthority(t)
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	refused := closed.Addr().(*net.TCPAddr).Port
	closed.Close()
	silent := serve(t, func(conn net.Conn) { time.Sleep(3 * time.Second); conn.Close() })
	reset := serve(t, func(conn net.Conn) { conn.Close() })
	alert := tlsServer(t, &tls.Config{GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) { return nil, errors.New("refuse") }})
	config := testConfig(a, nil)
	for _, tc := range []struct {
		port       int
		reach, tls string
	}{{refused, "refused", ""}, {silent, "ok", "timeout"}, {reset, "ok", "reset"}, {alert, "ok", "alert"}} {
		started := time.Now()
		p := one(t, config, Target{IP: "127.0.0.1", Port: tc.port, SNI: "site.example.test"})
		if p.Reach != tc.reach || p.TLS != tc.tls || p.Certificate != nil || p.Version != "" {
			t.Fatalf("port %d: %+v", tc.port, p)
		}
		if elapsed := time.Since(started); elapsed > 2600*time.Millisecond {
			t.Fatalf("port %d exceeded its budget: %v", tc.port, elapsed)
		}
	}
	dialTimeout := config
	dialTimeout.Dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if p := one(t, dialTimeout, Target{IP: "127.0.0.1", Port: 443}); p.Reach != "timeout" || p.TLS != "" {
		t.Fatalf("dial timeout: %+v", p)
	}
}

func TestConcurrencyIsBoundedAndOrderKept(t *testing.T) {
	var active, peak atomic.Int32
	config := Config{AllowPrivate: true, Now: time.Now, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		n := active.Add(1)
		for {
			old := peak.Load()
			if n <= old || peak.CompareAndSwap(old, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		active.Add(-1)
		return nil, errors.New("connection refused")
	}}
	req := request()
	for i := 1; i <= MaxTargets; i++ {
		req.Targets = append(req.Targets, Target{IP: "127.0.0." + strconv.Itoa(i), Port: 443})
	}
	req.Concurrency, req.ConnectMs, req.HandshakeMs = 3, 300, 500
	result := Execute(context.Background(), req, config)
	if result.Status != "ok" || len(result.Probes) != MaxTargets || peak.Load() > 3 || peak.Load() < 2 {
		t.Fatalf("peak %d: %+v", peak.Load(), result)
	}
	for i, p := range result.Probes {
		if p.Target != req.Targets[i] || p.Reach != "refused" {
			t.Fatalf("probe %d: %+v", i, p)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if p := Execute(ctx, request(Target{IP: "127.0.0.1", Port: 443}), config).Probes[0]; p.Reach != "skipped" {
		t.Fatalf("cancelled: %+v", p)
	}
}

func TestRejectsUnboundedOrUnsafeRequests(t *testing.T) {
	public := Config{Now: time.Now, Dial: func(context.Context, string, string) (net.Conn, error) {
		t.Fatal("must not dial")
		return nil, nil
	}}
	ok := Target{IP: "8.8.8.8", Port: 443, SNI: "dns.google"}
	many := request()
	for i := 0; i <= MaxTargets; i++ {
		many.Targets = append(many.Targets, Target{IP: "8.8.4." + strconv.Itoa(i+1), Port: 443})
	}
	slow := request()
	for i := 0; i < MaxTargets; i++ {
		slow.Targets = append(slow.Targets, Target{IP: "8.8.4." + strconv.Itoa(i+1), Port: 443})
	}
	slow.Concurrency, slow.ConnectMs, slow.HandshakeMs = 2, 1500, 3000
	mutate := func(f func(*Request)) Request { r := request(ok); f(&r); return r }
	for name, tc := range map[string]struct {
		req  Request
		code string
	}{
		"mode":              {mutate(func(r *Request) { r.Mode = "probe" }), "invalid_request"},
		"empty":             {request(), "invalid_request"},
		"too many":          {many, "invalid_request"},
		"over budget":       {slow, "input_limit"},
		"concurrency":       {mutate(func(r *Request) { r.Concurrency = MaxConcurrency + 1 }), "invalid_request"},
		"connect timeout":   {mutate(func(r *Request) { r.ConnectMs = 100 }), "invalid_request"},
		"handshake timeout": {mutate(func(r *Request) { r.HandshakeMs = 9000 }), "invalid_request"},
		"duplicate":         {request(ok, ok), "invalid_request"},
		"port":              {request(Target{IP: "8.8.8.8", Port: 0}), "invalid_request"},
		"non-canonical ip":  {request(Target{IP: "::ffff:8.8.8.8", Port: 443}), "invalid_request"},
		"hostname as ip":    {request(Target{IP: "dns.google", Port: 443}), "invalid_request"},
		"wildcard sni":      {request(Target{IP: "8.8.8.8", Port: 443, SNI: "*.google"}), "invalid_request"},
		"upper-case sni":    {request(Target{IP: "8.8.8.8", Port: 443, SNI: "DNS.google"}), "invalid_request"},
		"ip sni":            {request(Target{IP: "8.8.8.8", Port: 443, SNI: "8.8.8.8"}), "invalid_request"},
		"loopback":          {request(Target{IP: "127.0.0.1", Port: 443}), "private_target"},
		"private":           {request(Target{IP: "10.1.2.3", Port: 443}), "private_target"},
		"cgnat":             {request(Target{IP: "100.64.1.1", Port: 443}), "private_target"},
		"documentation":     {request(Target{IP: "203.0.113.7", Port: 443}), "private_target"},
		"ipv6 link-local":   {request(Target{IP: "fe80::1", Port: 443}), "private_target"},
		"ipv6 ula":          {request(Target{IP: "fd00::1", Port: 443}), "private_target"},
	} {
		result := Execute(context.Background(), tc.req, public)
		if result.Status != "not_tested" || result.Code != tc.code || result.Probes == nil || len(result.Probes) != 0 {
			t.Errorf("%s: %+v", name, result)
		}
	}
}
