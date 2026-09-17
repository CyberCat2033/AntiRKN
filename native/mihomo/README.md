# AntiRKN Mihomo runtime

Pinned upstream: https://github.com/MetaCubeX/mihomo/tree/v1.19.30
Revision: ac017cdd246ce8bd547653d927e7bf77d7ee73d5.
This native wrapper is distributed under GPL-3.0, see LICENSE.
The pinned module sources, checksums and replacement are in go.mod/go.sum;
`go mod download` retrieves the corresponding unmodified dependency source.
The AntiRKN source checkout contains the wrapper and build instructions; keep
that source with any distributed binary. Dependency notices are generated into
`notices/` beside each build and included in the application bundle.

Requires Go >= 1.26, Python 3; Android also NDK 28.2.13676358 (Linux host).
From repository root:

```
python3 tool/build_mihomo.py --target linux --output build/mihomo/linux/antirkn-mihomo
python3 tool/build_mihomo.py --target windows --output build/mihomo/windows/antirkn-mihomo.exe
python3 tool/build_mihomo.py --target android --abi arm64-v8a --ndk /path/to/ndk --output build/mihomo/android/arm64-v8a/libantirkn_mihomo.so
```

Normal Flutter desktop/Android builds invoke the same script. Outputs and module
cache are not committed. The build stamp records toolchain, inputs and binary SHA256.
The config worker parses the original YAML without applying the config. It never
starts configured listeners, TUN, provider polling or the external controller.
Linux/Android deny new sockets process-wide with seccomp. Windows uses the denied
dialer/resolver and a supported-constructor allowlist; Windows runtime tests require
a Windows host. Each request runs in a fresh process with a private temporary home.
Only bounded status codes and numeric locations leave it; raw upstream logs do not.
