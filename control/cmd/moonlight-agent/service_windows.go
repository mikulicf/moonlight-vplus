//go:build windows

package main

import (
	"context"
	"log"

	"golang.org/x/sys/windows/svc"
)

const windowsServiceName = "MoonlightManagedHostAgent"

func runWindowsService(configPath string) (bool, error) {
	isService, err := svc.IsWindowsService()
	if err != nil || !isService {
		return false, err
	}
	return true, svc.Run(windowsServiceName, &serviceHandler{configPath: configPath})
}

type serviceHandler struct {
	configPath string
}

func (h *serviceHandler) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runAgent(ctx, h.configPath, log.Default())
	}()

	accepted := svc.AcceptStop | svc.AcceptShutdown
	status := svc.Status{State: svc.Running, Accepts: accepted}
	changes <- status
	for {
		select {
		case err := <-done:
			cancel()
			if err != nil {
				log.Printf("host agent service stopped: %v", err)
				return false, 1
			}
			return false, 0
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				changes <- status
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				cancel()
				if err := <-done; err != nil {
					log.Printf("host agent service shutdown failed: %v", err)
					return false, 1
				}
				return false, 0
			}
		}
	}
}
