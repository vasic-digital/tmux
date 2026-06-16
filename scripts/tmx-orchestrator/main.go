// Command tmx-orchestrator is the vasic-digital/tmux consumer-side CLI
// that drives the `digital.vasic.containers` submodule library to
// orchestrate container distribution to remote test hosts (e.g.
// nezha.local) for this project's testing needs.
//
// This binary lives entirely in the TMUX (consumer) project and only
// IMPORTS the Containers library — it adds NO tmux-specific code INTO
// the submodule (CONST-051 100%-decoupled). The wiring of runtime +
// SSH executor + host manager + scheduler + distributor mirrors the
// proven path in Containers/cmd/boot/main.go.
//
// Subcommands:
//
//	hosts       Load .env, register every configured remote host, probe
//	            each for reachability + resources, print a table. Exit
//	            non-zero if any configured host is unreachable.
//	distribute  Schedule + run a container on the chosen remote host via
//	            the Distributor, print the DistributionSummary, then run
//	            the chosen health checker against the deployed host:port.
//	            Exit non-zero on distribution OR health-check failure.
//	down        Stop + remove the distributed container(s) and close
//	            tunnels via the Distributor's Undistribute teardown.
//	help        Usage.
//
// Build: go build -o ../tmx-orchestrator-bin .
// (the binary scripts/tmx-orchestrator-bin is gitignored, regenerated
// on each host per §11.4.77.)
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"text/tabwriter"
	"time"

	"digital.vasic.containers/pkg/distribution"
	"digital.vasic.containers/pkg/envconfig"
	"digital.vasic.containers/pkg/health"
	"digital.vasic.containers/pkg/logging"
	"digital.vasic.containers/pkg/remote"
	"digital.vasic.containers/pkg/runtime"
	"digital.vasic.containers/pkg/scheduler"
)

// orchestrator holds the wired Containers-library components shared by
// every subcommand. It is assembled once by newOrchestrator().
type orchestrator struct {
	cfg         *envconfig.DistributionConfig
	logger      logging.Logger
	rt          runtime.ContainerRuntime
	executor    *remote.SSHExecutor
	hostManager *remote.DefaultHostManager
	scheduler   scheduler.Scheduler
	distributor *distribution.DefaultDistributor
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	sub := os.Args[1]
	args := os.Args[2:]

	switch sub {
	case "help", "-h", "--help":
		usage()
		return
	case "hosts":
		os.Exit(cmdHosts(args))
	case "distribute":
		os.Exit(cmdDistribute(args))
	case "down":
		os.Exit(cmdDown(args))
	default:
		fmt.Fprintf(os.Stderr, "tmx-orchestrator: unknown subcommand %q\n\n", sub)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `tmx-orchestrator — drive the Containers submodule to distribute
containers to remote test hosts for the tmux project's testing needs.

USAGE:
  tmx-orchestrator <command> [flags]

COMMANDS:
  hosts        Register configured remote hosts and probe each
               (reachability + CPU/mem). Non-zero exit if any host is
               unreachable.
  distribute   Schedule + run a container on a remote host, print the
               distribution summary, then health-check the deployment.
  down         Stop + remove distributed container(s); close tunnels.
  help         Show this help.

COMMON FLAGS:
  --env <path>      Path to the .env config. Default search order:
                    ../../Containers/.env, ../../.env, ./.env, $PWD/.env
  --timeout <dur>   Overall context timeout (default 3m), e.g. 90s, 5m.

distribute FLAGS:
  --image <ref>            Container image (default docker.io/library/nginx:alpine)
  --name <container-name>  Container name (default tmx-orch-demo)
  --port <containerPort>   Container port inside the container (default 80)
  --publish <hostPort>     Host port to publish --port to (0 = same as --port)
  --health <tcp|http>      Health check kind (default tcp)
  --health-path </path>    HTTP health path (http only, default /)

down FLAGS:
  --name <container-name>  Container name to tear down (default tmx-orch-demo)

EXAMPLES:
  tmx-orchestrator hosts
  tmx-orchestrator hosts --env ../../Containers/.env
  tmx-orchestrator distribute --image docker.io/library/nginx:alpine \
      --name tmx-web --port 80 --health http --health-path /
  tmx-orchestrator distribute --image docker.io/library/redis:7 \
      --name tmx-redis --port 6379 --health tcp
  tmx-orchestrator down --name tmx-web

The binary consumes the vasic-digital/Containers submodule library
(pkg/runtime, pkg/remote, pkg/scheduler, pkg/distribution, pkg/health,
pkg/envconfig, pkg/logging). It adds no tmux-specific code INTO the
submodule (CONST-051).
`)
}

// resolveEnvFile returns the first existing candidate .env path. An
// explicit --env value (when non-empty) is returned even if missing so
// the caller surfaces a clear "load <path>" error.
func resolveEnvFile(explicit string) string {
	if explicit != "" {
		return explicit
	}
	candidates := []string{
		"../../Containers/.env",
		"../../.env",
		"./.env",
	}
	if pwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, pwd+"/.env")
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// newContext returns a context cancelled on SIGINT/SIGTERM and bounded
// by the requested timeout, mirroring Containers/cmd/boot/main.go.
func newContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	base, baseCancel := context.WithCancel(context.Background())

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Fprintln(os.Stderr, "\ntmx-orchestrator: signal received, shutting down...")
		baseCancel()
	}()

	ctx, cancel := context.WithTimeout(base, timeout)
	return ctx, func() {
		cancel()
		baseCancel()
	}
}

// newOrchestrator loads the .env config and wires every Containers
// component (runtime auto-detect, SSH executor, host manager, scheduler,
// distributor) following the cmd/boot path. Registered hosts come from
// cfg.ToRemoteHosts().
func newOrchestrator(ctx context.Context, envFile string) (*orchestrator, error) {
	logger := logging.NewStdLogger("tmx-orchestrator")

	resolved := resolveEnvFile(envFile)
	if resolved == "" {
		return nil, fmt.Errorf(
			"no .env config found (searched --env, " +
				"../../Containers/.env, ../../.env, ./.env, $PWD/.env)",
		)
	}

	cfg, err := envconfig.LoadFromFile(resolved)
	if err != nil {
		return nil, fmt.Errorf("load env config %s: %w", resolved, err)
	}
	logger.Info("config loaded from %s: enabled=%v, hosts=%d, scheduler=%s",
		resolved, cfg.Enabled, len(cfg.Hosts), cfg.Scheduler)

	rt, err := runtime.AutoDetect(ctx)
	if err != nil {
		return nil, fmt.Errorf("auto-detect local runtime: %w", err)
	}
	logger.Info("local runtime: %s", rt.Name())

	exec, err := remote.NewSSHExecutor(logger)
	if err != nil {
		return nil, fmt.Errorf("create SSH executor: %w", err)
	}

	hostManager := remote.NewHostManager(exec, logger)
	registered := 0
	for _, host := range cfg.ToRemoteHosts() {
		if addErr := hostManager.AddHost(host); addErr != nil {
			logger.Warn("failed to register host %s: %v", host.Name, addErr)
			continue
		}
		registered++
		logger.Info("registered remote host: %s (%s)", host.Name, host.Address)
	}
	if registered == 0 {
		return nil, fmt.Errorf(
			"no remote hosts registered from %s "+
				"(check CONTAINERS_REMOTE_HOST_N_* entries)", resolved,
		)
	}

	sched := scheduler.NewScheduler(
		hostManager, logger,
		scheduler.WithStrategy(strategyFromConfig(cfg.Scheduler)),
	)

	distributor := distribution.NewDistributor(
		distribution.WithLocalRuntime(rt),
		distribution.WithHostManager(hostManager),
		distribution.WithExecutor(exec),
		distribution.WithScheduler(sched),
		distribution.WithLogger(logger),
	)

	return &orchestrator{
		cfg:         cfg,
		logger:      logger,
		rt:          rt,
		executor:    exec,
		hostManager: hostManager,
		scheduler:   sched,
		distributor: distributor,
	}, nil
}

// close releases the SSH executor's connection pool, if any.
func (o *orchestrator) close() {
	if o.executor != nil {
		_ = o.executor.Close()
	}
}

// strategyFromConfig maps the .env scheduler string to a
// scheduler.PlacementStrategy, defaulting to resource_aware.
func strategyFromConfig(name string) scheduler.PlacementStrategy {
	switch scheduler.PlacementStrategy(name) {
	case scheduler.StrategyResourceAware,
		scheduler.StrategyRoundRobin,
		scheduler.StrategyAffinity,
		scheduler.StrategySpread,
		scheduler.StrategyBinPack,
		scheduler.StrategyGPUAffinity:
		return scheduler.PlacementStrategy(name)
	default:
		return scheduler.StrategyResourceAware
	}
}

// cmdHosts registers + probes every configured remote host and prints a
// table. Returns 1 if any configured host is unreachable, 2 on setup
// error.
func cmdHosts(args []string) int {
	fs := flag.NewFlagSet("hosts", flag.ContinueOnError)
	envFile := fs.String("env", "", "Path to .env config file")
	timeout := fs.Duration("timeout", 3*time.Minute, "Overall timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ctx, cancel := newContext(*timeout)
	defer cancel()

	orch, err := newOrchestrator(ctx, *envFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 2
	}
	defer orch.close()

	hosts := orch.hostManager.ListHosts()

	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tADDRESS\tPORT\tREACHABLE\tCPU%\tMEM%\tMEM(MB)\tCORES")

	anyUnreachable := false
	for _, h := range hosts {
		res, probeErr := orch.hostManager.ProbeHost(ctx, h.Name)
		if probeErr != nil {
			anyUnreachable = true
			fmt.Fprintf(tw, "%s\t%s\t%d\tno\t-\t-\t-\t-\n",
				h.Name, h.Address, h.SSHPort())
			orch.logger.Warn("host %s probe failed: %v", h.Name, probeErr)
			continue
		}
		fmt.Fprintf(tw, "%s\t%s\t%d\tyes\t%.1f\t%.1f\t%d/%d\t%d\n",
			h.Name, h.Address, h.SSHPort(),
			res.CPUPercent, res.MemoryPercent,
			res.MemoryUsedMB, res.MemoryTotalMB, res.CPUCores)
	}
	_ = tw.Flush()

	if anyUnreachable {
		fmt.Fprintln(os.Stderr,
			"tmx-orchestrator: at least one configured host is unreachable")
		return 1
	}
	return 0
}

// cmdDistribute schedules + runs a container on the chosen remote host
// and then health-checks the deployment. Returns 1 on distribution or
// health-check failure, 2 on setup error.
func cmdDistribute(args []string) int {
	fs := flag.NewFlagSet("distribute", flag.ContinueOnError)
	envFile := fs.String("env", "", "Path to .env config file")
	timeout := fs.Duration("timeout", 3*time.Minute, "Overall timeout")
	image := fs.String("image", "docker.io/library/nginx:alpine", "Container image")
	name := fs.String("name", "tmx-orch-demo", "Container name")
	port := fs.Int("port", 80, "Container port (inside the container)")
	publish := fs.Int("publish", 0, "Host port to publish --port to (0 = same as --port); required for a cross-host health check to reach the service")
	healthKind := fs.String("health", "tcp", "Health check kind: tcp|http")
	healthPath := fs.String("health-path", "/", "HTTP health path (http only)")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *healthKind != "tcp" && *healthKind != "http" {
		fmt.Fprintf(os.Stderr,
			"Error: --health must be tcp or http (got %q)\n", *healthKind)
		return 2
	}

	ctx, cancel := newContext(*timeout)
	defer cancel()

	orch, err := newOrchestrator(ctx, *envFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 2
	}
	defer orch.close()

	publishPort := *publish
	if publishPort == 0 {
		publishPort = *port
	}
	reqs := []scheduler.ContainerRequirements{
		{
			Name:  *name,
			Image: *image,
			Ports: []scheduler.PortMapping{
				{HostPort: publishPort, ContainerPort: *port},
			},
		},
	}

	summary, err := orch.distributor.Distribute(ctx, reqs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: distribute: %v\n", err)
		return 1
	}

	printSummary(summary)

	if summary.FailedContainers > 0 {
		fmt.Fprintf(os.Stderr,
			"tmx-orchestrator: %d container(s) failed to deploy\n",
			summary.FailedContainers)
		return 1
	}

	// Resolve the host the container actually landed on, so the health
	// check targets the real deployment address:port.
	target, err := resolveDeploymentTarget(orch, summary, *name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 1
	}

	if !runHealthCheck(ctx, orch, target, publishPort, *healthKind, *healthPath) {
		return 1
	}
	return 0
}

// resolveDeploymentTarget finds the host address that the named
// container was placed on, for the health check. A locally-placed
// container resolves to localhost.
func resolveDeploymentTarget(
	orch *orchestrator,
	summary *distribution.DistributionSummary,
	name string,
) (string, error) {
	for _, dc := range summary.Containers {
		if dc.Requirement.Name != name {
			continue
		}
		if dc.HostName == "" || dc.HostName == "local" {
			return "localhost", nil
		}
		host, err := orch.hostManager.GetHost(dc.HostName)
		if err != nil {
			return "", fmt.Errorf(
				"resolve deployment host %q: %w", dc.HostName, err)
		}
		return host.Address, nil
	}
	return "", fmt.Errorf(
		"container %q not present in distribution summary", name)
}

// runHealthCheck runs the chosen health checker (tcp|http) against
// address:port and prints the HealthResult. Returns true when healthy.
func runHealthCheck(
	ctx context.Context,
	orch *orchestrator,
	address string,
	port int,
	kind, path string,
) bool {
	checker := health.NewDefaultChecker()

	target := health.HealthTarget{
		Name: "tmx-orch-deployment",
		Host: address,
		Port: strconv.Itoa(port),
	}
	if kind == "http" {
		target.Type = health.HealthHTTP
		target.Path = path
	} else {
		target.Type = health.HealthTCP
	}

	orch.logger.Info("health-checking %s %s:%d%s (polling until ready)",
		kind, address, port, pathSuffix(kind, path))

	// Poll until the service is ready: a freshly-deployed container needs a
	// moment for the runtime's port-forward + the app to start accepting
	// connections (observed: the first connect after `run -d` returns is
	// reset). Retry up to ~15s; a genuinely-down service stays UNHEALTHY for
	// the full window and is reported as such (no false PASS).
	var result *health.HealthResult
	for attempt := 1; attempt <= 30; attempt++ {
		result = checker.Check(ctx, target)
		if result.Healthy || ctx.Err() != nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}

	status := "UNHEALTHY"
	if result.Healthy {
		status = "HEALTHY"
	}
	fmt.Printf("\nHealth check (%s) %s:%d -> %s (%.0fms)\n",
		kind, address, port, status, float64(result.Duration.Microseconds())/1000.0)
	if result.Error != "" {
		fmt.Printf("  error: %s\n", result.Error)
	}
	for k, v := range result.Details {
		fmt.Printf("  %s: %s\n", k, v)
	}

	if !result.Healthy {
		fmt.Fprintln(os.Stderr,
			"tmx-orchestrator: deployment failed health check")
		return false
	}
	return true
}

func pathSuffix(kind, path string) string {
	if kind == "http" {
		return path
	}
	return ""
}

// printSummary prints the DistributionSummary: counts + per-container
// host placement.
func printSummary(s *distribution.DistributionSummary) {
	fmt.Printf("\nDistribution summary:\n")
	fmt.Printf("  total=%d  local=%d  remote=%d  failed=%d  duration=%s\n",
		s.TotalContainers, s.LocalContainers, s.RemoteContainers,
		s.FailedContainers, s.Duration)

	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "  CONTAINER\tHOST\tSTATE\tERROR")
	for _, dc := range s.Containers {
		host := dc.HostName
		if host == "" {
			host = "local"
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\n",
			dc.Requirement.Name, host, dc.State, dc.Error)
	}
	_ = tw.Flush()
}

// cmdDown tears down the distributed container(s) and closes tunnels via
// the Distributor's Undistribute. Idempotent: a Distributor with no
// in-memory containers is a no-op.
func cmdDown(args []string) int {
	fs := flag.NewFlagSet("down", flag.ContinueOnError)
	envFile := fs.String("env", "", "Path to .env config file")
	timeout := fs.Duration("timeout", 3*time.Minute, "Overall timeout")
	name := fs.String("name", "tmx-orch-demo", "Container name to tear down")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ctx, cancel := newContext(*timeout)
	defer cancel()

	orch, err := newOrchestrator(ctx, *envFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return 2
	}
	defer orch.close()

	// A freshly-constructed Distributor has no in-memory record of a
	// container deployed by a prior process invocation, so explicitly
	// remove the named container on each registered remote host so
	// teardown is idempotent across separate process runs.
	for _, h := range orch.hostManager.ListHosts() {
		host, getErr := orch.hostManager.GetHost(h.Name)
		if getErr != nil {
			continue
		}
		rt := host.Runtime
		if rt == "" {
			rt = "docker"
		}
		cmd := fmt.Sprintf("%s rm -f %s 2>/dev/null || true", rt, *name)
		if _, execErr := orch.executor.Execute(ctx, *host, cmd); execErr != nil {
			orch.logger.Warn("teardown on %s: %v", h.Name, execErr)
			continue
		}
		orch.logger.Info("removed container %s on %s", *name, h.Name)
	}

	// Close tunnels / unmount volumes / clear in-memory state.
	if err := orch.distributor.Undistribute(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error: undistribute: %v\n", err)
		return 1
	}

	fmt.Printf("teardown complete for container %q\n", *name)
	return 0
}
