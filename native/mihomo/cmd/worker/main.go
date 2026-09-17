package main

import (
	"antirkn.local/mihomo/runtime"
	"antirkn.local/mihomo/validator"
	"encoding/json"
	"io"
	"os"
	"time"
)

func main() {
	// No inherited hooks, user config or secrets in arguments. One request only.
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	time.AfterFunc(15*time.Second, func() { os.Exit(3) })
	input, err := io.ReadAll(io.LimitReader(os.Stdin, validator.MaxInput*4+1))
	if err != nil {
		os.Exit(2)
	}
	result := runtime.Execute(input, os.Args[1])
	_ = json.NewEncoder(os.Stdout).Encode(result)
}
