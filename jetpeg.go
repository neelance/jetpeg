package jetpeg

import (
	"fmt"
	"github.com/axw/gollvm/llvm"
	"unsafe"
)

/*
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

void pushEmpty();
void pushInputRange(size_t, size_t);
void pushBoolean(bool);
void pushString(char*);
void pushArray(bool);
void appendToArray();
void makeLabel(char*);
void mergeLabels(int64_t);
void makeValue(char*, char*, int64_t);
void makeObject(char*);
void pop();
void localsPush(int64_t);
void localsLoad(int64_t);
void localsPop(int64_t);
size_t match(size_t);
void setAsSource();
void readFromSource(char*);
void traceEnter(char*);
void traceLeave(char*, bool);
void traceFailure(size_t, char*, bool);
*/
import "C"

type InputRange struct {
	Start int
	End   int
}

// callbacks rely on global variables since Go has no easy way of passing closures to C and the JetPEG backend has no support for passing the parser object yet
var Debug = false
var Factory = func(class string, value interface{}) interface{} { return value }
var input []byte
var inputOffset uintptr
var outputStack []interface{}
var localsStack []interface{}

func init() {
	if err := llvm.InitializeNativeTarget(); err != nil {
		panic(err)
	}
}

func Parse(grammarPath string, ruleName string, rawInput []byte) (interface{}, error) {
	outputStack = outputStack[:0]
	mod, err := llvm.ParseBitcodeFile(grammarPath)
	if err != nil {
		return nil, err
	}
	engine, err := llvm.NewJITCompiler(mod, 0)
	if err != nil {
		return nil, err
	}
	input = append(rawInput, 0)
	inputOffset = uintptr(unsafe.Pointer(&input[0]))
	result := engine.RunFunction(engine.FindFunction(ruleName+"_match"), []llvm.GenericValue{
		llvm.NewGenericValueFromPointer(unsafe.Pointer(&input[0])),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(&input[len(input)-1])),
		llvm.NewGenericValueFromInt(llvm.Int1Type(), 0, false),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pushEmpty)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pushInputRange)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pushBoolean)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pushString)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pushArray)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.appendToArray)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.makeLabel)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.mergeLabels)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.makeValue)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.makeObject)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.pop)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.localsPush)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.localsLoad)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.localsPop)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.match)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.setAsSource)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.readFromSource)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.traceEnter)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.traceLeave)),
		llvm.NewGenericValueFromPointer(unsafe.Pointer(C.traceFailure)),
	})
	if result.Int(false) == 0 {
		return nil, fmt.Errorf("parsing failed")
	}
	return outputStack[0], nil
}

func pushOutput(v interface{}) {
	outputStack = append(outputStack, v)
}

func popOutput() interface{} {
	v := outputStack[len(outputStack)-1]
	outputStack = outputStack[:len(outputStack)-1]
	return v
}

//export pushEmpty
func pushEmpty() {
	if Debug {
		fmt.Printf("pushEmpty()\n")
	}
	outputStack = append(outputStack, make(map[string]interface{}))
}

//export pushInputRange
func pushInputRange(from uintptr, to uintptr) {
	if Debug {
		fmt.Printf("pushInputRange(%d, %d)\n", from-inputOffset, to-inputOffset)
	}
	pushOutput(&InputRange{int(from - inputOffset), int(to - inputOffset)})
}

//export pushBoolean
func pushBoolean(value C.bool) {
	if Debug {
		fmt.Printf("pushBoolean(%t)\n", bool(value))
	}
	pushOutput(bool(value))
}

//export pushString
func pushString(value *C.char) {
	if Debug {
		fmt.Printf("pushString(%q)\n", C.GoString(value))
	}
	pushOutput(C.GoString(value))
}

//export pushArray
func pushArray(appendCurrent C.bool) {
	if Debug {
		fmt.Printf("pushArray(%t)\n", bool(appendCurrent))
	}
	if appendCurrent {
		pushOutput([]interface{}{popOutput()})
		return
	}
	pushOutput([]interface{}{})
}

//export appendToArray
func appendToArray() {
	if Debug {
		fmt.Printf("appendToArray()\n")
	}
	v := popOutput()
	pushOutput(append(popOutput().([]interface{}), v))
}

//export makeLabel
func makeLabel(name *C.char) {
	if Debug {
		fmt.Printf("makeLabel(%q)\n", C.GoString(name))
	}
	pushOutput(map[string]interface{}{C.GoString(name): popOutput()})
}

//export mergeLabels
func mergeLabels(count C.int64_t) {
	if Debug {
		fmt.Printf("mergeLabels(%d)\n", count)
	}
	merged := make(map[string]interface{})
	for i := 0; i < int(count); i++ {
		m := popOutput().(map[string]interface{})
		for k, v := range m {
			merged[k] = v
		}
	}
	pushOutput(merged)
}

//export makeValue
func makeValue(code *C.char, filename *C.char, line C.int64_t) {
	if Debug {
		fmt.Printf("makeValue(%q, %q, %d)\n", C.GoString(code), C.GoString(filename), line)
	}
	panic("makeValue not supported")
}

//export makeObject
func makeObject(class *C.char) {
	if Debug {
		fmt.Printf("makeObject(%q)\n", C.GoString(class))
	}
	pushOutput(Factory(C.GoString(class), popOutput()))
}

//export pop
func pop() {
	if Debug {
		fmt.Printf("pop()\n")
	}
	popOutput()
}

//export localsPush
func localsPush(count C.int64_t) {
	if Debug {
		fmt.Printf("localsPush(%d)\n", count)
	}
	for i := 0; i < int(count); i++ {
		localsStack = append(localsStack, popOutput())
	}
}

//export localsLoad
func localsLoad(index C.int64_t) {
	if Debug {
		fmt.Printf("localsLoad(%d)\n", index)
	}
	pushOutput(localsStack[len(localsStack)-1-int(index)])
}

//export localsPop
func localsPop(count C.int64_t) {
	if Debug {
		fmt.Printf("localsPop(%d)\n", count)
	}
	localsStack = localsStack[:len(localsStack)-int(count)]
}

//export match
func match(input uintptr) uintptr {
	if Debug {
		fmt.Printf("match(%d)\n", input-inputOffset)
	}
	panic("match not supported")
}

//export setAsSource
func setAsSource() {
	if Debug {
		fmt.Printf("setAsSource()\n")
	}
	panic("setAsSource not supported")
}

//export readFromSource
func readFromSource(name *C.char) {
	if Debug {
		fmt.Printf("readFromSource(%q)\n", C.GoString(name))
	}
	panic("readFromSource not supported")
}

//export traceEnter
func traceEnter(name *C.char) {
	if Debug {
		fmt.Printf("traceEnter(%q)\n", C.GoString(name))
	}
}

//export traceLeave
func traceLeave(name *C.char, successful C.bool) {
	if Debug {
		fmt.Printf("traceLeave(%q, %t)\n", C.GoString(name), bool(successful))
	}
}

//export traceFailure
func traceFailure(pos uintptr, reason *C.char, isExpectation C.bool) {
	if Debug {
		fmt.Printf("traceFailure(%d, %q, %t  )\n", pos-inputOffset, C.GoString(reason), bool(isExpectation))
	}
}
