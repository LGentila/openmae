package relay

import (
	"context"
	"net/netip"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time      { return c.t }
func (c *fakeClock) add(d time.Duration) { c.t = c.t.Add(d) }
func newClock() *fakeClock               { return &fakeClock{t: time.Unix(1_000_000, 0)} }
func ms(n int) time.Duration             { return time.Duration(n) * time.Millisecond }
func near(got, want time.Duration) bool  { return got > want-ms(1) && got < want+ms(1) }
func bucketFor(c *fakeClock) *bucket     { return newBucket(32_000, 32_000, c.now) }
func allowAll(b *bucket, n, size int) (k int) {
	for range n {
		if b.allow(size) {
			k++
		}
	}
	return k
}

func TestBucketDropsDatagramsBeyondTheBudget(t *testing.T) {
	clock := newClock()
	b := bucketFor(clock)
	// A full second of budget at start, then 32 bytes per millisecond.
	if got := allowAll(b, 400, 100); got != 320 {
		t.Errorf("burst: %d datagrams of 100 bytes passed, want 320", got)
	}
	clock.add(ms(10))
	if got := allowAll(b, 10, 100); got != 3 {
		t.Errorf("after 10 ms: %d passed, want 3", got)
	}
	clock.add(time.Hour)
	if got := allowAll(b, 400, 100); got != 320 {
		t.Errorf("the budget piles up past the burst: %d passed", got)
	}
}

func TestBucketSlowsBytesDown(t *testing.T) {
	clock := newClock()
	b := bucketFor(clock)
	if d := b.reserve(32_000); d != 0 {
		t.Errorf("within the burst: wait %v", d)
	}
	if d := b.reserve(16_000); !near(d, ms(500)) {
		t.Errorf("half a second over: wait %v", d)
	}
	// The debt holds datagrams back until it is repaid.
	clock.add(ms(400))
	if b.allow(1) {
		t.Error("datagram passed while in debt")
	}
	clock.add(ms(101))
	if !b.allow(1) {
		t.Error("datagram refused once the debt was repaid")
	}
}

func TestBucketWaitEndsWithContext(t *testing.T) {
	b := newBucket(1, 1, nil)
	b.reserve(1)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := b.wait(ctx, 1000); err == nil {
		t.Error("wait ignored its context")
	}
	if err := newBucket(1000, 1000, nil).wait(context.Background(), 10); err != nil {
		t.Error(err)
	}
}

func TestAttempts(t *testing.T) {
	clock := newClock()
	a := newAttempts(10, time.Minute, 100, clock.now)
	ip := netip.MustParseAddr("192.0.2.1")
	for i := range 10 {
		if !a.allow(ip) {
			t.Fatalf("attempt %d refused", i+1)
		}
		clock.add(time.Second)
	}
	if a.allow(ip) {
		t.Error("11th attempt within a minute allowed")
	}
	if !a.allow(netip.MustParseAddr("192.0.2.2")) {
		t.Error("another address refused")
	}
	// Refused attempts are not counted: the first one leaves the window
	// 60 seconds after it was made.
	clock.add(50 * time.Second) // 60 s after the first
	if !a.allow(ip) {
		t.Error("attempt refused once the first left the window")
	}
	if a.allow(ip) {
		t.Error("the second is still in the window")
	}
	// IPv4 addresses mapped in IPv6 are the same address.
	if a.allow(netip.MustParseAddr("::ffff:192.0.2.1")) {
		t.Error("mapped address counted apart")
	}
}

func TestAttemptsCountIPv6Per64(t *testing.T) {
	clock := newClock()
	a := newAttempts(2, time.Minute, 100, clock.now)
	for _, s := range []string{"2001:db8:1:2::1", "2001:db8:1:2:aaaa::7"} {
		if !a.allow(netip.MustParseAddr(s)) {
			t.Fatalf("%s refused", s)
		}
	}
	if a.allow(netip.MustParseAddr("2001:db8:1:2:ffff::1%eth0")) {
		t.Error("third address of the same /64 allowed")
	}
	if !a.allow(netip.MustParseAddr("2001:db8:1:3::1")) {
		t.Error("another /64 refused")
	}
}

func TestAttemptsBoundMemory(t *testing.T) {
	clock := newClock()
	a := newAttempts(10, time.Minute, 3, clock.now)
	for i := range 3 {
		if !a.allow(netip.AddrFrom4([4]byte{198, 51, 100, byte(i)})) {
			t.Fatal("refused under the bound")
		}
	}
	if a.allow(netip.MustParseAddr("198.51.100.99")) {
		t.Error("new address accepted past the bound")
	}
	if !a.allow(netip.AddrFrom4([4]byte{198, 51, 100, 0})) {
		t.Error("known address refused past the bound")
	}
	clock.add(time.Minute) // all out of the window: swept
	if !a.allow(netip.MustParseAddr("198.51.100.99")) {
		t.Error("new address refused after the sweep")
	}
	if n := len(a.seen); n != 1 {
		t.Errorf("%d addresses kept after the sweep", n)
	}
}
