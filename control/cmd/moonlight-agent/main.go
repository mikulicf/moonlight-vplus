package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mikulicf/moonlight-vplus/control/internal/agent"
)

func main() {
	configPath := flag.String("config", "", "path to the host agent JSON configuration")
	flag.Parse()
	if *configPath == "" {
		log.Fatal("-config is required")
	}

	handled, err := runWindowsService(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	if handled {
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := runAgent(ctx, *configPath, log.Default()); err != nil {
		log.Fatal(err)
	}
}

func runAgent(ctx context.Context, configPath string, logger agent.Logger) error {
	config, err := agent.LoadConfig(configPath)
	if err != nil {
		return fmt.Errorf("load host agent configuration: %w", err)
	}
	hostAgent, err := agent.New(config, logger)
	if err != nil {
		return fmt.Errorf("initialize host agent: %w", err)
	}
	return hostAgent.Run(ctx)
}
