package relay

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

func TestQUICIdentityIsKept(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "data")
	now := time.Now()
	key, cert, err := loadQUICIdentity(dir, now, quiet)
	if err != nil {
		t.Fatal(err)
	}
	pin := spkiPin(cert.Leaf)

	// The pin is the SHA-256 of the DER SubjectPublicKeyInfo.
	spki, _ := x509.MarshalPKIXPublicKey(key.Public())
	sum := sha256.Sum256(spki)
	if pin != base64.StdEncoding.EncodeToString(sum[:]) {
		t.Error("pin is not the SHA-256 of the SubjectPublicKeyInfo")
	}
	if cert.Leaf.PublicKeyAlgorithm != x509.ECDSA || key.Curve.Params().Name != "P-256" {
		t.Error("not ECDSA P-256")
	}
	if info, err := os.Stat(filepath.Join(dir, quicKeyFile)); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("key file: %v %v", info.Mode(), err)
	}

	// Reused at the next start.
	_, again, err := loadQUICIdentity(dir, now.Add(time.Hour), quiet)
	if err != nil {
		t.Fatal(err)
	}
	if !again.Leaf.Equal(cert.Leaf) {
		t.Error("certificate not reused")
	}

	// A lost or old certificate is made again from the key: same pin.
	if err := os.Remove(filepath.Join(dir, quicCertFile)); err != nil {
		t.Fatal(err)
	}
	_, remade, err := loadQUICIdentity(dir, now, quiet)
	if err != nil || remade.Leaf.Equal(cert.Leaf) || spkiPin(remade.Leaf) != pin {
		t.Errorf("certificate not remade with the same key: %v", err)
	}
	_, renewed, err := loadQUICIdentity(dir, now.Add(certValidity-certRenewal/2), quiet)
	if err != nil || renewed.Leaf.Equal(remade.Leaf) || spkiPin(renewed.Leaf) != pin {
		t.Errorf("certificate near its end not renewed: %v", err)
	}
}

func TestQUICIdentityRefusesABrokenKey(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, quicKeyFile), []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Making a new key would silently change the pin.
	if _, _, err := loadQUICIdentity(dir, time.Now(), quiet); err == nil {
		t.Error("broken key file accepted")
	}
}

func TestQUICIdentityReplacesACertificateForAnotherKey(t *testing.T) {
	dirA, dirB := t.TempDir(), t.TempDir()
	_, certA, _ := loadQUICIdentity(dirA, time.Now(), quiet)
	_, certB, _ := loadQUICIdentity(dirB, time.Now(), quiet)
	data, _ := os.ReadFile(filepath.Join(dirB, quicCertFile))
	if err := os.WriteFile(filepath.Join(dirA, quicCertFile), data, 0o644); err != nil {
		t.Fatal(err)
	}
	key, cert, err := loadQUICIdentity(dirA, time.Now(), quiet)
	if err != nil || cert.Leaf.Equal(certB.Leaf) || spkiPin(cert.Leaf) != spkiPin(certA.Leaf) {
		t.Errorf("certificate of another key used: %v", err)
	}
	if !cert.Leaf.PublicKey.(*ecdsa.PublicKey).Equal(key.Public()) {
		t.Error("certificate and key differ")
	}
}

func TestPinList(t *testing.T) {
	cur := "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	old := "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="
	pins, err := pinList(cur, []string{old, " " + old, cur, ""})
	if err != nil || len(pins) != 2 || pins[0] != cur || pins[1] != old {
		t.Errorf("pinList = %v, %v", pins, err)
	}
	for _, bad := range []string{"abc", base64.StdEncoding.EncodeToString(make([]byte, 31)), base64.RawStdEncoding.EncodeToString(make([]byte, 32))} {
		if _, err := pinList(cur, []string{bad}); err == nil {
			t.Errorf("pin %q accepted", bad)
		}
	}
}

func TestStatelessResetKeyIsStable(t *testing.T) {
	dir := t.TempDir()
	key1, _, _ := loadQUICIdentity(dir, time.Now(), quiet)
	key2, _, _ := loadQUICIdentity(dir, time.Now(), quiet)
	k1, _ := statelessResetKey(key1)
	k2, _ := statelessResetKey(key2)
	if *k1 != *k2 {
		t.Error("stateless reset key changes across restarts")
	}
}
