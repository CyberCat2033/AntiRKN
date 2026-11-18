// Package probe tests one explicit outbound without applying a client config.
package probe

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"golang.org/x/net/dns/dnsmessage"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	mdns "github.com/metacubex/mihomo/dns"
)

type Request struct {
	Mode string `json:"mode"`
	YAML string `json:"yaml"`
	UDP  bool   `json:"udp"`
	// Interface is the device's physical interface while its VPN is on. Every
	// outbound socket and DNS query of this worker then bypasses that VPN, so
	// the result describes the device's own network.
	Interface string `json:"interface,omitempty"`
}
type Result struct {
	Status       string `json:"status"`
	Code         string `json:"code"`
	Hash         string `json:"hash"`
	TCP          bool   `json:"tcp"`
	UDP          bool   `json:"udp"`
	UDPTested    bool   `json:"udpTested"`
	Milliseconds int64  `json:"milliseconds"`
	Version      string `json:"version"`
	Revision     string `json:"revision"`
	Failure      string `json:"failure,omitempty"`
	// Endpoint is a plain TCP check of the server address after a failed
	// connection: reachable, refused, timeout, unreachable or unresolved.
	Endpoint string `json:"endpoint,omitempty"`
}

var interfaceName = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,15}$`)

// DirectNameservers resolve proxy server names outside the device VPN.
var DirectNameservers = []string{"1.1.1.1:53", "8.8.8.8:53", "9.9.9.9:53"}

// UseInterface binds all dials and DNS of this process to one interface.
func UseInterface(name string) bool {
	if !interfaceName.MatchString(name) {
		return false
	}
	dialer.DefaultInterface.Store(name)
	servers := make([]mdns.NameServer, 0, len(DirectNameservers))
	for _, address := range DirectNameservers {
		servers = append(servers, mdns.NameServer{Net: "udp", Addr: address})
	}
	resolvers := mdns.NewResolver(mdns.Config{Main: servers, Default: servers})
	resolver.DefaultResolver = resolvers.Resolver
	resolver.ProxyServerHostResolver = resolvers.Resolver
	resolver.DirectHostResolver = resolvers.Resolver
	return true
}

type Targets struct {
	HTTPS   []string
	DNS     []netip.AddrPort
	RootCAs *x509.CertPool
}

var PublicTargets = Targets{HTTPS: []string{"https://1.1.1.1/cdn-cgi/trace", "https://www.gstatic.com/generate_204"}, DNS: []netip.AddrPort{netip.MustParseAddrPort("1.1.1.1:53"), netip.MustParseAddrPort("8.8.8.8:53")}}

// Execute permits only adapters used by AntiRKN, never groups or DIRECT fallback.
func Execute(ctx context.Context, request Request, targets Targets) (result Result) {
	hash := sha256.Sum256([]byte(request.YAML))
	result = Result{Status: "not_tested", Code: "unsupported", Hash: hex.EncodeToString(hash[:])}
	if len(request.YAML) > 256*1024 {
		result.Code = "input_limit"
		return
	}
	var proxy C.Proxy
	var fields map[string]any
	if request.Mode != "control" {
		var err error
		fields, err = proxyFields(request.YAML)
		if err != nil {
			result.Code = "invalid_proxy"
			return
		}
		switch fields["type"] {
		case "vless", "wireguard", "trusttunnel":
		default:
			return
		}
		// A standalone test must not silently lose an upstream chain.
		if fields["dialer-proxy"] != nil {
			result.Code = "unsupported_route"
			return
		}
		proxy, err = adapter.ParseProxy(fields)
		if err != nil {
			result.Code = "invalid_proxy"
			return
		}
		defer proxy.Close()
	}
	started := time.Now()
	result.Status = "failed"
	result.Code = "connection_failed"
	for _, target := range targets.HTTPS {
		if err := https(ctx, proxy, target, targets.RootCAs); err == nil {
			result.TCP = true
			break
		} else {
			result.Failure = failureCode(err)
		}
	}
	result.Milliseconds = time.Since(started).Milliseconds()
	if !result.TCP && proxy != nil && ctx.Err() == nil {
		// Separates "this network does not reach the server address" from a
		// protocol or settings failure; the UDP check cannot add to a failure.
		result.Endpoint = endpoint(ctx, fields)
		if ctx.Err() == nil {
			return
		}
	}
	if request.UDP && (proxy == nil || proxy.SupportUDP()) {
		result.UDPTested = true
		for _, target := range targets.DNS {
			if err := dns(ctx, proxy, target); err == nil {
				result.UDP = true
				break
			} else if result.TCP {
				result.Failure = "udp"
			}
		}
	}
	if result.TCP && (!request.UDP || result.UDP) {
		result.Status = "success"
		result.Code = "connected"
	}
	if request.UDP && !result.UDPTested {
		result.Status = "not_tested"
		result.Code = "udp_unsupported"
	}
	if ctx.Err() != nil {
		result.Status = "not_tested"
		result.Code = "timeout"
	}
	return
}

func failureCode(err error) string {
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "reality authentication"):
		return "reality_auth"
	case strings.Contains(text, "xhttp") || strings.Contains(text, "packet-up") || strings.Contains(text, "stream-up"):
		return "xhttp"
	case strings.Contains(text, "failed to verify certificate") || strings.Contains(text, "certificate signed by unknown") || strings.Contains(text, "certificate is valid for"):
		return "certificate"
	case strings.Contains(text, "first record does not look like"):
		return "tls_record"
	case strings.Contains(text, "remote error: tls"):
		return "tls_remote"
	case strings.Contains(text, "unexpected eof") || strings.HasSuffix(text, ": eof") || text == "eof":
		return "eof"
	case strings.Contains(text, "certificate") || strings.Contains(text, "tls") || strings.Contains(text, "handshake"):
		return "tls"
	case strings.Contains(text, "deadline") || strings.Contains(text, "timeout") || strings.Contains(text, "context canceled"):
		return "timeout"
	case strings.Contains(text, "refused") || strings.Contains(text, "unreachable") || strings.Contains(text, "no route"):
		return "dial"
	case strings.Contains(text, "vless") || strings.Contains(text, "response version"):
		return "vless"
	default:
		return "transport"
	}
}

// Mihomo's weak decoder converts float64 to exponent strings. XHTTP ranges
// accept decimal integers, so retain integer types across our JSON boundary.
func proxyFields(source string) (map[string]any, error) {
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	var fields map[string]any
	if err := decoder.Decode(&fields); err != nil {
		return nil, err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("trailing input")
	}
	var numbers func(any) (any, error)
	numbers = func(value any) (any, error) {
		switch value := value.(type) {
		case json.Number:
			if integer, err := value.Int64(); err == nil {
				return integer, nil
			}
			return value.Float64()
		case map[string]any:
			for key, item := range value {
				converted, err := numbers(item)
				if err != nil {
					return nil, err
				}
				value[key] = converted
			}
		case []any:
			for index, item := range value {
				converted, err := numbers(item)
				if err != nil {
					return nil, err
				}
				value[index] = converted
			}
		}
		return value, nil
	}
	_, err := numbers(fields)
	return fields, err
}

func https(parent context.Context, proxy C.Proxy, target string, roots *x509.CertPool) error {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	u, err := url.Parse(target)
	if err != nil || u.Scheme != "https" || u.User != nil {
		return errors.New("target")
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	metadata := &C.Metadata{NetWork: C.TCP}
	if err := metadata.SetRemoteAddress(net.JoinHostPort(u.Hostname(), port)); err != nil {
		return err
	}
	var connection net.Conn
	if proxy == nil {
		connection, err = dialer.DialContext(ctx, "tcp4", metadata.RemoteAddress())
	} else {
		connection, err = proxy.DialContext(ctx, metadata)
	}
	if err != nil {
		return err
	}
	defer connection.Close()
	// The adapter owns streams for the entire request, so its context must not be
	// the short-lived internal dial context of net/http (also Mihomo URLTest's model).
	transport := &http.Transport{DisableKeepAlives: true, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
		DialContext: func(context.Context, string, string) (net.Conn, error) { return connection, nil }}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "AntiRKN connectivity check")
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent && !(u.Path == "/cdn-cgi/trace" && response.StatusCode == http.StatusOK) {
		return errors.New("response")
	}
	_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	return err
}

func dns(parent context.Context, proxy C.Proxy, target netip.AddrPort) error {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	metadata := &C.Metadata{DstIP: target.Addr(), DstPort: target.Port(), NetWork: C.UDP}
	var connection net.PacketConn
	if proxy == nil {
		var err error
		connection, err = dialer.ListenPacket(ctx, "udp", ":0", target)
		if err != nil {
			return err
		}
	} else {
		pc, err := proxy.ListenPacketContext(ctx, metadata)
		if err != nil {
			return err
		}
		connection = pc
	}
	defer connection.Close()
	deadline, _ := ctx.Deadline()
	if err := connection.SetDeadline(deadline); err != nil {
		return err
	}
	// An unpredictable DNS transaction ID and fixed question validate a UDP reply.
	query := []byte{0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}
	if _, err := rand.Read(query[:2]); err != nil {
		return err
	}
	if _, err := connection.WriteTo(query, net.UDPAddrFromAddrPort(target)); err != nil {
		return err
	}
	response := make([]byte, 4096)
	n, source, err := connection.ReadFrom(response)
	if err != nil {
		return err
	}
	var answer dnsmessage.Message
	if answer.Unpack(response[:n]) != nil || answer.ID != uint16(query[0])<<8|uint16(query[1]) || !answer.Response || answer.RCode != dnsmessage.RCodeSuccess || len(answer.Questions) != 1 || len(answer.Answers) == 0 || source.String() != target.String() {
		return errors.New("udp_response")
	}
	question := answer.Questions[0]
	if question.Name.String() != "example.com." || question.Type != dnsmessage.TypeA || question.Class != dnsmessage.ClassINET {
		return errors.New("udp_question")
	}
	return nil
}

// endpoint dials the server address itself (TCP port of the proxy; 443 for
// UDP-only WireGuard, an IP-level hint) through the same interface and DNS.
func endpoint(parent context.Context, fields map[string]any) string {
	host, _ := fields["server"].(string)
	port := 443
	if fields["type"] != "wireguard" {
		switch value := fields["port"].(type) {
		case int64:
			port = int(value)
		case float64:
			port = int(value)
		default:
			return ""
		}
	}
	if host == "" || port < 1 || port > 65535 {
		return ""
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	ips, err := resolver.LookupIPv4WithResolver(ctx, host, resolver.ProxyServerHostResolver)
	if err != nil || len(ips) == 0 {
		return "unresolved"
	}
	connection, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort(ips[0].String(), strconv.Itoa(port)))
	if err == nil {
		connection.Close()
		return "reachable"
	}
	text := strings.ToLower(err.Error())
	switch {
	case strings.Contains(text, "refused"):
		return "refused"
	case ctx.Err() != nil || strings.Contains(text, "timeout") || strings.Contains(text, "deadline"):
		return "timeout"
	default:
		return "unreachable"
	}
}
