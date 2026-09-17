// Package validator exposes one bounded, offline config test per worker process.
// Never call executor.ApplyConfig: this package is not a VPN client.
package validator

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	RP "github.com/metacubex/mihomo/rules/provider"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"sort"
	"strings"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	_ "github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
	"gopkg.in/yaml.v3"
)

const Version = "1.19.30"
const Revision = "ac017cdd246ce8bd547653d927e7bf77d7ee73d5"
const MaxInput = 4 * 1024 * 1024

type Request struct {
	YAML      string            `json:"yaml"`
	Resources map[string][]byte `json:"resources,omitempty"`
}
type Result struct {
	Status        string `json:"status"`
	Code          string `json:"code"`
	Version       string `json:"version"`
	Revision      string `json:"revision"`
	Hash          string `json:"hash"`
	ResourcesHash string `json:"resourcesHash"`
	Path          string `json:"path,omitempty"`
}

// Raw upstream errors may contain UUIDs, URLs, keys and whole YAML lines.
// Only our own codes and numeric locations cross the process boundary.
func Validate(input []byte, directory string) (result Result) {
	result = Result{Status: "invalid", Code: "invalid_yaml", Version: Version, Revision: Revision}
	defer func() {
		if recover() != nil {
			result.Status = "incomplete"
			result.Code = "core_failure"
			result.Path = ""
		}
	}()
	debug.SetMemoryLimit(192 * 1024 * 1024)
	log.SetLevel(log.SILENT)
	logrus.SetOutput(io.Discard)
	var request Request
	if len(input) > MaxInput*4 || json.Unmarshal(input, &request) != nil {
		return
	}
	data := []byte(request.YAML)
	hash := sha256.Sum256(data)
	result.Hash = hex.EncodeToString(hash[:])
	if len(data) > MaxInput {
		result.Code = "input_limit"
		return
	}
	var document yaml.Node
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	if decoder.Decode(&document) != nil || len(document.Content) != 1 {
		return
	}
	var extra yaml.Node
	if decoder.Decode(&extra) != io.EOF {
		return
	}
	count := 0
	if !bounded(&document, 0, &count) {
		result.Code = "unsupported_yaml"
		return
	}
	root := document.Content[0]
	if root.Kind != yaml.MappingNode {
		return
	}
	if !filepath.IsAbs(directory) {
		result.Status = "incomplete"
		result.Code = "core_failure"
		return
	}
	if os.MkdirAll(directory, 0700) != nil {
		result.Status = "incomplete"
		result.Code = "core_failure"
		return
	}
	C.SetHomeDir(directory)
	C.SetConfig(filepath.Join(directory, "config.yaml"))
	C.Version = Version
	// All supported outbound constructors use this hook. The Linux/Android
	// worker also installs a process-wide seccomp socket prohibition.
	denied := errors.New("network disabled during validation")
	dialer.DefaultSocketHook = func(string, string, syscall.RawConn) error { return denied }
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(context.Context, string, string) (net.Conn, error) { return nil, denied }}
	http.DefaultTransport = &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) { return nil, denied }}
	if restrictNetwork() != nil {
		result.Status = "incomplete"
		result.Code = "isolation_unavailable"
		return
	}
	// File-backed certificates and runtime-specific adapters must not read the
	// administrator's files or initialize a client while merely checking YAML.
	if path := unavailable(root, ""); path != "" {
		result.Status = "incomplete"
		result.Code = "external_dependency"
		result.Path = path
		return
	}
	parsed, err := config.Parse(data)
	if err != nil {
		text := err.Error()
		if strings.Contains(text, "download") || strings.Contains(text, "no such file") || strings.Contains(text, "operation not permitted") || strings.Contains(text, "network disabled") {
			result.Status = "incomplete"
			result.Code = "external_dependency"
		} else {
			result.Code = "core_rejected"
			for _, item := range []struct{ prefix, path string }{{"proxy[", "proxies"}, {"proxy group[", "proxy-groups"}, {"rules[", "rules"}, {"listener ", "listeners"}} {
				if match := regexp.MustCompile(regexp.QuoteMeta(item.prefix) + `([0-9]{1,5})`).FindStringSubmatch(text); len(match) > 1 {
					result.Path = item.path + "[" + match[1] + "]"
					break
				}
			}
		}
		return
	}
	result.Status = "valid"
	result.Code = "valid"
	digest := sha256.New()
	resourceKeys := make([]string, 0, len(request.Resources))
	total := 0
	for key, data := range request.Resources {
		total += len(data)
		if len(data) > 4*1024*1024 || total > 8*1024*1024 {
			result.Status = "incomplete"
			result.Code = "input_limit"
			return
		}
		resourceKeys = append(resourceKeys, key)
	}
	sort.Strings(resourceKeys)
	for _, key := range resourceKeys {
		h := sha256.Sum256(request.Resources[key])
		digest.Write([]byte(key))
		digest.Write([]byte{0})
		digest.Write(h[:])
	}
	result.ResourcesHash = hex.EncodeToString(digest.Sum(nil))
	// SideUpdate uses the native rule parser without Initial()/polling. Remote
	// bytes were fetched separately; this process has no network capability.
	for i := 0; i < len(root.Content); i += 2 {
		key, value := root.Content[i].Value, root.Content[i+1]
		if key != "proxy-providers" && key != "rule-providers" {
			continue
		}
		if value.Kind != yaml.MappingNode {
			continue
		}
		for j := 0; j < len(value.Content); j += 2 {
			name, mapping := value.Content[j].Value, value.Content[j+1]
			if mapValue(mapping, "type") == "inline" {
				continue
			}
			contents, ok := request.Resources[name]
			if key == "proxy-providers" || !ok {
				result.Status = "incomplete"
				result.Code = "provider_content"
				result.Path = key
				continue
			}
			provider, ok := parsed.RuleProviders[name].(*RP.RuleSetProvider)
			if !ok {
				result.Status = "incomplete"
				result.Code = "provider_content"
				result.Path = key
				continue
			}
			_, _, err := provider.SideUpdate(contents)
			_ = provider.Close()
			if err != nil {
				result.Status = "invalid"
				result.Code = "provider_rejected"
				result.Path = "rule-providers"
				return
			}
		}
	}
	return
}

func bounded(n *yaml.Node, depth int, count *int) bool {
	*count++
	if depth > 40 || *count > 150000 || n.Kind == yaml.AliasNode || (n.Style&yaml.TaggedStyle) != 0 {
		return false
	}
	if n.Kind == yaml.MappingNode {
		seen := map[string]bool{}
		for i := 0; i < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Kind != yaml.ScalarNode || k.Tag != "!!str" || k.Value == "<<" || seen[k.Value] {
				return false
			}
			seen[k.Value] = true
		}
	}
	for _, child := range n.Content {
		if !bounded(child, depth+1, count) {
			return false
		}
	}
	return true
}
func mapValue(n *yaml.Node, key string) string {
	if n.Kind == yaml.MappingNode {
		for i := 0; i < len(n.Content); i += 2 {
			if n.Content[i].Value == key {
				return n.Content[i+1].Value
			}
		}
	}
	return ""
}

func unavailable(n *yaml.Node, path string) string {
	if n.Kind == yaml.MappingNode {
		if path == "proxies[]" || strings.HasSuffix(path, ".payload[]") {
			typ := mapValue(n, "type")
			switch typ {
			case "vless", "wireguard", "trusttunnel", "socks5", "http", "direct", "reject":
			default:
				return "proxies"
			}
		}
		for i := 0; i < len(n.Content); i += 2 {
			k, v := n.Content[i].Value, n.Content[i+1]
			if k == "listeners" && len(v.Content) > 0 {
				return "listeners"
			}
			if (k == "certificate" || k == "private-key" && strings.HasSuffix(path, "tls") || k == "client-auth-cert" || k == "ech-key" || k == "custom-certifactes") && v.Value != "" && !strings.Contains(v.Value, "-----BEGIN ") {
				return "tls"
			}
			if k == "custom-certifactes" && len(v.Content) > 0 {
				return "tls"
			}
			if k == "path" && (strings.HasPrefix(path, "rule-providers") || strings.HasPrefix(path, "proxy-providers")) {
				if !filepath.IsLocal(v.Value) {
					return "providers"
				}
			}
			if blocked := unavailable(v, childPath(path, k)); blocked != "" {
				return blocked
			}
		}
	} else if n.Kind == yaml.SequenceNode {
		for _, child := range n.Content {
			if blocked := unavailable(child, path+"[]"); blocked != "" {
				return blocked
			}
		}
	}
	return ""
}

func childPath(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}
