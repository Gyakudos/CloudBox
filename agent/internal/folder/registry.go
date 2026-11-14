package folder

import (
	"fmt"
	"sort"
	"sync"
)

// Registry maps the folder IDs a phone knows to the finalizers that write them.
//
// The phone never sends a raw filesystem path when it creates an upload; it sends a folder ID
// that the user configured during setup. The mapping from ID to an absolute, user-chosen path
// lives here and nowhere else, so a client cannot name an arbitrary location to write to.
type Registry struct {
	mu      sync.RWMutex
	folders map[string]*Finalizer
	names   map[string]string
	ordered []string
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		folders: make(map[string]*Finalizer),
		names:   make(map[string]string),
	}
}

// Register binds id to a finalizer. Re-registering the same ID replaces it, which is what a
// settings change should do.
func (r *Registry) Register(id, name string, f *Finalizer) error {
	if id == "" {
		return fmt.Errorf("folder: id must not be empty")
	}
	if f == nil {
		return fmt.Errorf("folder: finalizer must not be nil")
	}
	if name == "" {
		name = id
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.folders[id]; !exists {
		r.ordered = append(r.ordered, id)
	}
	r.folders[id] = f
	r.names[id] = name
	return nil
}

// Get returns the finalizer registered for id.
func (r *Registry) Get(id string) (*Finalizer, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	f, ok := r.folders[id]
	return f, ok
}

// Folder is a summary of one configured sync folder.
type Folder struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Root string `json:"root"`
}

// List returns the registered folders in registration order.
func (r *Registry) List() []Folder {
	r.mu.RLock()
	defer r.mu.RUnlock()

	out := make([]Folder, 0, len(r.ordered))
	for _, id := range r.ordered {
		out = append(out, Folder{ID: id, Name: r.names[id], Root: r.folders[id].Root})
	}
	return out
}

// IDs returns the registered folder IDs, sorted, for deterministic messages.
func (r *Registry) IDs() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.folders))
	for id := range r.folders {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}
