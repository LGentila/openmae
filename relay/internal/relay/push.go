package relay

import "context"

// Pusher would let a relay wake an iPhone with a push notification. Only a
// relay holding the app's APNs key can do that, so no implementation ships
// here: Config.Pusher stays nil and /v1/info says "push": false. The control
// messages that would use it are not part of openmae-relay/1 yet.
type Pusher interface {
	// Push sends payload, already encrypted end to end by the Mac, to the
	// iPhone app registered under deviceToken.
	Push(ctx context.Context, deviceToken string, payload []byte) error
}
