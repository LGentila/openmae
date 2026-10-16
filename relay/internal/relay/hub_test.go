package relay

import "testing"

func TestHub(t *testing.T) {
	h := newHub(2, 3)
	if _, _, code := h.open("mac"); code != codeMacOffline {
		t.Fatalf("unregistered Mac: %q", code)
	}
	first := &registration{id: "mac"}
	h.register(first)
	second := &registration{id: "mac"}
	if old := h.register(second); old != first {
		t.Fatal("registration not replaced")
	}
	h.unregister(first) // the old connection closing must not remove the new one
	if _, reg, code := h.open("mac"); code != "" || reg != second {
		t.Fatalf("open: %q", code)
	}

	// The tube opened above is pending: one more, then busy.
	p, _, _ := h.open("mac")
	if _, _, code := h.open("mac"); code != codeBusy {
		t.Fatalf("third tube: %q", code)
	}
	if h.claim(newToken(), nil) != nil {
		t.Error("claimed an unknown token")
	}
	if h.claim(p.token, nil) != p || h.claim(p.token, nil) != nil {
		t.Error("a token must be claimed once")
	}
	if h.withdraw(p) {
		t.Error("withdrew a claimed tube")
	}
	h.release(p)
	if tubesOf(h, "mac") != 1 {
		t.Errorf("%d tubes after a release", tubesOf(h, "mac"))
	}

	// The global bound on pending tubes.
	for _, id := range []string{"b", "c"} {
		h.register(&registration{id: id})
		if _, _, code := h.open(id); code != "" {
			t.Fatal(code)
		}
	}
	h.register(&registration{id: "d"})
	if _, _, code := h.open("d"); code != codeBusy {
		t.Errorf("past the pending bound: %q", code)
	}
}
