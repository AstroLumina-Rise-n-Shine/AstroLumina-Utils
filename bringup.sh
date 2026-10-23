#!/usr/bin/env bash
# ============================================================================
# AstroLumina bring-up — ONE environment at a time (development|staging|
# production). Interactive on purpose: EVERY command is printed first and
# runs only after you press Enter, so nothing executes without your consent.
#
# Usage:   ./bringup.sh [development|staging|production]
#          (no argument -> it asks; default: development)
#
# Operator note: one Enter per step — do not hold or paste Enter, buffered
# keystrokes would silently confirm the following steps.
#
# Sequence:
#   Phase 0. Preflight: repo check + K8S_CP_CONN from Doppler (read-only)
#   Phase 1. Terraform: build the 3 VMs (tf.sh apply -> terraform apply,
#            wait for SSH on every node, tailnet DNS sync)
#   Phase 2. Ansible: provision RKE2 (playbooks/full_rke2_config.yml)
#   Phase 3. ArgoCD: kubectl bootstrap, namespace + RBAC, Helm chart, admin
#            password, Traefik route, Doppler operator + token secret,
#            ghcr-secret, ApplicationSets (NO sync happens here)
#   Phase 4. Monitoring — STAGING/PRODUCTION ONLY (skipped for development,
#            which runs ArgoCD alone by design): local-path-provisioner,
#            kube-prometheus-stack, Traefik basicAuth + routes, ServiceMonitors,
#            standalone prometheus-adapter, Grafana dashboards; then PRODUCTION
#            ONLY: the traefik-dashboard basicAuth Secret the Helm chart
#            references but never creates
#   Phase 5. You: open the ArgoCD UI and sync THIS environment's applications
#            manually (the script never presses SYNC for you).
#
# Why Monitoring (Phase 4) must finish BEFORE the first Argo sync: the API
# HPAs scale on the custom metric `api_requests_per_minute`, which only
# exists once prometheus-adapter is running. Syncing the apps earlier would
# leave those HPAs at ScalingActive=False (scale-down held) until the
# adapter shows up — nothing breaks, but the first snapshot would be dirty.
#
# Precondition: the four source repos below are on up-to-date `main` (feature
# PRs merged). Source of truth for every command:
#   AstroLumina-ArgoCD/ARGOCD.md + AstroLumina-ArgoCD/README.md
#   AstroLumina-Monitoring/MONITORING.md
#   AstroLumina-Terraform/tf.sh, AstroLumina-Ansible/playbooks/
#
# Documented deviations from the raw docs (all intentional, all re-run-safe):
#   - `kubectl apply -k install/` (docs) -> streamed as `kubectl apply -f -`
#     over ssh, because kubectl lives on the CP and this repo is on the laptop.
#   - `helm install` (docs) -> `helm upgrade --install` (identical on a fresh
#     cluster, safe on re-runs).
#   - `helm repo add` kept re-runnable via `2>/dev/null || true`.
#   - servicemonitors/ + dashboards/ are copied to the CP first, then applied
#     there with `kubectl apply -k` (the doc's "from this repo root on the CP").
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Workspace root detection
#
# The script lives in the AstroLumina-Utils checkout. Resolve the workspace
# root that contains the run-time repos. Order of precedence:
#   1. An exported WORKSPACE_ROOT (explicit, wins over everything).
#   2. The script's own directory, if it directly contains
#      AstroLumina-Terraform and AstroLumina-Ansible (legacy layout: the
#      scripts sat in the workspace root itself).
#   3. The parent of the script directory (current layout: AstroLumina-Utils
#      is a sibling of the other repos inside the workspace).
# ---------------------------------------------------------------------------
if [ -n "${WORKSPACE_ROOT:-}" ]; then
  ROOT="$WORKSPACE_ROOT"
elif [ -d "$(dirname "${BASH_SOURCE[0]}")/AstroLumina-Terraform" ] \
  && [ -d "$(dirname "${BASH_SOURCE[0]}")/AstroLumina-Ansible" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
TF_REPO="$ROOT/AstroLumina-Terraform"
ANSIBLE_REPO="$ROOT/AstroLumina-Ansible"
ARGO_REPO="$ROOT/AstroLumina-ArgoCD"
MON_REPO="$ROOT/AstroLumina-Monitoring"

# ----------------------------------------------------------------- arguments
ENV="${1:-}"
if [ -z "$ENV" ]; then
  printf 'Environment to bring up — development|staging|production (default: development): '
  read -r ENV < /dev/tty || true
  ENV="${ENV:-development}"
fi
case "$ENV" in
  development) CFG=dev ;;
  staging)     CFG=stg ;;
  production)  CFG=prd ;;
  *) echo "error: unknown environment '$ENV' (use development|staging|production)" >&2; exit 2 ;;
esac

# The whole point of this script is the Enter gate: an interactive terminal
# is mandatory (same reasoning as clean_branches.sh).
if [ ! -t 0 ]; then
  echo "error: bringup.sh needs an interactive terminal (stdin is not a tty)" >&2
  exit 1
fi

for d in "$TF_REPO" "$ANSIBLE_REPO" "$ARGO_REPO" "$MON_REPO"; do
  [ -d "$d" ] || { echo "error: missing repo directory: $d" >&2; exit 2; }
done

# ------------------------------------------------------------------ plumbing
abort() { printf '\n[bringup] ABORT: %s\n' "$1" >&2; exit 1; }

# Stop on the first failed command; explain what to do next. Commands that
# are allowed to fail are explicitly guarded with `|| ...` where used.
trap 'rc=$?; printf "\n[bringup] ABORT: a command failed (exit %s)\n[bringup]   STEP: %s\n[bringup]   CMD:  %s\n[bringup] Fix the problem, then re-run: ./bringup.sh %s\n" "$rc" "$CURRENT" "${LAST_CMD:-?}" "$ENV" >&2; exit "$rc"' ERR

STEP=0
CURRENT=""
LAST_CMD=""
preview() { local a out=""; for a in "$@"; do out+="$a "; done; printf '%s' "${out% }"; }

# gate "<description>" ["<command preview>"] — print, then wait for Enter.
gate() {
  STEP=$((STEP+1)); CURRENT="$1"; LAST_CMD="${2:-}"
  printf '\n============================================================\n'
  printf 'STEP %s — %s\n' "$STEP" "$1"
  if [ -n "$LAST_CMD" ]; then printf '  CMD: %s\n' "$LAST_CMD"; fi
  printf '============================================================\n'
  printf '  Press Enter to run it (Ctrl+C stops the whole script): '
  read -r _ < /dev/tty || abort "no Enter received (input closed) at step: $CURRENT"
}

# step "<description>" cmd args... — gate + run (command auto-printed).
step() {
  local desc="$1"; shift
  gate "$desc" "$(preview "$@")"
  "$@"
}

printf '\nAstroLumina bring-up — environment: %s (Doppler config: %s)\n' "$ENV" "$CFG"
printf 'Every command is printed first; it runs only after you press Enter.\n'

# ============================================================ Phase 0 =======
printf '\n=== Phase 0/4: preflight ===\n'

gate 'Preflight — inspect the four source repos (branch + uncommitted changes; read-only)' \
  'git -C <repo> status --short --branch   # for AstroLumina-{Terraform,Ansible,ArgoCD,Monitoring}'
for r in "$TF_REPO" "$ANSIBLE_REPO" "$ARGO_REPO" "$MON_REPO"; do
  br="$(git -C "$r" branch --show-current)"
  dirty="$(git -C "$r" status --porcelain | wc -l | tr -d ' ')"
  printf '  %-28s branch=%s modified_files=%s\n' "$(basename "$r")" "$br" "$dirty"
  [ "$br" = "main" ] || echo "    (!) not on main — the bring-up reads files from this working tree"
  [ "$dirty" = "0" ] || echo "    (!) uncommitted changes present"
done

gate "Read K8S_CP_CONN for '$ENV' from Doppler (read-only)" \
  "doppler secrets get K8S_CP_CONN --plain --project astrolumina --config $CFG"
K8S_CP_CONN="$(doppler secrets get K8S_CP_CONN --plain --project astrolumina --config "$CFG")"
[ -n "$K8S_CP_CONN" ] || abort "K8S_CP_CONN came back empty (check Doppler: project astrolumina, config $CFG)"
export K8S_CP_CONN
printf '  -> target control plane: %s\n' "$K8S_CP_CONN"

# ============================================================ Phase 1 =======
printf '\n=== Phase 1/4: VMs (Terraform) ===\n'

step "Build the 3 VMs for '$ENV' (terraform apply + wait for SSH + tailnet DNS sync)" \
  "$TF_REPO/tf.sh" "$ENV" apply

# ============================================================ Phase 2 =======
printf '\n=== Phase 2/4: Ansible provisioning (RKE2) ===\n'

gate "Provision the cluster with Ansible — playbooks/full_rke2_config.yml (takes a few minutes)" \
  "cd AstroLumina-Ansible && ansible-playbook playbooks/full_rke2_config.yml -i inventory/inventory.yml"
( cd "$ANSIBLE_REPO" && ansible-playbook playbooks/full_rke2_config.yml -i inventory/inventory.yml )

# ============================================================ Phase 3 =======
printf '\n=== Phase 3/4: ArgoCD ===\n'

# -- 3.1 kubectl for the ubuntu user on the CP (RKE2 hides it outside PATH)
step 'Make kubectl usable on the CP (RKE2 kubeconfig) + smoke-test: kubectl get nodes' \
  ssh "$K8S_CP_CONN" -- "sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl && mkdir -p ~/.kube && sudo cat /etc/rancher/rke2/rke2.yaml > ~/.kube/config && chmod 600 ~/.kube/config && kubectl get nodes"

# -- 3.2 namespace + RBAC (streamed: kubectl is on the CP, repo on the laptop)
gate 'Apply the ArgoCD namespace + cluster-admin RBAC (install/00 + install/01, streamed to the CP)' \
  'cat AstroLumina-ArgoCD/install/00-namespace.yaml AstroLumina-ArgoCD/install/01-argocd-cluster-access.yaml | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"'
cat "$ARGO_REPO/install/00-namespace.yaml" "$ARGO_REPO/install/01-argocd-cluster-access.yaml" | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"

# -- 3.3 Helm CLI on the CP (idempotent)
step 'Ensure the Helm CLI exists on the CP (skips when already installed)' \
  ssh "$K8S_CP_CONN" -- "helm version >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

# -- 3.4 argo chart repo
step 'Add/refresh the argo Helm chart repo on the CP' \
  ssh "$K8S_CP_CONN" -- "helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true; helm repo update"

# -- 3.5 resolve the chart version
gate 'Resolve the newest argo-cd chart version on the CP (read-only)' \
  "CHART_VERSION=\$(ssh \"\$K8S_CP_CONN\" -- \"helm show chart argo/argo-cd | grep '^version:' | awk '{print \$2}'\"); value printed below and reused by the install steps"
CHART_VERSION="$(ssh "$K8S_CP_CONN" -- "helm show chart argo/argo-cd | grep '^version:' | awk '{print \$2}'")"
[ -n "$CHART_VERSION" ] || abort 'could not resolve the argo-cd chart version'
printf '  -> argo-cd chart version: %s\n' "$CHART_VERSION"

# -- 3.6 values for the ArgoCD chart (content printed first, then piped)
ARGOCD_VALUES="$(cat <<'EOF'
# Traefik IngressRoute (see below) replaces the chart's own Ingress.
server:
  ingress:
    enabled: false
  # ArgoCD server listens HTTPS on 8080 by default. Traefik terminates TLS
  # at the edge and talks plaintext to the backend (same as every other
  # route here), so the server must serve plain HTTP — otherwise the UI
  # route 502s. In-cluster only; the browser still gets HTTPS.
  extraArgs:
    - --insecure
EOF
)"
printf '\n----- ~/argocd-values.yaml (what will be written on the CP) -----\n%s\n-----------------------------------------------------------------\n' "$ARGOCD_VALUES"
gate 'Write ~/argocd-values.yaml on the CP (chart Ingress off; plain HTTP behind Traefik — content shown above)' \
  'printf "%s\n" "$ARGOCD_VALUES" | ssh "$K8S_CP_CONN" -- "cat > ~/argocd-values.yaml"'
printf '%s\n' "$ARGOCD_VALUES" | ssh "$K8S_CP_CONN" -- "cat > ~/argocd-values.yaml"
unset ARGOCD_VALUES

# -- 3.7 install/upgrade ArgoCD
step "Install/upgrade ArgoCD (helm upgrade --install, chart $CHART_VERSION)" \
  ssh "$K8S_CP_CONN" -- "helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version $CHART_VERSION -f ~/argocd-values.yaml"

step 'Wait for argocd-server to roll out' \
  ssh "$K8S_CP_CONN" -- "kubectl rollout status deploy/argocd-server -n argocd --timeout=300s"

# -- 3.8 admin password from Doppler (script patches argocd-secret, deletes
#    the initial-password secret, restarts the server)
gate "Set the ArgoCD admin password from Doppler (install/set-argocd-admin-password.sh, config $CFG)" \
  "cd AstroLumina-ArgoCD && DOPPLER_CONFIG=$CFG ./install/set-argocd-admin-password.sh"
( cd "$ARGO_REPO" && DOPPLER_CONFIG="$CFG" ./install/set-argocd-admin-password.sh )

# -- 3.9 expose the UI via Traefik (content printed first, then piped)
ARGOCD_ROUTE="$(cat <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.k8s.astrolumina.ro`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls: {}
EOF
)"
printf '\n----- IngressRoute argocd-server (what will be applied) -----\n%s\n-------------------------------------------------------------\n' "$ARGOCD_ROUTE"
gate 'Expose the ArgoCD UI via Traefik (IngressRoute argocd.k8s.astrolumina.ro — content shown above)' \
  'printf "%s\n" "$ARGOCD_ROUTE" | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"'
printf '%s\n' "$ARGOCD_ROUTE" | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"
unset ARGOCD_ROUTE

# -- 3.10 Doppler operator (once per cluster rebuild, BEFORE the token secret)
step 'Install the Doppler Kubernetes operator (recommended.yaml)' \
  ssh "$K8S_CP_CONN" -- "kubectl apply -f https://github.com/DopplerHQ/kubernetes-operator/releases/latest/download/recommended.yaml"

# -- 3.11 Doppler service token for THIS config (value never echoed)
gate "Read DOPPLER_SERVICE_TOKEN (Doppler, config $CFG) + create secret doppler-token-$CFG in doppler-operator-system (value hidden)" \
  "doppler secrets get DOPPLER_SERVICE_TOKEN --plain --project astrolumina --config $CFG ; ssh \"\$K8S_CP_CONN\" -- kubectl create secret generic doppler-token-$CFG -n doppler-operator-system --from-literal=serviceToken=*** --dry-run=client -o yaml | kubectl apply -f -   # read-only; value captured into a variable, never printed"
DOPPLER_SERVICE_TOKEN="$(doppler secrets get DOPPLER_SERVICE_TOKEN --plain --project astrolumina --config "$CFG")"
[ -n "$DOPPLER_SERVICE_TOKEN" ] || abort 'DOPPLER_SERVICE_TOKEN came back empty'
# Pre-escape "$" so the remote shell cannot mangle the value (same rule the
# monitoring secrets below follow; see MONITORING.md).
ESC_TOKEN=${DOPPLER_SERVICE_TOKEN//$/\\$}
ssh "$K8S_CP_CONN" -- 'kubectl create secret generic doppler-token-'"$CFG"' -n doppler-operator-system --from-literal=serviceToken='"$ESC_TOKEN"' --dry-run=client -o yaml | kubectl apply -f -'
unset DOPPLER_SERVICE_TOKEN ESC_TOKEN

step 'Verify the Doppler operator is running and the token secret exists' \
  ssh "$K8S_CP_CONN" -- "kubectl -n doppler-operator-system get pods && kubectl -n doppler-operator-system get secret doppler-token-$CFG"

# -- 3.12 GHCR pull credentials (needed before the first sync; values hidden)
gate "Read the GHCR credentials from Doppler (read-only, values hidden)" \
  "doppler secrets get GITHUB_USER --plain --project astrolumina --config $CFG ; doppler secrets get GITHUB_TOKEN --plain --project astrolumina --config $CFG ; doppler secrets get GITHUB_EMAIL --plain --project astrolumina --config $CFG   # read-only; values captured into variables, never printed"
GITHUB_USER="$(doppler secrets get GITHUB_USER --plain --project astrolumina --config "$CFG")"
GITHUB_TOKEN="$(doppler secrets get GITHUB_TOKEN --plain --project astrolumina --config "$CFG")"
GITHUB_EMAIL="$(doppler secrets get GITHUB_EMAIL --plain --project astrolumina --config "$CFG")"
[ -n "$GITHUB_USER" ] || abort 'GITHUB_USER came back empty'
[ -n "$GITHUB_TOKEN" ] || abort 'GITHUB_TOKEN came back empty'
[ -n "$GITHUB_EMAIL" ] || abort 'GITHUB_EMAIL came back empty'
# Pre-escape "$" for the remote shell (same rule as the other secrets).
ESC_USER=${GITHUB_USER//$/\\$}
ESC_GH_TOKEN=${GITHUB_TOKEN//$/\\$}
ESC_MAIL=${GITHUB_EMAIL//$/\\$}

step "Create the application namespace astrolumina-$ENV (idempotent)" \
  ssh "$K8S_CP_CONN" -- "kubectl create namespace astrolumina-$ENV --dry-run=client -o yaml | kubectl apply -f -"

gate "Create/refresh ghcr-secret in astrolumina-$ENV (private ghcr.io pull secret; values hidden)" \
  "ssh \"\$K8S_CP_CONN\" -- kubectl create secret docker-registry ghcr-secret -n astrolumina-$ENV --docker-server=ghcr.io --docker-username=*** --docker-password=*** --docker-email=*** --dry-run=client -o yaml | kubectl apply -f -"
ssh "$K8S_CP_CONN" -- 'kubectl create secret docker-registry ghcr-secret -n astrolumina-'"$ENV"' --docker-server=ghcr.io --docker-username='"$ESC_USER"' --docker-password='"$ESC_GH_TOKEN"' --docker-email='"$ESC_MAIL"' --dry-run=client -o yaml | kubectl apply -f -'
unset GITHUB_TOKEN GITHUB_USER GITHUB_EMAIL ESC_USER ESC_GH_TOKEN ESC_MAIL

step 'Verify the pull secret exists' \
  ssh "$K8S_CP_CONN" -- "kubectl get secret ghcr-secret -n astrolumina-$ENV"

# -- 3.13 ApplicationSets (they only create the Applications; nothing syncs)
gate 'Apply ApplicationSet: astrolumina-kubernetes (creates the 3 env Applications; NO sync yet)' \
  'ssh "$K8S_CP_CONN" -- "kubectl apply -f -" < AstroLumina-ArgoCD/apps/astrolumina-kubernetes.yaml'
ssh "$K8S_CP_CONN" -- "kubectl apply -f -" < "$ARGO_REPO/apps/astrolumina-kubernetes.yaml"

gate 'Apply ApplicationSet: astrolumina-helm (creates the 3 Helm Applications; NO sync yet)' \
  'ssh "$K8S_CP_CONN" -- "kubectl apply -f -" < AstroLumina-ArgoCD/apps/astrolumina-helm.yaml'
ssh "$K8S_CP_CONN" -- "kubectl apply -f -" < "$ARGO_REPO/apps/astrolumina-helm.yaml"

step 'List the Applications ArgoCD now knows about (all OutOfSync — nothing synced yet)' \
  ssh "$K8S_CP_CONN" -- "kubectl -n argocd get applications"

# ============================================================ Phase 4 =======
# Monitoring is staging/production-only: development runs ArgoCD alone.
if [ "$ENV" = development ]; then
  printf '\n[skip] Phase 4 (Monitoring): development runs ArgoCD only (no Traefik, no monitoring stack).\n'
else
printf '\n=== Phase 4/4: Monitoring (Prometheus/Grafana + adapter + dashboards) ===\n'

# -- 4.1 storage backend (once per cluster rebuild)
step 'Install local-path-provisioner (storage for the monitoring PVCs, once per rebuild)' \
  ssh "$K8S_CP_CONN" -- "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"

step 'Wait for local-path-provisioner + confirm the StorageClass (expect: local-path default)' \
  ssh "$K8S_CP_CONN" -- "kubectl -n local-path-storage rollout status deploy/local-path-provisioner && kubectl get storageclass"

# -- 4.2 values file for the kube-prometheus-stack release (printed, then piped)
MON_VALUES="$(cat <<'EOF'
prometheus:
  prometheusSpec:
    scrapeInterval: 1m
    evaluationInterval: 1m
    retention: 1d
    retentionSize: 8GB   # second guardrail: whichever hits first wins, disk never fills silently
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 10Gi } }
    resources: { requests: { cpu: 300m, memory: 1Gi } }
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 2Gi } }
grafana:
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi   # dashboards + sqlite survive restarts (emptyDir would wipe them)
    # NOTE: admin password is NOT in this file — passed via --set from Doppler at install time.
EOF
)"
printf '\n----- ~/monitoring-values.yaml (what will be written on the CP) -----\n%s\n--------------------------------------------------------------------\n' "$MON_VALUES"
gate 'Write ~/monitoring-values.yaml on the CP (1m scrape, 1d/8GB retention, PVCs on local-path — content shown above)' \
  'printf "%s\n" "$MON_VALUES" | ssh "$K8S_CP_CONN" -- "cat > ~/monitoring-values.yaml"'
printf '%s\n' "$MON_VALUES" | ssh "$K8S_CP_CONN" -- "cat > ~/monitoring-values.yaml"
unset MON_VALUES

step 'Ensure the Helm CLI exists on the CP (idempotent)' \
  ssh "$K8S_CP_CONN" -- "helm version >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

step 'Add/refresh the prometheus-community chart repo on the CP' \
  ssh "$K8S_CP_CONN" -- "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true; helm repo update"

# -- 4.3 install the monitoring release (Grafana admin password via --set)
gate 'Read GRAFANA_ADMIN_PASSWORD from Doppler (read-only, hidden)' \
  "doppler secrets get GRAFANA_ADMIN_PASSWORD --plain --project astrolumina --config $CFG"
GRAFANA_ADMIN="$(doppler secrets get GRAFANA_ADMIN_PASSWORD --plain --project astrolumina --config "$CFG")"
[ -n "$GRAFANA_ADMIN" ] || abort 'GRAFANA_ADMIN_PASSWORD came back empty'

gate "Install/upgrade the kube-prometheus-stack release 'monitoring' (Grafana admin via --set; value hidden)" \
  "ssh \"\$K8S_CP_CONN\" -- helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f ~/monitoring-values.yaml --set grafana.adminPassword=***"
ESCAPED_ADMIN=${GRAFANA_ADMIN//$/\\$}
ssh "$K8S_CP_CONN" -- 'helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f ~/monitoring-values.yaml --set grafana.adminPassword='"$ESCAPED_ADMIN"
unset GRAFANA_ADMIN ESCAPED_ADMIN

# -- 4.4 Traefik basicAuth secret for Prometheus + the two IngressRoutes
gate 'Read PROMETHEUS_AUTH from Doppler + create the prometheus-auth secret (Traefik basicAuth; value hidden)' \
  "doppler secrets get PROMETHEUS_AUTH --plain --project astrolumina --config $CFG ; ssh \"\$K8S_CP_CONN\" -- kubectl create secret generic prometheus-auth -n monitoring --from-literal=users=*** --dry-run=client -o yaml | kubectl apply -f -   # read-only; value captured into a variable, never printed"
PROMETHEUS_AUTH="$(doppler secrets get PROMETHEUS_AUTH --plain --project astrolumina --config "$CFG")"
[ -n "$PROMETHEUS_AUTH" ] || abort 'PROMETHEUS_AUTH came back empty'
ESCAPED_AUTH=${PROMETHEUS_AUTH//$/\\$}
ssh "$K8S_CP_CONN" -- 'kubectl create secret generic prometheus-auth -n monitoring --from-literal=users='"$ESCAPED_AUTH"' --dry-run=client -o yaml | kubectl apply -f -'
unset PROMETHEUS_AUTH ESCAPED_AUTH

ROUTES_YAML="$(cat <<'EOF'
# Both routes are HTTPS-only on websecure. HTTP is deliberately NOT served.
# `tls: {}` serves Traefik's default self-signed cert (lab has no public
# DNS, so Let's Encrypt cannot issue) — expect a browser cert warning.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints: [websecure]
  tls: {}
  routes:
    - match: Host(`grafana.k8s.astrolumina.ro`)
      kind: Rule
      services:
        - name: monitoring-grafana
          port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints: [websecure]
  tls: {}
  routes:
    - match: Host(`prometheus.k8s.astrolumina.ro`)
      kind: Rule
      middlewares:
        - name: prometheus-auth
      services:
        - name: monitoring-kube-prometheus-prometheus
          port: 9090
---
# BasicAuth for Prometheus (same password as Grafana). The `secret` value is
# the name of the generic Secret created above; its `users` key holds the
# full htpasswd line. Deliberately NOT attached to the Grafana route —
# Grafana has its own login, basicAuth on top would double-prompt.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: prometheus-auth
  namespace: monitoring
spec:
  basicAuth:
    secret: prometheus-auth
EOF
)"
printf '\n----- /tmp/monitoring-routes.yaml (what will be written locally) -----\n%s\n---------------------------------------------------------------------\n' "$ROUTES_YAML"
gate 'Write /tmp/monitoring-routes.yaml locally (Grafana + Prometheus IngressRoutes + basicAuth Middleware — content shown above)' \
  'printf "%s\n" "$ROUTES_YAML" > /tmp/monitoring-routes.yaml'
printf '%s\n' "$ROUTES_YAML" > /tmp/monitoring-routes.yaml
unset ROUTES_YAML

gate 'Apply the monitoring routes to the cluster' \
  'cat /tmp/monitoring-routes.yaml | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"'
cat /tmp/monitoring-routes.yaml | ssh "$K8S_CP_CONN" -- "kubectl apply -f -"

step 'Verify monitoring pods + routes (first image pull takes 1-2 min; wait for Running)' \
  ssh "$K8S_CP_CONN" -- "kubectl get pods -n monitoring && kubectl get ingressroute -n monitoring"

# -- 4.5 ServiceMonitors + dashboards (copy to the CP, apply -k there)
gate 'Copy servicemonitors/ + dashboards/ to the CP (~/monitoring-kustomize) for kubectl apply -k' \
  'tar czf - -C AstroLumina-Monitoring servicemonitors dashboards | ssh "$K8S_CP_CONN" -- "mkdir -p ~/monitoring-kustomize && tar xzf - -C ~/monitoring-kustomize"'
tar czf - -C "$MON_REPO" servicemonitors dashboards | ssh "$K8S_CP_CONN" -- "mkdir -p ~/monitoring-kustomize && tar xzf - -C ~/monitoring-kustomize"

step 'Apply the ServiceMonitors on the CP (kubectl apply -k servicemonitors/)' \
  ssh "$K8S_CP_CONN" -- "cd ~/monitoring-kustomize && kubectl apply -k servicemonitors/"

# -- 4.6 prometheus-adapter overlay (custom metric for the HPAs)
gate 'Copy values-prometheus-adapter.yaml to the CP' \
  'cat AstroLumina-Monitoring/values-prometheus-adapter.yaml | ssh "$K8S_CP_CONN" -- "cat > ~/values-prometheus-adapter.yaml"'
cat "$MON_REPO/values-prometheus-adapter.yaml" | ssh "$K8S_CP_CONN" -- "cat > ~/values-prometheus-adapter.yaml"

# The kube-prometheus-stack chart no longer bundles a prometheus-adapter
# subchart: an overlay nested under the monitoring release is silently
# ignored ("Upgrade complete", zero adapter manifests). Install the adapter
# as its own release instead (values file is standalone-chart shaped).
step 'Install/upgrade the standalone prometheus-adapter release (chart 5.3.0 => app v0.12.0)' \
  ssh "$K8S_CP_CONN" -- "helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter -n monitoring -f ~/values-prometheus-adapter.yaml --version 5.3.0"

step 'Apply the Grafana dashboards on the CP (kubectl apply -k dashboards/)' \
  ssh "$K8S_CP_CONN" -- "cd ~/monitoring-kustomize && kubectl apply -k dashboards/"

gate "Verify the custom metric endpoint (an empty PodMetricsList is normal at zero traffic)" \
  "ssh \"\$K8S_CP_CONN\" -- kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/astrolumina-$ENV/pods/*/api_requests_per_minute"
ssh "$K8S_CP_CONN" -- "kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/astrolumina-$ENV/pods/*/api_requests_per_minute" \
  || printf '  (i) endpoint not served yet — normal right after install; retry in 1-2 minutes with the same command.\n'

step 'Verify ServiceMonitors + dashboards are loaded (ConfigMaps labelled grafana_dashboard=1)' \
  ssh "$K8S_CP_CONN" -- "kubectl get servicemonitor -n monitoring && kubectl get configmap -n monitoring -l grafana_dashboard=1"

gate 'Check the laptop /etc/hosts entries for the UIs (read-only)' \
  "grep -nE '(argocd|grafana|prometheus)\\.k8s\\.astrolumina\\.ro' /etc/hosts"
grep -nE '(argocd|grafana|prometheus)\.k8s\.astrolumina\.ro' /etc/hosts \
  || printf '  (!) missing entries — add (with sudo):\n      192.168.122.11 argocd.k8s.astrolumina.ro prometheus.k8s.astrolumina.ro grafana.k8s.astrolumina.ro\n'

# -- 4.7 production only: the Traefik dashboard basicAuth Secret ------------
# The Helm chart only REFERENCES this Secret (templates/middlewares.yaml ->
# dashboard-auth middleware). Without it Traefik drops the whole
# `traefik-dashboard` IngressRoute (middleware fails to load -> router
# removed -> 404 on dashboard.k8s.astrolumina.ro). It is deliberately NOT in
# git — created imperatively from Doppler, exactly like the repo README says.
# Development/staging do not attach basicAuth to the dashboard route.
if [ "$ENV" = production ]; then
  gate 'Ensure the astrolumina-production namespace exists (the app sync adopts it later)' \
    'ssh "$K8S_CP_CONN" -- kubectl create namespace astrolumina-production --dry-run=client -o yaml | kubectl apply -f -'
  ssh "$K8S_CP_CONN" -- "kubectl create namespace astrolumina-production --dry-run=client -o yaml | kubectl apply -f -"

  gate "Read TRAEFIK_DASHBOARD_AUTH from Doppler + create the traefik-dashboard-auth secret (value hidden)" \
    "doppler secrets get TRAEFIK_DASHBOARD_AUTH --plain --project astrolumina --config $CFG ; ssh \"\$K8S_CP_CONN\" -- kubectl create secret generic traefik-dashboard-auth -n astrolumina-production --from-literal=users=*** --dry-run=client -o yaml | kubectl apply -f -   # read-only; value captured into a variable, never printed"
  TRAEFIK_DASH_AUTH="$(doppler secrets get TRAEFIK_DASHBOARD_AUTH --plain --project astrolumina --config "$CFG")"
  [ -n "$TRAEFIK_DASH_AUTH" ] || abort 'TRAEFIK_DASHBOARD_AUTH came back empty'
  ESCAPED_DASH_AUTH=${TRAEFIK_DASH_AUTH//$/\\$}
  ssh "$K8S_CP_CONN" -- 'kubectl create secret generic traefik-dashboard-auth -n astrolumina-production --from-literal=users='"$ESCAPED_DASH_AUTH"' --dry-run=client -o yaml | kubectl apply -f -'
  unset TRAEFIK_DASH_AUTH ESCAPED_DASH_AUTH

  step 'Verify the dashboard secret exists (hash prefix only, hidden value)' \
    ssh "$K8S_CP_CONN" -- "kubectl -n astrolumina-production get secret traefik-dashboard-auth -o jsonpath='{.data.users}' | base64 -d | cut -c1-10"
else
  printf '\n[skip] 4.7 Traefik dashboard secret: production-only step (current env: %s)\n' "$ENV"
fi
fi # end Phase 4 guard (development skips the whole monitoring phase)

# ============================================================ Outro =========
printf '\n============================================================\n'
printf ' bringup.sh finished — the cluster is ready for YOUR manual sync\n'
printf '============================================================\n'
if [ "$ENV" = development ]; then
  MON_UI='    (no Grafana/Prometheus on development — ArgoCD alone by design)'
  MON_NEXT='    4. (monitoring stack skipped on development — Grafana/Prometheus absent)
    5. (nothing further — the remaining notes are production-only)'
else
  MON_UI='    Grafana    : https://grafana.k8s.astrolumina.ro/   (user: admin — password = Doppler GRAFANA_ADMIN_PASSWORD, plaintext)
    Prometheus : https://prometheus.k8s.astrolumina.ro/ (user: admin — same password, via Traefik basicAuth)'
  MON_NEXT='    4. Grafana -> folder "AstroLumina" (dashboards) + Prometheus -> Targets
       once the pods are scraped. HPAs scale on api_requests_per_minute
       (API, target 20/min/pod) and frontend_requests_per_minute (frontend).
    5. production only: walk ARGOCD.md section 0 (prerequisites) before syncing.'
fi

cat <<EOF

  UIs (browser will warn about the lab self-signed cert):
    ArgoCD     : https://argocd.k8s.astrolumina.ro/    (user: admin — password = Doppler ARGOCD_ADMIN_PASSWORD, config $CFG)
$MON_UI

  Your next step (deliberately manual — nothing syncs by itself):
    1. Open the ArgoCD UI and log in.
    2. For THIS cluster sync ONLY the '$ENV' applications, after reviewing each diff:
         - astrolumina-kubernetes-$ENV
         - astrolumina-helm-$ENV
       (the staging/production Applications exist too but belong to their own
        clusters — leave them untouched here)
    3. Watch the namespace astrolumina-$ENV: pods start, then the Doppler
       operator materialises the 4 env-* secrets.
$MON_NEXT
EOF

printf '\nDone.\n'
