// Package logbuf keeps the most recent agent log lines in memory so the PC app can show them
// without a console window or a log file. It satisfies io.Writer, so it can be plugged straight
// into slog's text handler alongside stderr.
package logbuf

import (
	"bytes"
	"strings"
	"sync"
)

// DefaultLimit is enough context for the desktop app without unbounded memory growth.
const DefaultLimit = 200

// Buffer stores the last Limit complete log lines, oldest first.
type Buffer struct {
	mu      sync.Mutex
	lines   []string
	pending []byte
	limit   int
}

// New returns an empty buffer. Non-positive limits use DefaultLimit.
func New(limit int) *Buffer {
	if limit < 1 {
		limit = DefaultLimit
	}
	return &Buffer{limit: limit, lines: make([]string, 0, limit)}
}

// Write records complete lines from p and holds back an unfinished final line until the next
// write. slog writes one newline-terminated record at a time, but the partial-line handling keeps
// Buffer safe for any io.Writer user.
func (b *Buffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	data := make([]byte, 0, len(b.pending)+len(p))
	data = append(data, b.pending...)
	data = append(data, p...)
	b.pending = b.pending[:0]

	for {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			b.pending = append(b.pending, data...)
			break
		}
		b.add(strings.TrimSuffix(string(data[:i]), "\r"))
		data = data[i+1:]
	}
	return len(p), nil
}

// Lines returns a copy of the buffered lines, oldest first.
func (b *Buffer) Lines() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]string, len(b.lines))
	copy(out, b.lines)
	return out
}

func (b *Buffer) add(line string) {
	if line == "" {
		return
	}
	if len(b.lines) == b.limit {
		copy(b.lines, b.lines[1:])
		b.lines[len(b.lines)-1] = line
		return
	}
	b.lines = append(b.lines, line)
}
