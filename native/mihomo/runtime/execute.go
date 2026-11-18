package runtime

import (
	"antirkn.local/mihomo/probe"
	"antirkn.local/mihomo/validator"
	"context"
	"encoding/json"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
	"io"
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
	if request.Mode != "probe" && request.Mode != "control" {
		return
	}
	if os.MkdirAll(directory, 0700) != nil {
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
