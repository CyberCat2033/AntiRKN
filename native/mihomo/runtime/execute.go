package runtime

import (
	"antirkn.local/mihomo/probe"
	"antirkn.local/mihomo/scanner"
	"antirkn.local/mihomo/validator"
	"context"
	"encoding/json"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
	"io"
	"net"
	"net/netip"
	"os"
	"runtime/debug"
	"time"
)

func Execute(input []byte, directory string) (result any) {
	var request probe.Request
	if len(input) > validator.MaxInput*4 || json.Unmarshal(input, &request) != nil || request.Mode == "" {
		return validator.Validate(input, directory)
	}
	log.SetLevel(log.SILENT)
	logrus.SetOutput(io.Discard)
	debug.SetMemoryLimit(192 * 1024 * 1024)
	result = probe.Result{Status: "not_tested", Code: "core_failure", Version: validator.Version, Revision: validator.Revision}
	defer func() {
		if recover() != nil {
			result = probe.Result{Status: "not_tested", Code: "core_failure", Version: validator.Version, Revision: validator.Revision}
		}
	}()
	if os.MkdirAll(directory, 0700) != nil {
		return
	}
	if request.Mode == scanner.Mode {
		return scan(input)
	}
	if request.Mode != "probe" && request.Mode != "control" {
		return
	}
	if request.Interface != "" && !probe.UseInterface(request.Interface) {
		result = probe.Result{Status: "not_tested", Code: "unsupported_route", Version: validator.Version, Revision: validator.Revision}
		return
	}
	C.SetHomeDir(directory)
	C.Version = validator.Version
	ctx, cancel := context.WithTimeout(context.Background(), 13*time.Second)
	defer cancel()
	value := probe.Execute(ctx, request, probe.PublicTargets)
	value.Version = validator.Version
	value.Revision = validator.Revision
	return value
}

// scan runs one TLS batch; the device interface, if given, bypasses its VPN.
func scan(input []byte) any {
	var request scanner.Request
	if json.Unmarshal(input, &request) != nil {
		request = scanner.Request{}
	}
	result := scanner.Result{Status: "not_tested", Code: "unsupported_route", Probes: []scanner.Probe{}}
	if request.Interface == "" || probe.UseInterface(request.Interface) {
		resolver.DisableIPv6 = false
		ctx, cancel := context.WithTimeout(context.Background(), scanner.Budget+500*time.Millisecond)
		defer cancel()
		result = scanner.Execute(ctx, request, scanner.Config{
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				return dialer.DialContext(ctx, network, address)
			},
			Lookup: func(ctx context.Context, host string, ipv6 bool) ([]netip.Addr, error) {
				if ipv6 {
					return resolver.LookupIPv6WithResolver(ctx, host, resolver.ProxyServerHostResolver)
				}
				return resolver.LookupIPv4WithResolver(ctx, host, resolver.ProxyServerHostResolver)
			},
		})
	}
	result.Version, result.Revision = validator.Version, validator.Revision
	return result
}
