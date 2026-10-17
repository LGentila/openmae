package relay

import "sync"

// hub holds the relay's whole state, in memory: which Mac is registered on
// which control connection, and the tubes being set up.
type hub struct {
	mu          sync.Mutex
	macs        map[string]*registration // by device id
	inbound     map[string]*registration // registrations for deliveries (home mode), by inbound name
	tubes       map[string]int           // iPhones' open and pending tubes, by Mac device id
	pending     map[token]*pendingTube
	tubesPerMac int
	maxPending  int
}

type registration struct {
	id      string // device id, or inbound name for an inbound registration
	inbound bool   // gets deliveries instead of iPhones
	c       conn
}

// pendingTube is an iPhone, or a delivery, waiting for its Mac's accept.
type pendingTube struct {
	token    token
	mac      string        // device id, or inbound name for a delivery
	delivery bool          // not counted against tubesPerMac, which is for iPhones
	accepted chan conn     // receives the Mac's tube connection; buffered, written once
	done     chan struct{} // closed when the tube is over
}

func newHub(tubesPerMac, maxPending int) *hub {
	return &hub{
		macs:        make(map[string]*registration),
		inbound:     make(map[string]*registration),
		tubes:       make(map[string]int),
		pending:     make(map[token]*pendingTube),
		tubesPerMac: tubesPerMac,
		maxPending:  maxPending,
	}
}

// registrations is where r belongs: a Mac's ordinary registration and its
// inbound one are kept apart, and neither replaces the other.
func (h *hub) registrations(r *registration) map[string]*registration {
	if r.inbound {
		return h.inbound
	}
	return h.macs
}

// register makes r the Mac's registration (of its kind) and returns the one
// it replaces, whose connection the caller closes.
func (h *hub) register(r *registration) *registration {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.registrations(r)
	old := m[r.id]
	m[r.id] = r
	return old
}

func (h *hub) unregister(r *registration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if m := h.registrations(r); m[r.id] == r {
		delete(m, r.id)
	}
}

// open starts a tube to a Mac. On success the caller must call release once
// the tube is over, whatever happens.
func (h *hub) open(mac string) (*pendingTube, *registration, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.macs[mac]
	switch {
	case r == nil:
		return nil, nil, codeMacOffline
	case h.tubes[mac] >= h.tubesPerMac, len(h.pending) >= h.maxPending:
		return nil, nil, codeBusy
	}
	p := &pendingTube{mac: mac, accepted: make(chan conn, 1), done: make(chan struct{})}
	h.addPending(p)
	h.tubes[mac]++
	return p, r, ""
}

// openInbound starts a delivery's tube to the Mac registered for deliveries
// under name. It counts against the pending tubes only. On success the
// caller must call release once the delivery is over, whatever happens.
func (h *hub) openInbound(name string) (*pendingTube, *registration, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.inbound[name]
	switch {
	case r == nil:
		return nil, nil, codeMacOffline
	case len(h.pending) >= h.maxPending:
		return nil, nil, codeBusy
	}
	p := &pendingTube{mac: name, delivery: true, accepted: make(chan conn, 1), done: make(chan struct{})}
	h.addPending(p)
	return p, r, ""
}

// addPending gives p a fresh token and lets the Mac claim it. h.mu is held.
func (h *hub) addPending(p *pendingTube) {
	for {
		p.token = newToken()
		if _, taken := h.pending[p.token]; !taken {
			break
		}
	}
	h.pending[p.token] = p
}

// inboundRegistered reports whether a Mac is registered for deliveries
// under name.
func (h *hub) inboundRegistered(name string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.inbound[name] != nil
}

// claim hands the Mac's tube connection c to the iPhone, or the delivery,
// waiting on t.
func (h *hub) claim(t token, c conn) *pendingTube {
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.pending[t]
	if p != nil {
		delete(h.pending, t)
		p.accepted <- c
	}
	return p
}

// withdraw stops waiting for an accept. It returns false if the Mac's
// connection was claimed meanwhile and is in p.accepted.
func (h *hub) withdraw(p *pendingTube) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.pending[p.token] != p {
		return false
	}
	delete(h.pending, p.token)
	return true
}

func (h *hub) release(p *pendingTube) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.pending[p.token] == p {
		delete(h.pending, p.token)
	}
	if p.delivery {
		return
	}
	if h.tubes[p.mac]--; h.tubes[p.mac] <= 0 {
		delete(h.tubes, p.mac)
	}
}

func (h *hub) counts() (macs, inbound, pending int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.macs), len(h.inbound), len(h.pending)
}
