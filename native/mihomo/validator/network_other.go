//go:build !linux && !android

package validator

// Supported constructors are guarded by DefaultSocketHook and the deny resolver.
// Windows runtime acceptance is tracked separately from cross-compilation.
func restrictNetwork() error { return nil }
