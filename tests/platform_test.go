package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(thisFile))
}

func TestPlatformScriptsSyntaxAndExecutable(t *testing.T) {
	root := repoRoot(t)
	scripts := []string{
		"scripts/bootstrap-lab.sh",
		"scripts/onboard-repo.sh",
		"scripts/nuke-lab.sh",
	}

	for _, rel := range scripts {
		t.Run(rel, func(t *testing.T) {
			full := filepath.Join(root, rel)
			info, err := os.Stat(full)
			if err != nil {
				t.Fatalf("missing script %s: %v", rel, err)
			}
			if info.Mode()&0111 == 0 {
				t.Fatalf("expected %s to be executable (mode %o)", rel, info.Mode())
			}

			cmd := exec.Command("bash", "-n", full)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("bash -n %s failed: %v\n%s", rel, err, string(out))
			}
		})
	}
}

func TestPlatformRepoIsAppAgnostic(t *testing.T) {
	root := repoRoot(t)

	// Verify application-specific directories are no longer coupled into the platform repo.
	for _, forbidden := range []string{"k8s", "argocd", ".gitea"} {
		if _, err := os.Stat(filepath.Join(root, forbidden)); !os.IsNotExist(err) {
			t.Fatalf("expected %q to be absent from app-agnostic platform repo", forbidden)
		}
	}

	// Verify bootstrap-lab.sh does not hardcode sample microservices.
	data, err := os.ReadFile(filepath.Join(root, "scripts", "bootstrap-lab.sh"))
	if err != nil {
		t.Fatalf("failed to read bootstrap-lab.sh: %v", err)
	}
	text := string(data)
	for _, coupled := range []string{"orders", "inventory", "payments"} {
		if strings.Contains(text, coupled) {
			t.Fatalf("bootstrap-lab.sh still references coupled sample app %q", coupled)
		}
	}
}
