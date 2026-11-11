package tests

import (
	"net/http"
	"net/http/cgi"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
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
		"scripts/bootstrap-common.sh",
		"scripts/bootstrap-orbstack.sh",
		"scripts/bootstrap-linux.sh",
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

	// Verify bootstrap scripts do not hardcode sample microservices.
	for _, rel := range []string{
		"scripts/bootstrap-common.sh",
		"scripts/bootstrap-orbstack.sh",
		"scripts/bootstrap-linux.sh",
	} {
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("failed to read %s: %v", rel, err)
		}
		text := string(data)
		for _, coupled := range []string{"orders", "inventory", "payments"} {
			if strings.Contains(text, coupled) {
				t.Fatalf("%s still references coupled sample app %q", rel, coupled)
			}
		}
	}
}

func TestAnsiblePlaybookCoversPrerequisites(t *testing.T) {
	root := repoRoot(t)

	for _, rel := range []string{"ansible/playbook.yml", "ansible/inventory.ini"} {
		if _, err := os.Stat(filepath.Join(root, rel)); err != nil {
			t.Fatalf("expected %s to exist: %v", rel, err)
		}
	}

	data, err := os.ReadFile(filepath.Join(root, "ansible", "playbook.yml"))
	if err != nil {
		t.Fatalf("failed to read ansible/playbook.yml: %v", err)
	}
	playbook := string(data)

	// Every CLI binary required by preflight_check() in bootstrap-common.sh must be covered.
	requiredTools := []string{
		"docker", "kind", "kubectl", "kustomize", "helm",
		"argocd", "jq", "skopeo", "git", "curl",
	}
	for _, tool := range requiredTools {
		if !strings.Contains(playbook, tool) {
			t.Errorf("ansible/playbook.yml does not reference required prerequisite %q", tool)
		}
	}

	// Verify multi-cluster inotify sysctl and insecure-registry configuration are present.
	for _, setting := range []string{
		"fs.inotify.max_user_watches",
		"fs.inotify.max_user_instances",
		"harbor.orb.local:8085",
		"gitea.orb.local",
	} {
		if !strings.Contains(playbook, setting) {
			t.Errorf("ansible/playbook.yml missing expected host setting %q", setting)
		}
	}

	// If uv is installed, run ansible-playbook --syntax-check via uv.
	if _, err := exec.LookPath("uv"); err == nil {
		cmd := exec.Command(
			"uv", "run", "--with", "ansible-core",
			"ansible-playbook", "--syntax-check",
			"-i", filepath.Join(root, "ansible", "inventory.ini"),
			filepath.Join(root, "ansible", "playbook.yml"),
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("uv run --with ansible-core ansible-playbook --syntax-check failed: %v\n%s", err, string(out))
		}
	}
}

func TestRuntimeIsolationAndLimaSpec(t *testing.T) {
	root := repoRoot(t)

	for _, rel := range []string{"scripts/bootstrap-common.sh", "scripts/nuke-lab.sh"} {
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("failed to read %s: %v", rel, err)
		}
		text := string(data)
		if !strings.Contains(text, "LAB_RUNTIME_DIR") || !strings.Contains(text, ".local/share}/local-lab") {
			t.Errorf("%s should isolate Linux runtime state from macOS .lab-runtime", rel)
		}
	}

	commonBytes, err := os.ReadFile(filepath.Join(root, "scripts", "bootstrap-common.sh"))
	if err != nil {
		t.Fatalf("failed to read bootstrap-common.sh: %v", err)
	}
	common := string(commonBytes)
	if !strings.Contains(common, `--kubeconfig "${TMP_KUBECONFIG}"`) {
		t.Errorf("bootstrap-common.sh should use a temporary kubeconfig when registering internal Docker IPs in Argo CD")
	}

	beelinkBytes, err := os.ReadFile(filepath.Join(root, "beelink.yaml"))
	if err != nil {
		t.Fatalf("failed to read beelink.yaml: %v", err)
	}
	beelink := string(beelinkBytes)
	if strings.Contains(beelink, `eval echo "~$(ls /home`) {
		t.Errorf("beelink.yaml must not use ~<dir> tilde expansion for Lima .guest home directories")
	}
	if !strings.Contains(beelink, "rosetta:") || !strings.Contains(beelink, "enabled: true") {
		t.Errorf("beelink.yaml must keep Rosetta enabled for Harbor linux/amd64 images")
	}
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=Test User",
		"GIT_AUTHOR_EMAIL=test@local.lab",
		"GIT_COMMITTER_NAME=Test User",
		"GIT_COMMITTER_EMAIL=test@local.lab",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, string(out))
	}
	return strings.TrimSpace(string(out))
}

func TestOnboardRepoIdempotentAndPreservesRemotes(t *testing.T) {
	root := repoRoot(t)
	gitExecOut, err := exec.Command("git", "--exec-path").Output()
	if err != nil {
		t.Skip("git not available")
	}
	httpBackend := filepath.Join(strings.TrimSpace(string(gitExecOut)), "git-http-backend")
	if _, err := os.Stat(httpBackend); err != nil {
		t.Skipf("git-http-backend not found at %s", httpBackend)
	}

	tmpDir := t.TempDir()
	remoteRoot := filepath.Join(tmpDir, "gitea-remotes")
	bareRepo := filepath.Join(remoteRoot, "platform", "sample-app.git")

	var mu sync.Mutex
	repoCreated := false
	prodProtected := false
	patchCount := 0

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		switch {
		case r.URL.Path == "/api/v1/version":
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"version":"1.22.0"}`))
			return

		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/repos/platform/sample-app":
			exists := repoCreated
			mu.Unlock()
			if exists {
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"name":"sample-app"}`))
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
			return

		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/user/repos":
			if err := os.MkdirAll(bareRepo, 0755); err != nil {
				mu.Unlock()
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			runGit(t, bareRepo, "init", "--bare")
			runGit(t, bareRepo, "config", "http.receivepack", "true")
			// Install pre-receive hook enforcing prod branch protection once marker exists.
			hookPath := filepath.Join(bareRepo, "hooks", "pre-receive")
			hookScript := "#!/usr/bin/env bash\nwhile read oldrev newrev refname; do\n  if [ \"$refname\" = \"refs/heads/prod\" ] && [ -f \"" + filepath.Join(bareRepo, "prod-protected") + "\" ]; then\n    echo \"prod branch is protected\" >&2\n    exit 1\n  fi\ndone\n"
			if err := os.WriteFile(hookPath, []byte(hookScript), 0755); err != nil {
				mu.Unlock()
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			repoCreated = true
			mu.Unlock()
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"name":"sample-app"}`))
			return

		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/repos/platform/sample-app/branch_protections/prod":
			protected := prodProtected
			mu.Unlock()
			if protected {
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"branch_name":"prod"}`))
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
			return

		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/repos/platform/sample-app/branch_protections":
			_ = os.WriteFile(filepath.Join(bareRepo, "prod-protected"), []byte("1"), 0644)
			prodProtected = true
			mu.Unlock()
			w.WriteHeader(http.StatusCreated)
			return

		case r.Method == http.MethodPatch && r.URL.Path == "/api/v1/repos/platform/sample-app/branch_protections/prod":
			patchCount++
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
			return
		}
		mu.Unlock()

		// Delegate Git smart-HTTP traffic to git-http-backend.
		handler := &cgi.Handler{
			Path: httpBackend,
			Env: []string{
				"GIT_PROJECT_ROOT=" + remoteRoot,
				"GIT_HTTP_EXPORT_ALL=1",
			},
		}
		handler.ServeHTTP(w, r)
	}))
	defer srv.Close()

	// Create local workload repository with a non-GitHub origin (GitLab URL).
	workRepo := filepath.Join(tmpDir, "sample-app")
	if err := os.MkdirAll(workRepo, 0755); err != nil {
		t.Fatal(err)
	}
	runGit(t, workRepo, "init", "-b", "main")
	if err := os.WriteFile(filepath.Join(workRepo, "README.md"), []byte("v1\n"), 0644); err != nil {
		t.Fatal(err)
	}
	runGit(t, workRepo, "add", "README.md")
	runGit(t, workRepo, "commit", "-m", "initial commit")
	initialSHA := runGit(t, workRepo, "rev-parse", "HEAD")
	upstreamURL := "https://gitlab.example.com/team/sample-app.git"
	runGit(t, workRepo, "remote", "add", "origin", upstreamURL)

	onboardScript := filepath.Join(root, "scripts", "onboard-repo.sh")
	runOnboard := func() {
		t.Helper()
		cmd := exec.Command(onboardScript, workRepo)
		cmd.Env = append(os.Environ(), "GITEA_URL="+srv.URL)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("onboard-repo.sh failed: %v\n%s", err, string(out))
		}
	}

	// 1st run: preserves non-GitHub origin as 'seed' (push DISABLED), pushes main/dev/prod, enables prod protection.
	runOnboard()

	if got := runGit(t, workRepo, "remote", "get-url", "seed"); got != upstreamURL {
		t.Fatalf("expected seed fetch URL %q, got %q", upstreamURL, got)
	}
	if got := runGit(t, workRepo, "remote", "get-url", "--push", "seed"); got != "DISABLED" {
		t.Fatalf("expected seed push URL DISABLED, got %q", got)
	}

	// Advance 'dev' with a new commit so dev and prod diverge, then switch back to main.
	runGit(t, workRepo, "checkout", "dev")
	if err := os.WriteFile(filepath.Join(workRepo, "README.md"), []byte("v2-dev\n"), 0644); err != nil {
		t.Fatal(err)
	}
	runGit(t, workRepo, "commit", "-am", "dev feature")
	devSHA := runGit(t, workRepo, "rev-parse", "HEAD")
	runGit(t, workRepo, "checkout", "main")

	// 2nd run: must NOT clobber diverged local dev/prod branches, must NOT fail against protected prod, and must PATCH protection.
	runOnboard()

	if got := runGit(t, workRepo, "rev-parse", "dev"); got != devSHA {
		t.Fatalf("expected local dev branch to stay at %s, got %s", devSHA, got)
	}
	if got := runGit(t, workRepo, "rev-parse", "prod"); got != initialSHA {
		t.Fatalf("expected local prod branch to stay at %s, got %s", initialSHA, got)
	}
	if got := runGit(t, bareRepo, "rev-parse", "refs/heads/dev"); got != devSHA {
		t.Fatalf("expected remote dev branch to advance to %s, got %s", devSHA, got)
	}
	if got := runGit(t, bareRepo, "rev-parse", "refs/heads/prod"); got != initialSHA {
		t.Fatalf("expected remote protected prod branch to remain at %s, got %s", initialSHA, got)
	}
	mu.Lock()
	gotPatches := patchCount
	mu.Unlock()
	if gotPatches != 1 {
		t.Fatalf("expected 1 PATCH to branch_protections/prod on second run, got %d", gotPatches)
	}
}
