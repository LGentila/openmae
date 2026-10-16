package relay

import "sync"

// hub holds the relay's whole state, in memory: which Mac is registered on
// which control connection, and the tubes being set up.
type hub struct {
	mu          sync.Mutex
	macs        map[string]*registration // by device id
	tubes       map[string]int           // open and pending tubes, by Mac device id
	pending     map[token]*pendingTube
	tubesPerMac int
	maxPending  int
}

type registration struct {
	id string
	c  conn
}

// pendingTube is an iPhone waiting for its Mac's accept.
type pendingTube struct {
	token    token
	mac      string
	accepted chan conn     // receives the Mac's tube connection; buffered, written once
	done     chan struct{} // closed when the tube is over
}

func newHub(tubesPerMac, maxPending int) *hub {
	return &hub{
		macs:        make(map[string]*registration),
		tubes:       make(map[string]int),
		pending:     make(map[token]*pendingTube),
		tubesPerMac: tubesPerMac,
		maxPending:  maxPending,
	}
}

// register makes r the Mac's registration and returns the one it replaces,
// whose connection the caller closes.
func (h *hub) register(r *registration) *registration {
	h.mu.Lock()
	defer h.mu.Unlock()
	old := h.macs[r.id]
	h.macs[r.id] = r
	return old
}

func (h *hub) unregister(r *registration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.macs[r.id] == r {
		delete(h.macs, r.id)
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
	for {
		p.token = newToken()
		if _, taken := h.pending[p.token]; !taken {
			break
		}
	}
	h.pending[p.token] = p
	h.tubes[mac]++
	return p, r, ""
}

// claim hands the Mac's tube connection c to the iPhone waiting on t.
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
	if h.tubes[p.mac]--; h.tubes[p.mac] <= 0 {
		delete(h.tubes, p.mac)
	}
}

func (h *hub) counts() (macs, pending int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.macs), len(h.pending)
}
