package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"antirkn.local/mihomo/validator"
	"encoding/json"
)

//export antirknValidate
func antirknValidate(input *C.char, directory *C.char) *C.char {
	result := validator.Validate([]byte(C.GoString(input)), C.GoString(directory))
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}
func main() {}
