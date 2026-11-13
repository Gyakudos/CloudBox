package devices

import "testing"

func TestCreateAndAuthenticate(t *testing.T) {
	store := NewStore()

	device, token, err := store.Create("Pixel 8", "android", "test-version")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if device.ID == "" || device.Name != "Pixel 8" || device.Platform != "android" {
		t.Fatalf("unexpected device: %+v", device)
	}
	if token == "" {
		t.Fatal("Create returned an empty token")
	}
	if device.CreatedAt.IsZero() {
		t.Fatal("CreatedAt was not set")
	}

	resolved, ok := store.Authenticate(token)
	if !ok {
		t.Fatal("Authenticate rejected a freshly issued token")
	}
	if resolved.ID != device.ID {
		t.Fatalf("Authenticate returned device %q, want %q", resolved.ID, device.ID)
	}
}

func TestAuthenticateRejectsBadTokens(t *testing.T) {
	store := NewStore()
	if _, _, err := store.Create("Pixel", "android", "v"); err != nil {
		t.Fatalf("Create: %v", err)
	}

	for _, token := range []string{"", "wrong", "  "} {
		if _, ok := store.Authenticate(token); ok {
			t.Errorf("Authenticate(%q) succeeded", token)
		}
	}
}

func TestTokensAreUnique(t *testing.T) {
	store := NewStore()

	seen := make(map[string]bool, 16)
	for i := 0; i < 16; i++ {
		_, token, err := store.Create("phone", "android", "v")
		if err != nil {
			t.Fatalf("Create %d: %v", i, err)
		}
		if seen[token] {
			t.Fatalf("duplicate token: %q", token)
		}
		seen[token] = true
	}
}

func TestRevokeInvalidatesToken(t *testing.T) {
	store := NewStore()

	device, token, err := store.Create("Pixel", "android", "v")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if !store.Revoke(device.ID) {
		t.Fatal("Revoke returned false for a known device")
	}
	if _, ok := store.Authenticate(token); ok {
		t.Fatal("token still authenticates after revoke")
	}
	if store.Revoke(device.ID) {
		t.Fatal("Revoke returned true for an already-revoked device")
	}
	if got := len(store.List()); got != 0 {
		t.Fatalf("List has %d devices after revoke, want 0", got)
	}
}
