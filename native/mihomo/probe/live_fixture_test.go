package probe

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	"net/http"
	"os"
	"testing"
	"time"
)

// Optional disposable-VM fixture. Input remains outside the repository.
func TestLiveFixture(t *testing.T) {
	path := os.Getenv("ANTIRKN_PROBE_FIXTURE")
	if path == "" {
		t.Skip("isolated VM fixture not requested")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("fixture input")
	}
	var fields map[string]any
	if json.Unmarshal(data, &fields) != nil {
		t.Fatal("fixture input")
	}
	p, err := adapter.ParseProxy(fields)
	if err != nil {
		t.Fatal("fixture adapter")
	}
	defer p.Close()
	for _, secure := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		metadata := &C.Metadata{NetWork: C.TCP}
		address := "10.0.2.2:29880"
		if secure {
			address = "www.gstatic.com:443"
		}
		metadata.SetRemoteAddress(address)
		conn, e := p.DialContext(ctx, metadata)
		if e != nil {
			t.Logf("manual dial secure=%v error %T", secure, e)
			cancel()
			continue
		}
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		var client interface {
			Read([]byte) (int, error)
			Write([]byte) (int, error)
		} = conn
		if secure {
			tlsConn := tls.Client(conn, &tls.Config{ServerName: "www.gstatic.com", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12})
			e = tlsConn.HandshakeContext(ctx)
			t.Logf("TLS 1.2 handshake %v", e)
			client = tlsConn
		}
		if e == nil {
			client.Write([]byte("GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n"))
			reply, e := http.ReadResponse(bufio.NewReader(client), nil)
			if e == nil {
				t.Logf("manual response secure=%v status=%d", secure, reply.StatusCode)
				reply.Body.Close()
			} else {
				t.Logf("manual response %T", e)
			}
		}
		conn.Close()
		cancel()
	}
	for _, target := range PublicTargets.HTTPS {
		if err := https(context.Background(), p, target, nil); err != nil {
			t.Errorf("fixed HTTPS destination: %T: %v", err, err)
		}
	}
}
