package probe

import (
	"encoding/hex"
	"github.com/metacubex/mihomo/transport/vless"
	"google.golang.org/protobuf/proto"
	"testing"
)

func TestVisionAddonWireFormat(t *testing.T) {
	value, err := proto.Marshal(&vless.Addons{Flow: "xtls-rprx-vision"})
	if err != nil || hex.EncodeToString(value) != "0a1078746c732d727072782d766973696f6e" {
		t.Fatalf("Vision flow wire format: %x, %v", value, err)
	}
}
