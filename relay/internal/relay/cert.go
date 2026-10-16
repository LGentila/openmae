package relay

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The QUIC certificate is self-signed: clients accept it because its key
// matches a pin from /v1/info, which they fetch over HTTPS. The pin depends
// on the key alone, so the key file is what must be kept; the certificate
// can be made again from it at any time without changing the pin.
const (
	quicKeyFile  = "quic-key.pem"
	quicCertFile = "quic-cert.pem"

	certValidity = 10 * 365 * 24 * time.Hour
	certRenewal  = 365 * 24 * time.Hour // remake the certificate when less is left
)

// loadQUICIdentity loads the QUIC key and certificate from dir, creating
// them on first start.
func loadQUICIdentity(dir string, now time.Time, log *slog.Logger) (*ecdsa.PrivateKey, tls.Certificate, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, tls.Certificate{}, fmt.Errorf("data directory: %w", err)
	}
	key, err := loadOrCreateKey(filepath.Join(dir, quicKeyFile))
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	certPath := filepath.Join(dir, quicCertFile)
	leaf, err := loadCert(certPath, key, now)
	if err != nil {
		if leaf, err = newCert(key, now); err != nil {
			return nil, tls.Certificate{}, err
		}
		pemCert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})
		if err := writeFileAtomic(certPath, pemCert, 0o644); err != nil {
			// Not fatal: the pin comes from the key, which is safe on disk.
			log.Warn("could not save the QUIC certificate", "err", err)
		}
	}
	return key, tls.Certificate{Certificate: [][]byte{leaf.Raw}, PrivateKey: key, Leaf: leaf}, nil
}

func loadOrCreateKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, err
		}
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return nil, err
		}
		if err := writeFileAtomic(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
			// Without the key on disk, the pin would change at every start.
			return nil, fmt.Errorf("saving the QUIC key: %w", err)
		}
		return key, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the QUIC key: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("%s: no PEM block", path)
	}
	var parsed any
	switch block.Type {
	case "PRIVATE KEY":
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
	case "EC PRIVATE KEY":
		parsed, err = x509.ParseECPrivateKey(block.Bytes)
	default:
		err = fmt.Errorf("unexpected PEM block %q", block.Type)
	}
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("%s: not an ECDSA P-256 key", path)
	}
	return key, nil
}

// loadCert returns the saved certificate if it is for key and not close to
// its end.
func loadCert(path string, key *ecdsa.PrivateKey, now time.Time) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("no certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
	if !ok || !pub.Equal(key.Public()) {
		return nil, errors.New("certificate for another key")
	}
	if now.Add(certRenewal).After(cert.NotAfter) {
		return nil, errors.New("certificate near its end")
	}
	return cert, nil
}

func newCert(key *ecdsa.PrivateKey, now time.Time) (*x509.Certificate, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "openmae-relay"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(certValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

// spkiPin is the SHA-256 of the DER SubjectPublicKeyInfo, in standard base64.
func spkiPin(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(sum[:])
}

// pinList puts the current pin first, then the previous ones, checked and
// without repeats.
func pinList(current string, previous []string) ([]string, error) {
	pins := []string{current}
	for _, p := range previous {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if b, err := base64.StdEncoding.DecodeString(p); err != nil || len(b) != sha256.Size {
			return nil, fmt.Errorf("previous pin %q is not the standard base64 of a SHA-256", p)
		}
		dup := false
		for _, q := range pins {
			dup = dup || q == p
		}
		if !dup {
			pins = append(pins, p)
		}
	}
	return pins, nil
}

// statelessResetKey derives the QUIC stateless reset key from the
// certificate key, so that it survives restarts without another file: after
// a crash, clients still holding a connection learn at once that it is gone.
func statelessResetKey(key *ecdsa.PrivateKey) (*[32]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	mac := hmac.New(sha256.New, der)
	mac.Write([]byte("openmae-relay stateless reset"))
	var k [32]byte
	copy(k[:], mac.Sum(nil))
	return &k, nil
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // no-op once renamed
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
