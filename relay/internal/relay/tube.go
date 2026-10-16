package relay

import (
	"context"
	"time"
)

// runTube copies each side's bytes and datagrams to the other until one
// side closes, then closes the other. It calls release once the tube stops
// carrying anything, so that a closing tube no longer counts against the
// Mac's limit.
func (s *Server) runTube(phone, mac conn, release func()) {
	s.tubesOpen.Add(1)
	defer s.tubesOpen.Add(-1)
	s.log.Info("tube opened", "iphone", phone.transport(), "mac", mac.transport())

	act := newActivity()
	rate, burst := float64(s.lim.BytesPerSecond), float64(s.lim.BurstBytes)
	up := &flow{budget: newBucket(rate, burst, nil), activity: act}
	down := &flow{budget: newBucket(rate, burst, nil), activity: act}

	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	ended := make(chan error, 2)
	go func() { ended <- phone.forward(ctx, mac, up) }()
	go func() { ended <- mac.forward(ctx, phone, down) }()

	reason, running := s.watchTube(ended, act)
	release()

	// Everything one side sent before closing has been written to the other
	// side: close its write direction behind it, and give the client a
	// moment to read it all and close on its side.
	cancel()
	deadline := time.Now().Add(s.lim.Linger)
	force := time.AfterFunc(s.lim.Linger, func() {
		phone.closeNow()
		mac.closeNow()
	})
	phone.closeWrite(deadline)
	mac.closeWrite(deadline)
	for ; running > 0; running-- {
		<-ended
	}
	phone.drain(deadline)
	mac.drain(deadline)
	force.Stop()
	phone.closeNow()
	mac.closeNow()

	s.log.Info("tube closed",
		"reason", reason,
		"seconds", int(time.Since(act.start).Round(time.Second).Seconds()),
		"up_bytes", up.bytes.Load(), "up_datagrams", up.datagrams.Load(), "up_dropped", up.dropped.Load(),
		"down_bytes", down.bytes.Load(), "down_datagrams", down.datagrams.Load(), "down_dropped", down.dropped.Load())
}

// watchTube waits for a side to stop, the tube to go idle, or shutdown, and
// returns why and how many sides are still forwarding.
func (s *Server) watchTube(ended <-chan error, act *activity) (string, int) {
	tick := time.NewTicker(max(min(s.lim.TubeIdle/4, 5*time.Second), time.Millisecond))
	defer tick.Stop()
	for {
		select {
		case err := <-ended:
			return errKind(err), 1
		case <-s.ctx.Done():
			return "shutdown", 2
		case <-tick.C:
			if act.idleFor() >= s.lim.TubeIdle {
				return "idle", 2
			}
		}
	}
}
