package volume

import (
	"runtime"
	"testing"
)

func TestListReturnsSaneVolumes(t *testing.T) {
	vols, err := List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if !testing.Short() && runtime.GOOS == "windows" && len(vols) == 0 {
		t.Fatal("List returned no volumes on Windows")
	}

	for _, vol := range vols {
		if vol.Name == "" {
			t.Errorf("volume with empty name: %+v", vol)
		}
		if vol.Path == "" {
			t.Errorf("volume %q has empty path", vol.Name)
		}
		if vol.Total > 0 && vol.Free > vol.Total {
			t.Errorf("volume %q reports free %d > total %d", vol.Name, vol.Free, vol.Total)
		}
	}
}

func TestListIsSortedFixedFirst(t *testing.T) {
	vols := []Volume{
		{Name: "Z:", Network: true},
		{Name: "E:", Removable: true},
		{Name: "D:"},
		{Name: "C:"},
	}
	sortVolumes(vols)

	want := []string{"C:", "D:", "E:", "Z:"}
	for i, name := range want {
		if vols[i].Name != name {
			t.Fatalf("position %d = %q, want %q (order: %v)", i, vols[i].Name, name, names(vols))
		}
	}
}

func names(vols []Volume) []string {
	out := make([]string, len(vols))
	for i, vol := range vols {
		out[i] = vol.Name
	}
	return out
}

func TestFindMatchesExactlyThenCaseInsensitively(t *testing.T) {
	vols := []Volume{
		{Name: "C:", Path: `C:\`},
		{Name: "E:", Path: `E:\`},
		{Name: "/Volumes/Data", Path: "/Volumes/Data/"},
	}

	if v, ok := Find(vols, "E:"); !ok || v.Path != `E:\` {
		t.Fatalf("exact match = %+v, %v", v, ok)
	}
	// Windows drive letters are case-insensitive: the phone may echo back "e:".
	if v, ok := Find(vols, "e:"); !ok || v.Path != `E:\` {
		t.Fatalf("case-insensitive match = %+v, %v", v, ok)
	}
	if _, ok := Find(vols, "Z:"); ok {
		t.Fatal("Find matched a volume that does not exist")
	}
	if _, ok := Find(vols, "  "); ok {
		t.Fatal("Find matched the empty name")
	}
}
