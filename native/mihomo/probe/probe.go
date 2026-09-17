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
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
)

type Request struct {
	Mode string `json:"mode"`
	YAML string `json:"yaml"`
	UDP  bool   `json:"udp"`
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
	if request.Mode != "control" {
		var fields map[string]any
		if json.Unmarshal([]byte(request.YAML), &fields) != nil {
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
		var err error
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
		if https(ctx, proxy, target, targets.RootCAs) == nil {
			result.TCP = true
			break
		}
	}
	result.Milliseconds = time.Since(started).Milliseconds()
	if request.UDP && (proxy == nil || proxy.SupportUDP()) {
		result.UDPTested = true
		for _, target := range targets.DNS {
			if dns(ctx, proxy, target) == nil {
				result.UDP = true
				break
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
		connection, err = (&net.Dialer{}).DialContext(ctx, "tcp4", metadata.RemoteAddress())
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
		connection, err = net.ListenPacket("udp", ":0")
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
