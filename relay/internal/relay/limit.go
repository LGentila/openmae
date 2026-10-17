package relay

import (
	"context"
	"net/netip"
	"sync"
	"time"
)

// bucket is a token bucket. Tubes count bytes with it; control connections
// count messages.
type bucket struct {
	mu     sync.Mutex
	rate   float64 // tokens per second
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

func newBucket(rate, burst float64, now func() time.Time) *bucket {
	if now == nil {
		now = time.Now
	}
	return &bucket{rate: rate, burst: burst, tokens: burst, last: now(), now: now}
}

func (b *bucket) refill() {
	t := b.now()
	if d := t.Sub(b.last); d > 0 {
		b.tokens = min(b.burst, b.tokens+d.Seconds()*b.rate)
		b.last = t
	}
}

// allow takes n tokens if they are all there. Datagrams use it: one that
// does not fit in the budget is dropped, not delayed.
func (b *bucket) allow(n int) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refill()
	if b.tokens < float64(n) {
		return false
	}
	b.tokens -= float64(n)
	return true
}

// reserve takes n tokens, borrowing from the future if needed, and returns
// how long the caller must wait to stay within the rate. Tube bytes use it:
// they are slowed down, never dropped. The debt also holds back datagrams
// until it is repaid.
func (b *bucket) reserve(n int) time.Duration {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refill()
	b.tokens -= float64(n)
	if b.tokens >= 0 {
		return 0
	}
	return time.Duration(-b.tokens / b.rate * float64(time.Second))
}

func (b *bucket) wait(ctx context.Context, n int) error {
	d := b.reserve(n)
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// attempts limits hello and connect messages per IP address over a sliding
// window. IPv6 addresses count per /64, the usual size of one network, so
// that a single host cannot dodge the limit by changing its address.
type attempts struct {
	mu        sync.Mutex
	limit     int
	window    time.Duration
	maxKeys   int // bounds memory; past it, new addresses are refused
	seen      map[netip.Prefix][]time.Time
	lastSweep time.Time
	now       func() time.Time
}

func newAttempts(limit int, window time.Duration, maxKeys int, now func() time.Time) *attempts {
	if now == nil {
		now = time.Now
	}
	return &attempts{
		limit:     limit,
		window:    window,
		maxKeys:   maxKeys,
		seen:      make(map[netip.Prefix][]time.Time),
		lastSweep: now(),
		now:       now,
	}
}

// allow records an attempt from ip and reports whether it is within the
// limit. Refused attempts are not recorded, so a client that waits gets in
// again.
func (a *attempts) allow(ip netip.Addr) bool {
	key := addrKey(ip)
	now := a.now()
	a.mu.Lock()
	defer a.mu.Unlock()
	if now.Sub(a.lastSweep) >= a.window {
		a.sweep(now)
	}
	times, known := a.seen[key]
	cut := 0
	for cut < len(times) && now.Sub(times[cut]) >= a.window {
		cut++
	}
	times = append(times[:0], times[cut:]...)
	if len(times) >= a.limit {
		a.seen[key] = times
		return false
	}
	if !known && len(a.seen) >= a.maxKeys {
		return false
	}
	a.seen[key] = append(times, now)
	return true
}

// sweep forgets addresses whose attempts are all out of the window.
func (a *attempts) sweep(now time.Time) {
	for k, times := range a.seen {
		if len(times) == 0 || now.Sub(times[len(times)-1]) >= a.window {
			delete(a.seen, k)
		}
	}
	a.lastSweep = now
}

func addrKey(ip netip.Addr) netip.Prefix {
	ip = ip.Unmap().WithZone("")
	bits := 32
	if ip.Is6() {
		bits = 64
	}
	p, err := ip.Prefix(bits)
	if err != nil { // invalid address: all of them share one key
		return netip.Prefix{}
	}
	return p
}

// deliveries bounds the deliveries to each inbound name in home mode: so
// many over a sliding minute, so many in progress at once. Like attempts,
// refused deliveries are not recorded.
type deliveries struct {
	mu        sync.Mutex
	perMinute int
	atOnce    int
	maxNames  int // bounds memory; past it, new names are refused
	names     map[string]*deliveryCount
	lastSweep time.Time
	now       func() time.Time
}

type deliveryCount struct {
	recent []time.Time // deliveries started in the last minute
	active int         // deliveries in progress
}

func newDeliveries(perMinute, atOnce, maxNames int, now func() time.Time) *deliveries {
	if now == nil {
		now = time.Now
	}
	return &deliveries{
		perMinute: perMinute,
		atOnce:    atOnce,
		maxNames:  maxNames,
		names:     make(map[string]*deliveryCount),
		lastSweep: now(),
		now:       now,
	}
}

// start records a delivery to name and reports whether it is within the
// limits. If it is, the caller calls done once the delivery is over.
func (d *deliveries) start(name string) bool {
	now := d.now()
	d.mu.Lock()
	defer d.mu.Unlock()
	if now.Sub(d.lastSweep) >= time.Minute {
		d.sweep(now)
	}
	n := d.names[name]
	if n == nil {
		if len(d.names) >= d.maxNames {
			return false
		}
		n = &deliveryCount{}
		d.names[name] = n
	}
	cut := 0
	for cut < len(n.recent) && now.Sub(n.recent[cut]) >= time.Minute {
		cut++
	}
	n.recent = append(n.recent[:0], n.recent[cut:]...)
	if len(n.recent) >= d.perMinute || n.active >= d.atOnce {
		return false
	}
	n.recent = append(n.recent, now)
	n.active++
	return true
}

func (d *deliveries) done(name string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if n := d.names[name]; n != nil && n.active > 0 {
		n.active--
	}
}

// sweep forgets names with no delivery in progress and none in the last
// minute.
func (d *deliveries) sweep(now time.Time) {
	for k, n := range d.names {
		if n.active == 0 && (len(n.recent) == 0 || now.Sub(n.recent[len(n.recent)-1]) >= time.Minute) {
			delete(d.names, k)
		}
	}
	d.lastSweep = now
}
