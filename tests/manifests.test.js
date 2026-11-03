"use strict";
const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const { ROOT } = require("./helpers");

const hasKubectl = spawnSync("kubectl", ["version", "--client"], { stdio: "ignore" }).status === 0;
const opts = { skip: hasKubectl || process.env.CI ? false : "kubectl not installed" };

const ENVS = {
  dev:  { logLevel: "debug", host: "orders.dev.local",  project: "dev" },
  prod: { logLevel: "info",  host: "orders.prod.local", project: "prod" },
};
const SERVICES = ["orders", "payments", "inventory"];
const render = (dir) => execFileSync("kubectl", ["kustomize", path.join(ROOT, dir)], { encoding: "utf8" });
const docs = (yaml) => yaml.split(/^---$/m).map((d) => d.trim()).filter(Boolean);
const kind = (yaml, k) => docs(yaml).filter((d) => new RegExp(`^kind: ${k}$`, "m").test(d));

describe("overlays render correctly", opts, () => {
  for (const [env, cfg] of Object.entries(ENVS)) {
    for (const svc of SERVICES) {
      describe(`${env}/${svc}`, () => {
        const name = `${svc}-api`;
        const out = render(`k8s/overlays/${env}/${svc}`);

        test("produces Deployment, Service, no Namespace, and HTTPRoute only on orders", () => {
          assert.equal(kind(out, "Deployment").length, 1);
          assert.equal(kind(out, "Service").length, 1);
          assert.equal(kind(out, "Namespace").length, 0, "namespaces come from CreateNamespace=true");
          assert.equal(kind(out, "HTTPRoute").length, svc === "orders" ? 1 : 0);
        });

        test(`is in namespace ${env} and pulls from Harbor '${cfg.project}' project`, () => {
          for (const d of docs(out)) assert.match(d, new RegExp(`^  namespace: ${env}$`, "m"));
          assert.match(kind(out, "Deployment")[0], new RegExp(`image: harbor\\.orb\\.local:8085/${cfg.project}/${name}:\\d+\\.\\d+\\.\\d+$`, "m"));
          assert.match(kind(out, "Deployment")[0], /name: harbor-pull-secret/);
        });

        test("renders the replica count set in the overlay (any positive integer)", () => {
          const overlay = fs.readFileSync(path.join(ROOT, "k8s", "overlays", env, svc, "kustomization.yaml"), "utf8");
          const configured = overlay.match(/^replicas:\n\s+- name: \S+\n\s+count: (\d+)$/m);
          assert.ok(configured, "overlay must set replicas: [{name, count}]");
          const count = Number(configured[1]);
          assert.ok(Number.isInteger(count) && count >= 1, `count must be >= 1, got ${count}`);
          assert.match(kind(out, "Deployment")[0], new RegExp(`^  replicas: ${count}$`, "m"));
        });

        test(`sets LOG_LEVEL=${cfg.logLevel} exactly once`, () => {
          const dep = kind(out, "Deployment")[0];
          assert.equal((dep.match(/name: LOG_LEVEL/g) || []).length, 1);
          assert.match(dep, new RegExp(`name: LOG_LEVEL\\n\\s+value: ${cfg.logLevel}$`, "m"));
        });

        test("Service targetPort matches containerPort and probes (3000, /health)", () => {
          const dep = kind(out, "Deployment")[0];
          const svcDoc = kind(out, "Service")[0];
          assert.match(dep, /containerPort: 3000/);
          assert.match(svcDoc, /targetPort: 3000/);
          assert.match(svcDoc, /port: 80$/m);
          assert.equal((dep.match(/path: \/health/g) || []).length, 2, "readiness + liveness");
          assert.match(dep, /readinessProbe:/);
          assert.match(dep, /livenessProbe:/);
        });

        test("Service selector matches the Deployment labels", () => {
          assert.match(kind(out, "Service")[0], new RegExp(`selector:\\n\\s+app: ${name}`));
          assert.match(kind(out, "Deployment")[0], new RegExp(`matchLabels:\\n\\s+app: ${name}`));
        });

        test("has resource requests and limits and IfNotPresent pull policy", () => {
          const dep = kind(out, "Deployment")[0];
          assert.match(dep, /requests:/);
          assert.match(dep, /limits:/);
          assert.match(dep, /imagePullPolicy: IfNotPresent/);
        });

        if (svc === "orders") {
          test(`HTTPRoute routes hostname ${cfg.host} via platform-gateway`, () => {
            const route = kind(out, "HTTPRoute")[0];
            assert.match(route, new RegExp(`- "?${cfg.host}"?`));
            assert.match(route, /name: platform-gateway/);
          });
        }
      });
    }
  }

  test("orders passes the dependency URLs as relative service names", () => {
    for (const env of Object.keys(ENVS)) {
      const dep = kind(render(`k8s/overlays/${env}/orders`), "Deployment")[0];
      assert.match(dep, /name: INVENTORY_URL\n\s+value: http:\/\/inventory-api$/m);
      assert.match(dep, /name: PAYMENTS_URL\n\s+value: http:\/\/payments-api$/m);
    }
  });

  test("each overlay folder has a Dockerfile and src in its base", () => {
    for (const svc of SERVICES) {
      for (const f of ["Dockerfile", "package.json", "src/server.js", "kustomization.yaml"]) {
        assert.ok(fs.existsSync(path.join(ROOT, "k8s", "base", svc, f)), `base/${svc}/${f}`);
      }
    }
  });

  test("base kustomizations carry no namespace and no images block", () => {
    for (const svc of SERVICES) {
      const k = fs.readFileSync(path.join(ROOT, "k8s", "base", svc, "kustomization.yaml"), "utf8");
      assert.doesNotMatch(k, /^namespace:/m);
      assert.doesNotMatch(k, /^images:/m);
    }
  });
});

describe("tags in overlays are quoted strings (Kustomize rejects numbers)", () => {
  for (const env of Object.keys(ENVS)) {
    for (const svc of SERVICES) {
      test(`${env}/${svc}`, () => {
        const k = fs.readFileSync(path.join(ROOT, "k8s", "overlays", env, svc, "kustomization.yaml"), "utf8");
        assert.match(k, /newTag: "\d+\.\d+\.\d+"/);
      });
    }
  }
});

describe("Multi-Cluster Matrix ApplicationSet", () => {
  const file = path.join(ROOT, "argocd", "microservices-appset.yaml");
  const text = fs.readFileSync(file, "utf8");
  const envs = [...text.matchAll(/- env: (\S+)/g)].map((m) => m[1]);
  const services = [...text.matchAll(/- service: (\S+)/g)].map((m) => m[1]);

  test("covers exactly the environments and services that have overlays", () => {
    assert.deepEqual([...envs].sort(), Object.keys(ENVS).sort());
    assert.deepEqual([...services].sort(), [...SERVICES].sort());
    const onDisk = fs.readdirSync(path.join(ROOT, "k8s", "overlays"));
    assert.deepEqual(onDisk.sort(), [...envs].sort());
    for (const e of envs) {
      assert.deepEqual(fs.readdirSync(path.join(ROOT, "k8s", "overlays", e)).sort(), [...services].sort());
    }
  });

  test("maps dev -> dev-cluster (auto-sync) and prod -> prod-cluster (manual sync)", () => {
    assert.match(text, /env: dev\s+branch: dev\s+clusterName: dev-cluster/);
    assert.match(text, /env: prod\s+branch: prod\s+clusterName: prod-cluster/);
    assert.match(text, /if eq \.env "dev"/);
    assert.match(text, /prune: true/);
    assert.match(text, /selfHeal: true/);
    assert.match(text, /CreateNamespace=true/);
  });
});
