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
