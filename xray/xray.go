// Package xray runs Xray-core for VoidrauVPN, bound for Android with gomobile
// (see scripts/build_xray.sh): one Xray instance at a time, started from the
// app's JSON config, reading from the TUN device the app's VpnService opened.
// Only what the app uses: start and stop, the outbound traffic counters and
// the version.
//
// The shape follows the same public Xray-core API BPB-VPN's xray.go binds
// (GPLv3 — adapted, own code; see README/CHANGELOG). The app excludes itself
// from its VPN, so Xray's own sockets bypass the tunnel without
// VpnService.protect.
package xray

import (
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

// Environment variables Xray-core reads.
const (
	envAsset = "xray.location.asset"
	envCert  = "xray.location.cert"
	envTunFd = "xray.tun.fd"
)

// InitEnv points Xray at dir for its geo files (geoip.dat / geosite.dat) and
// the certificates a config names without a path.
func InitEnv(dir string) {
	os.Setenv(envAsset, dir)
	os.Setenv(envCert, dir)
}

// Version is Xray-core's version, e.g. 26.10.21.
func Version() string {
	return core.Version()
}

// Controller runs one Xray instance at a time.
type Controller struct {
	mu       sync.Mutex
	instance *core.Instance
	stats    stats.Manager
}

// NewController creates the process-wide controller.
func NewController() *Controller {
	return &Controller{}
}

// IsRunning reports whether an instance is up.
func (c *Controller) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.instance != nil
}

// Start starts an instance from the JSON config, with the TUN device tunFd
// (0: none, for proxy mode). Does nothing while one is running.
func (c *Controller) Start(config string, tunFd int32) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance != nil {
		return nil
	}
	os.Setenv(envTunFd, strconv.Itoa(int(tunFd)))

	parsed, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return fmt.Errorf("config error: %w", err)
	}
	instance, err := core.New(parsed)
	if err != nil {
		return fmt.Errorf("core init failed: %w", err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		return fmt.Errorf("startup failed: %w", err)
	}
	c.instance = instance
	c.stats = instance.GetFeature(stats.ManagerType()).(stats.Manager)
	return nil
}

// Stop closes the running instance, if any.
func (c *Controller) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance == nil {
		return
	}
	c.instance.Close()
	c.instance = nil
	c.stats = nil
}

// counter reads one named counter of the running instance, or 0 when the
// counter is absent.
func (c *Controller) counter(name string) int64 {
	v := c.stats.GetCounter(name)
	if v == nil {
		return 0
	}
	return v.Value()
}

// TrafficUp returns the uplink byte counter of the running instance's
// proxy outbound, or an error when nothing is running.
func (c *Controller) TrafficUp() (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance == nil || c.stats == nil {
		return 0, errors.New("xray is not running")
	}
	return c.counter("outbound>>>proxy>>>traffic>>>uplink"), nil
}

// TrafficDown returns the downlink byte counter of the running instance's
// proxy outbound, or an error when nothing is running.
func (c *Controller) TrafficDown() (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance == nil || c.stats == nil {
		return 0, errors.New("xray is not running")
	}
	return c.counter("outbound>>>proxy>>>traffic>>>downlink"), nil
}

var _ = log.Printf
