//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
)

func fileIdentity(f *os.File) (string, error) {
	var info windows.ByHandleFileInformation
	if e := windows.GetFileInformationByHandle(windows.Handle(f.Fd()), &info); e != nil {
		return "", e
	}
	return fmt.Sprintf("%d:%d:%d", info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow), nil
}
