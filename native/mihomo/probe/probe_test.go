package probe

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"golang.org/x/net/dns/dnsmessage"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

func targets(t *testing.T, corrupt bool) (Targets, *atomic.Int32) {
	t.Helper()
	count := &atomic.Int32{}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { count.Add(1); w.WriteHeader(http.StatusNoContent) }))
	t.Cleanup(server.Close)
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { udp.Close() })
	go func() {
		for {
			data := make([]byte, 512)
			n, peer, err := udp.ReadFrom(data)
			if err != nil {
				return
			}
			var question dnsmessage.Message
			if question.Unpack(data[:n]) != nil {
				continue
			}
			question.Response = true
			question.RecursionAvailable = true
			question.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}}}}
			response, _ := question.Pack()
			if corrupt {
				response = response[:12]
			}
			udp.WriteTo(response, peer)
		}
	}()
	return Targets{HTTPS: []string{server.URL}, DNS: []netip.AddrPort{udp.LocalAddr().(*net.UDPAddr).AddrPort()}, RootCAs: roots}, count
}

func TestControlsAndUDPValidation(t *testing.T) {
	for _, corrupt := range []bool{false, true} {
		target, _ := targets(t, corrupt)
		result := Execute(context.Background(), Request{Mode: "control", YAML: "{}", UDP: true}, target)
		if !result.TCP || !result.UDPTested || result.UDP == corrupt {
			t.Fatalf("unexpected result: %#v", result)
		}
		if (result.Status == "success") == corrupt {
			t.Fatal("malformed UDP cannot be a success")
		}
	}
}
func TestEveryAdapterRefusesDirectFallback(t *testing.T) {
	for _, kind := range []string{"vless", "trusttunnel", "wireguard"} {
		t.Run(kind, func(t *testing.T) {
			target, count := targets(t, false)
			fields := map[string]any{"name": "test", "type": kind, "server": "127.0.0.1", "port": 1, "uuid": "00000000-0000-4000-8000-000000000001", "username": "fixture", "password": "fixture-only"}
			if kind == "wireguard" {
				fields["private-key"] = "KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio="
				fields["public-key"] = fields["private-key"]
				fields["ip"] = "10.42.0.2"
			}
			data, _ := json.Marshal(fields)
			ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
			defer cancel()
			result := Execute(ctx, Request{Mode: "probe", YAML: string(data)}, target)
			if result.TCP || result.Status == "success" || count.Load() != 0 {
				t.Fatal("proxy failure reached direct destination")
			}
		})
	}
}
func TestUnsupportedChainAndDirectAreNotTested(t *testing.T) {
	for _, source := range []string{`{"type":"direct","name":"test"}`, `{"type":"vless","dialer-proxy":"parent"}`} {
		result := Execute(context.Background(), Request{Mode: "probe", YAML: source}, PublicTargets)
		if result.Status != "not_tested" {
			t.Fatal("unsupported route")
		}
	}
}
