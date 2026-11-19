package logbuf

import (
	"fmt"
	"testing"
)

func TestBufferKeepsMostRecentLines(t *testing.T) {
	buf := New(3)
	for i := 1; i <= 5; i++ {
		fmt.Fprintf(buf, "line %d\n", i)
	}
	got := buf.Lines()
	want := []string{"line 3", "line 4", "line 5"}
	if len(got) != len(want) {
		t.Fatalf("Lines() = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Lines()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestBufferHoldsBackPartialLine(t *testing.T) {
	buf := New(10)
	fmt.Fprint(buf, "first")
	if got := buf.Lines(); len(got) != 0 {
		t.Fatalf("partial line was exposed: %q", got)
	}
	fmt.Fprint(buf, " second\nthird\n")
	want := []string{"first second", "third"}
	got := buf.Lines()
	if len(got) != len(want) {
		t.Fatalf("Lines() = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("Lines()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestLinesReturnsACopy(t *testing.T) {
	buf := New(10)
	fmt.Fprint(buf, "one\n")
	lines := buf.Lines()
	lines[0] = "changed"
	if got := buf.Lines(); got[0] != "one" {
		t.Fatalf("mutating the returned slice changed the buffer: %q", got)
	}
}
